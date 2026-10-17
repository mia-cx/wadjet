import {
  type File,
  type FilePage,
  Id,
  type Kind,
  type PartReceipt,
  Time,
  type UploadedFile,
  type UploadSession,
  type UploadStatus,
} from '@wadjet/protocol'
import { Schema } from 'effect'
import type { BlobStore } from './blob-store.ts'
import { sha256Hex } from './crypto.ts'
import { invalidRequest, notFound, ProtocolError, tooLarge } from './errors.ts'
import { type Cursor, canonicalName, type FileIndex, type FileRow } from './file-index.ts'
import { extensionFor, kindFor } from './media.ts'
import type { CachePurger, Clock, IdGenerator, TokenGenerator } from './ports.ts'
import type { UploadIndex, UploadRow } from './upload-index.ts'

type FileKind = (typeof Kind)['Type']

export interface LibraryDeps {
  readonly files: FileIndex
  readonly uploads: UploadIndex
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

export interface StartUploadInput {
  readonly owner: string
  readonly contentType: string
  readonly size: number
  readonly filename?: string | undefined
  readonly kind?: FileKind | undefined
  readonly device?: string | undefined
  readonly idempotencyKey?: string | undefined
  readonly partBytes: number
  readonly maxFileBytes: number | null
}

export interface LibraryLimits {
  readonly partBytes: number
  readonly maxFileBytes: number | null
  readonly maxThumbnailBytes: number
}

const UPLOAD_TTL_MS = 24 * 3600 * 1000
const EXPIRE_SWEEP_LIMIT = 10
/** How long an in-flight complete holds its lease before another can take over. */
const COMPLETE_LEASE_MS = 15 * 60_000

const FILENAME_EXTENSION = /\.([0-9A-Za-z]{1,10})$/

const MAX_ID_ATTEMPTS = 5
const BLOB_KEY_TOKEN_CHARS = 16

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
    thumbnailUrl:
      row.thumbnailVersion > 0 ? `${deps.baseUrl}/t/${row.id}?v=${row.thumbnailVersion}` : null,
  })

  const uploadExpired = (row: UploadRow) =>
    new ProtocolError(410, 'upload_expired', `This upload expired at ${toTime(row.expiresAt)}.`)

  /** 404s a foreign or missing session; expires an overdue open one. */
  const liveUpload = async (id: string, owner: string): Promise<UploadRow> => {
    const row = await deps.uploads.get(id)
    if (!row || row.owner !== owner) throw notFound(`No upload ${id}.`)
    if (row.state === 'expired') throw uploadExpired(row)
    const now = deps.clock().getTime()
    const expirable =
      row.expiresAt.getTime() <= now &&
      (row.state === 'open' ||
        (row.state === 'completing' &&
          row.completingUntil !== null &&
          row.completingUntil.getTime() <= now))
    if (expirable) {
      // Abort first: a failure leaves the row unexpired so the next call
      // retries, instead of stranding it with live storage parts.
      await deps.blobs.abortMultipart(row.blobKey, row.storageUploadId)
      await deps.uploads.transition(id, row.state, 'expired')
      throw uploadExpired(row)
    }
    return row
  }

  /** Draws the id and builds the FileRow a finished upload inserts. */
  const prepareFile = async (
    input: Omit<UploadInput, 'body'>,
    fixedId?: string,
  ): Promise<{ row: FileRow; token: string }> => {
    const token = deps.tokens()
    const deleteTokenHash = await sha256Hex(token)
    let id = fixedId ?? ''
    if (id === '') {
      // Upload and file ids share one namespace — a completed upload's file
      // takes the session's id, so a free id must clear both tables.
      for (let attempt = 0; attempt < MAX_ID_ATTEMPTS; attempt++) {
        id = deps.ids()
        if ((await deps.files.get(id)) === undefined && (await deps.uploads.get(id)) === undefined)
          break
        if (attempt === MAX_ID_ATTEMPTS - 1)
          throw new Error(`Could not draw a free id in ${MAX_ID_ATTEMPTS} attempts`)
      }
    }
    const createdAt = new Date(Math.floor(deps.clock().getTime() / 1000) * 1000)
    const extension =
      input.filename?.match(FILENAME_EXTENSION)?.[1]?.toLowerCase() ??
      extensionFor(input.contentType) ??
      null
    const filename = input.filename ?? (extension ? `${id}.${extension}` : id)
    const kind = input.kind ?? kindFor(input.contentType)
    // The attempt's token makes the key unique even if two uploads draw the same id.
    const blobKey = `files/${id}-${deleteTokenHash.slice(0, BLOB_KEY_TOKEN_CHARS)}`
    return {
      token,
      row: {
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
        deleteTokenHash,
        idempotencyKey: input.idempotencyKey ?? null,
        deletedAt: null,
        thumbnailVersion: 0,
        thumbnailBlobKey: null,
        thumbnailContentType: null,
        thumbnailSize: null,
      },
    }
  }

  const sessionBody = (row: UploadRow): typeof UploadSession.Type => ({
    id: row.id,
    partBytes: row.partBytes,
    partCount: row.partCount,
    expiresAt: toTime(row.expiresAt),
  })

  return {
    async upload(
      input: UploadInput,
    ): Promise<{ file: typeof UploadedFile.Type; created: boolean }> {
      if (input.idempotencyKey !== undefined) {
        const existing = await deps.files.findByIdempotencyKey(input.owner, input.idempotencyKey)
        if (existing) return { file: { ...toFile(existing), deleteUrl: null }, created: false }
      }

      const prepared = await prepareFile(input)
      await deps.blobs.put(prepared.row.blobKey, input.body, input.size, input.contentType)
      let stored: FileRow
      try {
        stored = await deps.files.insert(prepared.row)
      } catch (error) {
        await deps.blobs.delete(prepared.row.blobKey)
        throw error
      }
      if (stored.blobKey !== prepared.row.blobKey) {
        // An overlapping upload with the same idempotency key won; drop our blob.
        await deps.blobs.delete(prepared.row.blobKey)
        return { file: { ...toFile(stored), deleteUrl: null }, created: false }
      }
      return {
        file: { ...toFile(prepared.row), deleteUrl: `${deps.baseUrl}/d/${prepared.token}` },
        created: true,
      }
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

    async setThumbnail(
      owner: string,
      id: string,
      body: ReadableStream<Uint8Array>,
      size: number,
      contentType: string,
      limits: { maxThumbnailBytes: number },
    ): Promise<typeof File.Type> {
      if (size > limits.maxThumbnailBytes)
        throw tooLarge(`This server accepts thumbnails up to ${limits.maxThumbnailBytes} bytes.`)

      // Write first, publish second: the row only ever points at bytes that
      // exist. The blob key carries a fresh token (not the version) — a
      // superseded blob can't be addressed by the version formula anymore.
      const blobKey = `thumbnails/${id}-${crypto.randomUUID()}`
      await deps.blobs.put(blobKey, body, size, contentType)
      for (let attempt = 0; attempt < MAX_ID_ATTEMPTS; attempt++) {
        const row = await deps.files.get(id)
        if (!row || row.owner !== owner || row.deletedAt) {
          await deps.blobs.delete(blobKey)
          throw notFound(`No file ${id}.`)
        }
        const version = row.thumbnailVersion + 1
        const claimed = await deps.files.setThumbnail(id, row.thumbnailVersion, {
          version,
          blobKey,
          contentType,
          size,
        })
        if (!claimed) continue // another PUT published first; re-read and retry
        if (row.thumbnailVersion > 0) {
          // Best-effort: a missed purge frees nothing and a missed blob
          // delete leaves a small orphan, both fixed by nothing short of GC.
          try {
            await deps.purger.purge([`${deps.baseUrl}/t/${id}?v=${row.thumbnailVersion}`])
            if (row.thumbnailBlobKey) await deps.blobs.delete(row.thumbnailBlobKey)
          } catch (error) {
            console.error(`thumbnail ${id} v${row.thumbnailVersion}: cleanup failed:`, error)
          }
        }
        const updated = await deps.files.get(id)
        if (!updated) throw notFound(`No file ${id}.`) // deleted between claim and read
        // Report the version this request claimed — a newer PUT may have moved
        // the row on, but ours still serves its own bytes at ?v={version}.
        return toFile({ ...updated, thumbnailVersion: version, thumbnailBlobKey: blobKey })
      }
      // Every claim attempt lost; our blob isn't referenced — free it.
      await deps.blobs.delete(blobKey)
      throw new Error(`Could not claim a thumbnail version in ${MAX_ID_ATTEMPTS} attempts`)
    },

    async delete(owner: string, id: string): Promise<void> {
      const row = await deps.files.get(id)
      if (!row || row.owner !== owner) throw notFound(`No file ${id}.`)
      // Tombstone first: GETs 404 so nothing refills the edge cache during the purge,
      // and any failure below leaves the tombstone for a retried DELETE to finish.
      if (!row.deletedAt) await deps.files.markDeleted(id, deps.clock())
      const urls = [fileUrl(row)]
      // Every version ever attached: a superseded thumbnail whose cleanup
      // failed earlier must still be purged and freed now.
      for (let v = 1; v <= row.thumbnailVersion; v++)
        urls.push(`${deps.baseUrl}/t/${row.id}?v=${v}`)
      await deps.purger.purge(urls)
      // Blob last: a failure here leaves an unreachable blob, never a row that 500s.
      await deps.blobs.delete(row.blobKey)
      // Thumbnail blob keys are random now — only the current one is
      // addressable; a superseded blob whose best-effort delete failed
      // earlier stays a small orphan.
      if (row.thumbnailBlobKey) await deps.blobs.delete(row.thumbnailBlobKey)
      await deps.files.delete(id)
    },

    async startUpload(
      input: StartUploadInput,
    ): Promise<{ session: typeof UploadSession.Type; created: boolean }> {
      // Lazy expiry sweep: no timers; each new session retires up to 10 overdue.
      // Per-row failures are logged and skipped — the same row retries on the
      // next start, and one bad session never fails a new upload.
      for (const stale of await deps.uploads.expired(deps.clock(), EXPIRE_SWEEP_LIMIT)) {
        try {
          await deps.blobs.abortMultipart(stale.blobKey, stale.storageUploadId)
          await deps.uploads.transition(stale.id, stale.state, 'expired')
        } catch (error) {
          console.error(`upload ${stale.id}: expiry failed:`, error)
        }
      }
      if (input.maxFileBytes !== null && input.size > input.maxFileBytes)
        throw tooLarge(`This server accepts files up to ${input.maxFileBytes} bytes.`)

      const partCount = Math.max(1, Math.ceil(input.size / input.partBytes))
      let id = ''
      let row: UploadRow | undefined
      for (let attempt = 0; attempt < MAX_ID_ATTEMPTS && row === undefined; attempt++) {
        // Ids share one namespace with files; check before starting storage
        // so a collision doesn't create a session just to abort it.
        id = deps.ids()
        if ((await deps.files.get(id)) !== undefined || (await deps.uploads.get(id)) !== undefined)
          continue
        const storageUploadId = await deps.blobs.startMultipart(`files/${id}`, input.contentType)
        const now = new Date(Math.floor(deps.clock().getTime() / 1000) * 1000)
        const candidate: UploadRow = {
          id,
          owner: input.owner,
          blobKey: `files/${id}`,
          storageUploadId,
          filename: input.filename ?? id,
          kind: input.kind ?? kindFor(input.contentType),
          contentType: input.contentType,
          size: input.size,
          device: input.device ?? null,
          partBytes: input.partBytes,
          partCount,
          idempotencyKey: input.idempotencyKey ?? null,
          createdAt: now,
          expiresAt: new Date(now.getTime() + UPLOAD_TTL_MS),
          state: 'open',
          fileId: null,
          completingUntil: null,
        }
        try {
          const stored = await deps.uploads.insert(candidate)
          if (stored.id !== candidate.id) {
            // An idempotent repeat: free the storage session we just started.
            await deps.blobs.abortMultipart(candidate.blobKey, candidate.storageUploadId)
            return { session: sessionBody(stored), created: false }
          }
          row = stored
        } catch (error) {
          await deps.blobs.abortMultipart(candidate.blobKey, candidate.storageUploadId)
          if (attempt === MAX_ID_ATTEMPTS - 1) throw error
        }
      }
      if (row === undefined)
        throw new Error(`Could not draw a free id in ${MAX_ID_ATTEMPTS} attempts`)
      return { session: sessionBody(row), created: true }
    },

    async uploadPart(
      owner: string,
      id: string,
      n: number,
      body: ReadableStream<Uint8Array>,
      size: number,
    ): Promise<typeof PartReceipt.Type> {
      const row = await liveUpload(id, owner)
      if (row.state !== 'open')
        throw new ProtocolError(409, 'upload_incomplete', `Upload ${id} is not open.`)
      if (n < 1 || n > row.partCount)
        throw invalidRequest(`Part ${n} is outside 1..${row.partCount}.`)
      const expected =
        n === row.partCount ? row.size - row.partBytes * (row.partCount - 1) : row.partBytes
      if (size !== expected)
        throw invalidRequest(`Part ${n} must be ${expected} bytes, got ${size}.`)
      const etag = await deps.blobs.putPart(row.blobKey, row.storageUploadId, n, body, size)
      await deps.uploads.putPart(id, { number: n, size, etag })
      return { number: n, size }
    },

    async getUpload(owner: string, id: string): Promise<typeof UploadStatus.Type> {
      const row = await liveUpload(id, owner)
      const received = (await deps.uploads.parts(id)).map((part) => part.number)
      return { ...sessionBody(row), receivedParts: received }
    },

    async completeUpload(
      owner: string,
      id: string,
    ): Promise<{ file: typeof UploadedFile.Type; created: boolean }> {
      const row = await liveUpload(id, owner)
      if (row.state === 'completed' && row.fileId !== null) {
        const file = await deps.files.get(row.fileId)
        // The file it made was deleted since; there's nothing left to complete.
        if (!file || file.deletedAt) throw notFound(`No file ${row.fileId}.`)
        return { file: { ...toFile(file), deleteUrl: null }, created: false }
      }
      // Open, or a 'completing' lease that expired (a request died mid-
      // completion): every step below is idempotent, so just run them again.
      const received = await deps.uploads.parts(id)
      const byNumber = new Map(received.map((part) => [part.number, part]))
      for (let n = 1; n <= row.partCount; n++) {
        if (!byNumber.has(n))
          throw new ProtocolError(
            409,
            'upload_incomplete',
            `Part ${n} of ${row.partCount} is missing.`,
          )
      }
      // One completer at a time: the loser 409s and retries, a crashed
      // completer's lease expires so the session never locks.
      const now = deps.clock()
      const claimed = await deps.uploads.claimCompletion(
        id,
        now,
        new Date(now.getTime() + COMPLETE_LEASE_MS),
      )
      if (claimed === null)
        throw new ProtocolError(
          409,
          'upload_incomplete',
          `Upload ${id} is still completing; retry shortly.`,
        )
      // After a takeover we must touch nothing: the successor owns the
      // storage object and the file row. A re-read right before each write
      // fences a completer whose lease was taken over — a residual window
      // between the check and the write remains (no cross-store
      // transaction), which the file-id reconciliation below narrows to a
      // harmless 200.
      const checkStillOurs = async () => {
        const fresh = await deps.uploads.get(id)
        if (fresh?.state !== 'completing' || fresh.completingUntil?.getTime() !== claimed.getTime())
          throw new ProtocolError(
            409,
            'upload_incomplete',
            `Upload ${id} was taken over by a newer completion.`,
          )
      }
      const parts = received.map((part) => ({ number: part.number, etag: part.etag }))
      await checkStillOurs()
      try {
        await deps.blobs.completeMultipart(row.blobKey, row.storageUploadId, parts)
      } catch (error) {
        // Storage failing on an already-finished upload is how a superseded
        // completer learns about its takeover — check first, rethrow storage.
        await checkStillOurs()
        throw error
      }
      await checkStillOurs()
      const prepared = await prepareFile(
        {
          owner,
          contentType: row.contentType,
          size: row.size,
          filename: row.filename,
          kind: row.kind,
          device: row.device ?? undefined,
          idempotencyKey: undefined,
        },
        id,
      )
      // The session's blob key, not prepareFile's token-keyed one — the
      // completed multipart object already lives there. The id collision is
      // the gate: exactly one inserter wins 201 + the delete token.
      let stored: FileRow
      try {
        stored = await deps.files.insert({ ...prepared.row, blobKey: row.blobKey })
      } catch (error) {
        const earlier = await deps.files.get(id)
        if (earlier?.owner === owner && earlier.blobKey === row.blobKey) {
          // Ours from an earlier or overlapping attempt — unless the lease
          // was taken over, in which case that row is the successor's.
          await checkStillOurs()
          await deps.uploads.markCompleted(id, earlier.id)
          return { file: { ...toFile(earlier), deleteUrl: null }, created: false }
        }
        throw error
      }
      await checkStillOurs()
      await deps.uploads.markCompleted(id, stored.id)
      return {
        file: { ...toFile(stored), deleteUrl: `${deps.baseUrl}/d/${prepared.token}` },
        created: true,
      }
    },

    async abortUpload(owner: string, id: string): Promise<void> {
      const row = await liveUpload(id, owner)
      await deps.blobs.abortMultipart(row.blobKey, row.storageUploadId)
      await deps.uploads.delete(id)
    },
  }
}

export type Library = ReturnType<typeof createLibrary>
