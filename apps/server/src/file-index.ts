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
}

export interface Cursor {
  readonly createdAt: Date
  readonly id: string
}

/** A file's canonical path name: `id.ext` with its stored extension, else bare `id`. */
export const canonicalName = (row: Pick<FileRow, 'id' | 'extension'>): string =>
  row.extension ? `${row.id}.${row.extension}` : row.id

export interface FileIndex {
  insert(row: FileRow): Promise<void>
  get(id: string): Promise<FileRow | undefined>
  findByIdempotencyKey(owner: string, key: string): Promise<FileRow | undefined>
  /** The owner's files newest first by (createdAt desc, id desc), strictly after `after`, at most `limit`. */
  list(owner: string, limit: number, after?: Cursor): Promise<readonly FileRow[]>
  delete(id: string): Promise<void>
}

/** In-memory file index; orders `id` with a binary string compare like SQLite. */
export const memoryFileIndex = (): FileIndex => {
  const rows = new Map<string, FileRow>()
  return {
    insert(row) {
      rows.set(row.id, row)
      return Promise.resolve()
    },
    get(id) {
      return Promise.resolve(rows.get(id))
    },
    findByIdempotencyKey(owner, key) {
      return Promise.resolve(
        [...rows.values()].find((row) => row.owner === owner && row.idempotencyKey === key),
      )
    },
    list(owner, limit, after) {
      const at = after === undefined ? -1 : after.createdAt.getTime()
      const page = [...rows.values()]
        .filter(
          (row) =>
            row.owner === owner &&
            (after === undefined ||
              row.createdAt.getTime() < at ||
              (row.createdAt.getTime() === at && row.id < after.id)),
        )
        .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime() || (a.id < b.id ? 1 : -1))
        .slice(0, limit)
      return Promise.resolve(page)
    },
    delete(id) {
      rows.delete(id)
      return Promise.resolve()
    },
  }
}
