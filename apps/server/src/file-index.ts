import type { Kind } from '@wadjet/protocol'

type FileKind = (typeof Kind)['Type']

export interface FileRow {
  readonly id: string
  readonly owner: string
  readonly filename: string
  readonly extension: string | null
  readonly kind: FileKind
  readonly contentType: string
  readonly size: number
  readonly device: string | null
  /** Whole seconds. */
  readonly createdAt: Date
  readonly blobKey: string
  readonly deleteTokenHash: string
  readonly idempotencyKey: string | null
  /** When the row was tombstoned for deletion; `null` while the file is live. */
  readonly deletedAt: Date | null
  /** Thumbnail version, 0 while the file has none; the URL is `/t/{id}?v={n}`. */
  readonly thumbnailVersion: number
  readonly thumbnailBlobKey: string | null
  readonly thumbnailContentType: string | null
  readonly thumbnailSize: number | null
}

/** The thumbnail blob a `setThumbnail` stores on the row. */
export interface Thumbnail {
  readonly version: number
  readonly blobKey: string
  readonly contentType: string
  readonly size: number
}

export interface Cursor {
  readonly createdAt: Date
  readonly id: string
}

/** A file's canonical path name: `id.ext` with its stored extension, else bare `id`. */
export const canonicalName = (row: Pick<FileRow, 'id' | 'extension'>): string =>
  row.extension ? `${row.id}.${row.extension}` : row.id

export interface FileIndex {
  /**
   * Returns the row the index now holds for the owner's idempotency key:
   * `row` itself, or the owner's earlier row with the same key. Throws when
   * `row.id` is taken.
   */
  insert(row: FileRow): Promise<FileRow>
  get(id: string): Promise<FileRow | undefined>
  findByIdempotencyKey(owner: string, key: string): Promise<FileRow | undefined>
  /** The file a `/d/{token}` link deletes, looked up by the token's sha256. */
  findByDeleteTokenHash(hash: string): Promise<FileRow | undefined>
  /** The owner's live files newest first by (createdAt desc, id desc), strictly after `after`, at most `limit`. Tombstones are excluded. */
  list(owner: string, limit: number, after?: Cursor): Promise<readonly FileRow[]>
  /**
   * Tombstones the row: sets `deletedAt` and releases its idempotency key, so a
   * retried upload with the same key legitimately creates a new file. `get`
   * still returns the row so a retried DELETE can finish the teardown.
   */
  markDeleted(id: string, at: Date): Promise<void>
  /** Attaches a new thumbnail as version `expectedVersion + 1`; returns false
   * when the row's version moved on (a concurrent PUT won) — retry the claim. */
  setThumbnail(id: string, expectedVersion: number, thumbnail: Thumbnail): Promise<boolean>
  delete(id: string): Promise<void>
}

/** In-memory file index; orders `id` with a binary string compare like SQLite. */
export const memoryFileIndex = (): FileIndex => {
  const rows = new Map<string, FileRow>()
  return {
    insert(row) {
      const existing =
        row.idempotencyKey === null
          ? undefined
          : [...rows.values()].find(
              (r) => r.owner === row.owner && r.idempotencyKey === row.idempotencyKey,
            )
      if (existing) return Promise.resolve(existing)
      if (rows.has(row.id)) return Promise.reject(new Error(`File ${row.id} already exists`))
      rows.set(row.id, row)
      return Promise.resolve(row)
    },
    get(id) {
      return Promise.resolve(rows.get(id))
    },
    findByIdempotencyKey(owner, key) {
      return Promise.resolve(
        [...rows.values()].find((row) => row.owner === owner && row.idempotencyKey === key),
      )
    },
    findByDeleteTokenHash(hash) {
      return Promise.resolve([...rows.values()].find((row) => row.deleteTokenHash === hash))
    },
    list(owner, limit, after) {
      const at = after === undefined ? -1 : after.createdAt.getTime()
      const page = [...rows.values()]
        .filter(
          (row) =>
            row.owner === owner &&
            row.deletedAt === null &&
            (after === undefined ||
              row.createdAt.getTime() < at ||
              (row.createdAt.getTime() === at && row.id < after.id)),
        )
        .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime() || (a.id < b.id ? 1 : -1))
        .slice(0, limit)
      return Promise.resolve(page)
    },
    markDeleted(id, at) {
      const row = rows.get(id)
      if (row) rows.set(id, { ...row, deletedAt: at, idempotencyKey: null })
      return Promise.resolve()
    },
    setThumbnail(id, expectedVersion, thumbnail) {
      const row = rows.get(id)
      if (!row || row.thumbnailVersion !== expectedVersion) return Promise.resolve(false)
      rows.set(id, {
        ...row,
        thumbnailVersion: thumbnail.version,
        thumbnailBlobKey: thumbnail.blobKey,
        thumbnailContentType: thumbnail.contentType,
        thumbnailSize: thumbnail.size,
      })
      return Promise.resolve(true)
    },
    delete(id) {
      rows.delete(id)
      return Promise.resolve()
    },
  }
}
