export interface UploadPart {
  readonly number: number
  readonly size: number
  readonly etag: string
}

export interface UploadRow {
  readonly id: string
  readonly owner: string
  /** The blob key the completed file lands under. */
  readonly blobKey: string
  /** The blob store's own multipart-upload id. */
  readonly storageUploadId: string
  readonly filename: string
  readonly kind: 'screenshot' | 'recording'
  readonly contentType: string
  readonly size: number
  readonly device: string | null
  readonly partBytes: number
  readonly partCount: number
  readonly idempotencyKey: string | null
  readonly createdAt: Date
  /** When the session stops accepting calls (24 h after `createdAt`). */
  readonly expiresAt: Date
  /** 'open' accepts parts; 'completed' has a file; 'expired' answers 410. */
  readonly state: 'open' | 'completed' | 'expired'
  /** The file the completed upload produced; null until completion finishes. */
  readonly fileId: string | null
}

/**
 * Multipart upload sessions, mirroring FileIndex's shape: one row per
 * session, one table of received parts. Completed rows keep `fileId` so a
 * retried complete returns the same file; expired rows stay `expired` so
 * every call answers 410 instead of recreating the session.
 */
export interface UploadIndex {
  /**
   * Returns the row the index now holds for the owner's idempotency key:
   * `row` itself, or the owner's earlier row with the same key. Throws when
   * `row.id` is taken.
   */
  insert(row: UploadRow): Promise<UploadRow>
  get(id: string): Promise<UploadRow | undefined>
  /** Stores part `n` (replacing any earlier copy — a resent part upserts). */
  putPart(uploadId: string, part: UploadPart): Promise<void>
  /** The upload's received parts, by part number. */
  parts(uploadId: string): Promise<readonly UploadPart[]>
  /**
   * Moves the row `from` one state `to` another, setting `fileId` when given.
   * Returns false when the row is no longer in `from` — the conditional
   * update is what stops two concurrent completes producing two files.
   */
  transition(
    id: string,
    from: UploadRow['state'],
    to: UploadRow['state'],
    fileId?: string,
  ): Promise<boolean>
  delete(id: string): Promise<void>
  /** Up to `limit` open rows whose `expiresAt` passed, for the lazy sweeper. */
  expired(now: Date, limit: number): Promise<readonly UploadRow[]>
}

/** In-memory upload index for tests and the fixture replay. */
export const memoryUploadIndex = (): UploadIndex => {
  const rows = new Map<string, UploadRow>()
  const parts = new Map<string, Map<number, UploadPart>>()
  return {
    insert(row) {
      const existing =
        row.idempotencyKey === null
          ? undefined
          : [...rows.values()].find(
              (r) => r.owner === row.owner && r.idempotencyKey === row.idempotencyKey,
            )
      if (existing) return Promise.resolve(existing)
      if (rows.has(row.id)) return Promise.reject(new Error(`Upload ${row.id} already exists`))
      rows.set(row.id, row)
      return Promise.resolve(row)
    },
    get(id) {
      return Promise.resolve(rows.get(id))
    },
    putPart(uploadId, part) {
      let session = parts.get(uploadId)
      if (!session) {
        session = new Map()
        parts.set(uploadId, session)
      }
      session.set(part.number, part)
      return Promise.resolve()
    },
    parts(uploadId) {
      return Promise.resolve(
        [...(parts.get(uploadId)?.values() ?? [])].sort((a, b) => a.number - b.number),
      )
    },
    transition(id, from, to, fileId) {
      const row = rows.get(id)
      if (!row || row.state !== from) return Promise.resolve(false)
      rows.set(id, { ...row, state: to, fileId: fileId ?? row.fileId })
      return Promise.resolve(true)
    },
    delete(id) {
      rows.delete(id)
      parts.delete(id)
      return Promise.resolve()
    },
    expired(now, limit) {
      const due = [...rows.values()]
        .filter((row) => row.state === 'open' && row.expiresAt.getTime() <= now.getTime())
        .slice(0, limit)
      for (const row of due) rows.set(row.id, { ...row, state: 'expired' })
      return Promise.resolve(due)
    },
  }
}
