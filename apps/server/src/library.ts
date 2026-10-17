import { type File, type FilePage, Id, type Kind, Time, type UploadedFile } from '@wadjet/protocol'
import { Schema } from 'effect'
import type { BlobStore } from './blob-store.ts'
import { sha256Hex } from './crypto.ts'
import { invalidRequest, notFound } from './errors.ts'
import { type Cursor, canonicalName, type FileIndex, type FileRow } from './file-index.ts'
import { extensionFor, kindFor } from './media.ts'
import type { CachePurger, Clock, IdGenerator, TokenGenerator } from './ports.ts'

type FileKind = (typeof Kind)['Type']

export interface LibraryDeps {
  readonly files: FileIndex
  readonly blobs: BlobStore
  readonly purger: CachePurger
  readonly clock: Clock
  readonly ids: IdGenerator
  readonly tokens: TokenGenerator
  readonly baseUrl: string
}

export interface UploadInput {
  readonly owner: string
  readonly body: ReadableStream<Uint8Array>
  readonly size: number
  readonly contentType: string
  readonly filename?: string | undefined
  readonly kind?: FileKind | undefined
  readonly device?: string | undefined
  readonly idempotencyKey?: string | undefined
}

const FILENAME_EXTENSION = /\.([0-9A-Za-z]{1,10})$/

const cursorSchema = Schema.fromJsonString(Schema.Tuple([Time, Id]))

const base64url = (text: string): string =>
  btoa(text).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')

const decodeCursor = (cursor: string): Cursor => {
  let json: string
  try {
    json = atob(cursor.replaceAll('-', '+').replaceAll('_', '/'))
  } catch {
    throw invalidRequest('This cursor is invalid.')
  }
  try {
    const [createdAt, id] = Schema.decodeUnknownSync(cursorSchema)(json)
    return { createdAt: new Date(createdAt), id }
  } catch {
    throw invalidRequest('This cursor is invalid.')
  }
}

const toTime = (date: Date): string => date.toISOString().replace(/\.\d{3}Z$/, 'Z')

/** Upload, list, and delete over the storage ports. */
export const createLibrary = (deps: LibraryDeps) => {
  const fileUrl = (row: Pick<FileRow, 'id' | 'extension'>): string =>
    `${deps.baseUrl}/${canonicalName(row)}`

  const toFile = (row: FileRow): typeof File.Type => ({
    id: row.id,
    url: fileUrl(row),
    filename: row.filename,
    kind: row.kind,
    contentType: row.contentType,
    size: row.size,
    device: row.device,
    createdAt: toTime(row.createdAt),
    thumbnailUrl: null, // #51 adds thumbnails
  })

  return {
    async upload(
      input: UploadInput,
    ): Promise<{ file: typeof UploadedFile.Type; created: boolean }> {
      if (input.idempotencyKey !== undefined) {
        const existing = await deps.files.findByIdempotencyKey(input.owner, input.idempotencyKey)
        if (existing) return { file: { ...toFile(existing), deleteUrl: null }, created: false }
      }

      const id = deps.ids()
      const token = deps.tokens()
      const createdAt = new Date(Math.floor(deps.clock().getTime() / 1000) * 1000)
      const extension =
        input.filename?.match(FILENAME_EXTENSION)?.[1]?.toLowerCase() ??
        extensionFor(input.contentType) ??
        null
      const filename = input.filename ?? (extension ? `${id}.${extension}` : id)
      const kind = input.kind ?? kindFor(input.contentType)
      const blobKey = `files/${id}`
      const row: FileRow = {
        id,
        owner: input.owner,
        filename,
        extension,
        kind,
        contentType: input.contentType,
        size: input.size,
        device: input.device ?? null,
        createdAt,
        blobKey,
        deleteTokenHash: await sha256Hex(token),
        idempotencyKey: input.idempotencyKey ?? null,
      }

      await deps.blobs.put(blobKey, input.body, input.size, input.contentType)
      try {
        await deps.files.insert(row)
      } catch (error) {
        await deps.blobs.delete(blobKey)
        throw error
      }
      return { file: { ...toFile(row), deleteUrl: `${deps.baseUrl}/d/${token}` }, created: true }
    },

    async list(
      owner: string,
      options: { cursor?: string | undefined; limit: number },
    ): Promise<typeof FilePage.Type> {
      const after = options.cursor === undefined ? undefined : decodeCursor(options.cursor)
      const rows = await deps.files.list(owner, options.limit + 1, after)
      const page = rows.slice(0, options.limit)
      const last = page.at(-1)
      const nextCursor =
        rows.length > options.limit && last
          ? base64url(JSON.stringify([toTime(last.createdAt), last.id]))
          : null
      return { items: page.map(toFile), nextCursor }
    },

    async delete(owner: string, id: string): Promise<void> {
      const row = await deps.files.get(id)
      if (!row || row.owner !== owner) throw notFound(`No file ${id}.`)
      await deps.blobs.delete(row.blobKey)
      await deps.files.delete(id)
      // #51 adds the thumbnail URL to this purge
      await deps.purger.purge([fileUrl(row)])
    },
  }
}

export type Library = ReturnType<typeof createLibrary>
