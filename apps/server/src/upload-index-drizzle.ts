import { and, asc, eq, lte, or } from 'drizzle-orm'
import type { BaseSQLiteDatabase } from 'drizzle-orm/sqlite-core'
import { uploadParts, uploads } from './db/schema.ts'
import type { UploadIndex } from './upload-index.ts'

/** Queries shared by the sync (better-sqlite3) and async (D1) SQLite dialects. */
export const drizzleUploadIndex = (
  db: BaseSQLiteDatabase<'sync' | 'async', unknown>,
): UploadIndex => ({
  async insert(row) {
    const inserted = await db
      .insert(uploads)
      .values(row)
      .onConflictDoNothing({ target: [uploads.owner, uploads.idempotencyKey] })
      .returning()
      .get()
    const key = row.idempotencyKey
    if (inserted || key === null) return inserted ?? row
    // The (owner, idempotency_key) conflict lost to an earlier row; hand it back.
    const earlier = await db
      .select()
      .from(uploads)
      .where(and(eq(uploads.owner, row.owner), eq(uploads.idempotencyKey, key)))
      .get()
    if (!earlier) throw new Error(`Insert of ${row.id} conflicted but no earlier row exists`)
    return earlier
  },
  async get(id) {
    const row = await db.select().from(uploads).where(eq(uploads.id, id)).get()
    return row
  },
  async putPart(uploadId, part) {
    await db
      .insert(uploadParts)
      .values({ uploadId, ...part })
      .onConflictDoUpdate({
        target: [uploadParts.uploadId, uploadParts.number],
        set: { size: part.size, etag: part.etag },
      })
      .run()
  },
  async parts(uploadId) {
    const rows = await db
      .select({ number: uploadParts.number, size: uploadParts.size, etag: uploadParts.etag })
      .from(uploadParts)
      .where(eq(uploadParts.uploadId, uploadId))
      .orderBy(asc(uploadParts.number))
      .all()
    return rows
  },
  async transition(id, from, to, fileId) {
    const changed = (await db
      .update(uploads)
      .set({ state: to, ...(fileId === undefined ? {} : { fileId }) })
      .where(and(eq(uploads.id, id), eq(uploads.state, from)))
      .run()) as { changes?: number; meta?: { changes?: number } }
    return (changed.changes ?? changed.meta?.changes ?? 0) > 0
  },
  async claimCompletion(id, now, until) {
    const changed = (await db
      .update(uploads)
      .set({ state: 'completing', completingUntil: until })
      .where(
        and(
          eq(uploads.id, id),
          or(
            eq(uploads.state, 'open'),
            and(eq(uploads.state, 'completing'), lte(uploads.completingUntil, now)),
          ),
        ),
      )
      .run()) as { changes?: number; meta?: { changes?: number } }
    return (changed.changes ?? changed.meta?.changes ?? 0) > 0
  },
  async markCompleted(id, fileId) {
    await db
      .update(uploads)
      .set({ state: 'completed', fileId, completingUntil: null })
      .where(eq(uploads.id, id))
      .run()
  },
  async delete(id) {
    await db.delete(uploads).where(eq(uploads.id, id)).run()
  },
  async expired(now, limit) {
    return await db
      .select()
      .from(uploads)
      .where(and(eq(uploads.state, 'open'), lte(uploads.expiresAt, now)))
      .limit(limit)
      .all()
  },
})
