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
  /**
   * 'open' accepts parts; 'completing' is claimed by an in-flight complete;
   * 'completed' has a file; 'expired' answers 410.
   */
  readonly state: 'open' | 'completing' | 'completed' | 'expired'
  /** The file the completed upload produced; null until completion finishes. */
  readonly fileId: string | null
  /**
   * The lease on a 'completing' session; a complete request whose requestor
   * died can be taken over once this passes. Null on every other state.
   */
  readonly completingUntil: Date | null
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
  /**
   * Takes the completion lease: the row moves to 'completing' with
   * `completingUntil = until`, and the granted `until` comes back for the
   * caller's takeover fences. Only an open session or an expired lease can
   * be claimed — returns null when the claim was lost.
   */
  claimCompletion(id: string, now: Date, until: Date): Promise<Date | null>
  /**
   * Record the file a session completed into and release the lease; safe to
   * call repeatedly.
   */
  markCompleted(id: string, fileId: string): Promise<void>
  delete(id: string): Promise<void>
  /**
   * Up to `limit` rows whose `expiresAt` passed — open ones outright, plus
   * 'completing' ones whose lease lapsed (a crashed completer can't hold a
   * session past its TTL forever).
   */
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
    claimCompletion(id, now, until) {
      const row = rows.get(id)
      if (
        !row ||
        (row.state !== 'open' &&
          !(
            row.state === 'completing' &&
            row.completingUntil !== null &&
            row.completingUntil.getTime() <= now.getTime()
          ))
      )
        return Promise.resolve(null)
      rows.set(id, { ...row, state: 'completing', completingUntil: until })
      return Promise.resolve(until)
    },
    markCompleted(id, fileId) {
      const row = rows.get(id)
      if (row) rows.set(id, { ...row, state: 'completed', fileId, completingUntil: null })
      return Promise.resolve()
    },
    delete(id) {
      rows.delete(id)
      parts.delete(id)
      return Promise.resolve()
    },
    expired(now, limit) {
      return Promise.resolve(
        [...rows.values()]
          .filter(
            (row) =>
              row.expiresAt.getTime() <= now.getTime() &&
              (row.state === 'open' ||
                (row.state === 'completing' &&
                  row.completingUntil !== null &&
                  row.completingUntil.getTime() <= now.getTime())),
          )
          .slice(0, limit),
      )
    },
  }
}
