import type { BlobStore, ByteRange } from './blob-store.ts'
import { notFound } from './errors.ts'
import { canonicalName, type FileIndex } from './file-index.ts'
import { isInline } from './media.ts'

export const FILE_CACHE_CONTROL = 'public, max-age=300, s-maxage=31536000'

const NAME_PATTERN = /^([0-9A-Za-z]{6})(?:\.([^/]+))?$/

const RFC5987_SAFE = /^[A-Za-z0-9\-._~]$/

/** filename* per RFC 5987: keep unreserved bytes, %XX-encode the rest (uppercase). */
const encodeFilename = (filename: string): string =>
  [...new TextEncoder().encode(filename)]
    .map((byte) => {
      const char = String.fromCharCode(byte)
      return RFC5987_SAFE.test(char) ? char : `%${byte.toString(16).toUpperCase().padStart(2, '0')}`
    })
    .join('')

interface ParsedRange {
  readonly offset: number
  readonly length: number
}

const RANGE_PATTERN = /^bytes=(\d*)-(\d*)$/

/** One satisfiable byte range, or null for "send the whole body". */
const parseRange = (header: string | undefined, size: number): ParsedRange | null => {
  if (!header) return null
  const [, first, last] = header.match(RANGE_PATTERN) ?? []
  if (first === undefined || (first === '' && last === '')) return null
  let start: number
  let end: number
  if (first === '') {
    const suffix = Number(last)
    if (suffix === 0) return null
    start = Math.max(0, size - suffix)
    end = size - 1
  } else {
    start = Number(first)
    end = last === '' ? size - 1 : Math.min(Number(last), size - 1)
  }
  if (start > end || start >= size) return null
  return { offset: start, length: end - start + 1 }
}

export interface ServedFile {
  readonly status: 200 | 206 | 301
  readonly headers: Record<string, string>
  readonly body: ReadableStream<Uint8Array> | null
}

/**
 * Resolve `GET`/`HEAD /:name` to a redirect, a full body, or a byte range.
 * `method` 'HEAD' skips opening the blob.
 */
export const serveFile = async (
  deps: { files: FileIndex; blobs: BlobStore; baseUrl: string },
  name: string,
  method: string,
  rangeHeader: string | undefined,
): Promise<ServedFile> => {
  const id = name.match(NAME_PATTERN)?.[1]
  if (id === undefined) throw notFound(`Nothing at /${name}.`)
  const row = await deps.files.get(id)
  if (!row || row.deletedAt) throw notFound(`No file ${id}.`)

  const canonical = canonicalName(row)
  if (name !== canonical) {
    return {
      status: 301,
      headers: {
        Location: `${deps.baseUrl}/${canonical}`,
        'Cache-Control': FILE_CACHE_CONTROL,
      },
      body: null,
    }
  }

  const headers: Record<string, string> = {
    'Content-Type': row.contentType,
    'Accept-Ranges': 'bytes',
    'Cache-Control': FILE_CACHE_CONTROL,
    'Content-Disposition': `${isInline(row.contentType) ? 'inline' : 'attachment'}; filename*=UTF-8''${encodeFilename(row.filename)}`,
    ETag: `"${row.id}"`,
  }

  const range = parseRange(rangeHeader, row.size)
  const slice: ByteRange = range ?? { offset: 0, length: row.size }
  const status = range ? 206 : 200
  headers['Content-Length'] = String(slice.length)
  if (range)
    headers['Content-Range'] =
      `bytes ${slice.offset}-${slice.offset + slice.length - 1}/${row.size}`

  if (method === 'HEAD') return { status, headers, body: null }
  const body = await deps.blobs.get(row.blobKey, range ?? undefined)
  if (!body) throw new Error(`Blob ${row.blobKey} is missing`)
  return { status, headers, body }
}
