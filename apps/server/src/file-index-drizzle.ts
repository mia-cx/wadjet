import { and, desc, eq, isNull, lt, or, type SQL } from 'drizzle-orm'
import type { BaseSQLiteDatabase } from 'drizzle-orm/sqlite-core'
import { files } from './db/schema.ts'
import type { FileIndex } from './file-index.ts'

/** Queries shared by the sync (better-sqlite3) and async (D1) SQLite dialects. */
export const drizzleFileIndex = (db: BaseSQLiteDatabase<'sync' | 'async', unknown>): FileIndex => ({
  async insert(row) {
    const inserted = await db
      .insert(files)
      .values(row)
      .onConflictDoNothing({ target: [files.owner, files.idempotencyKey] })
      .returning()
      .get()
    const key = row.idempotencyKey
    if (inserted || key === null) return inserted ?? row
    // The (owner, idempotency_key) conflict lost to an earlier row; hand it back.
    const earlier = await db
      .select()
      .from(files)
      .where(and(eq(files.owner, row.owner), eq(files.idempotencyKey, key)))
      .get()
    if (!earlier) throw new Error(`Insert of ${row.id} conflicted but no earlier row exists`)
    return earlier
  },
  async findByDeleteTokenHash(hash) {
    const row = await db.select().from(files).where(eq(files.deleteTokenHash, hash)).get()
    return row
  },
  async get(id) {
    const row = await db.select().from(files).where(eq(files.id, id)).get()
    return row
  },
  async findByIdempotencyKey(owner, key) {
    const row = await db
      .select()
      .from(files)
      .where(and(eq(files.owner, owner), eq(files.idempotencyKey, key)))
      .get()
    return row
  },
  async list(owner, limit, after) {
    const where: SQL[] = [eq(files.owner, owner), isNull(files.deletedAt)]
    if (after) {
      const sameTime = and(eq(files.createdAt, after.createdAt), lt(files.id, after.id))
      const condition = sameTime
        ? or(lt(files.createdAt, after.createdAt), sameTime)
        : lt(files.createdAt, after.createdAt)
      if (condition) where.push(condition)
    }
    const rows = await db
      .select()
      .from(files)
      .where(and(...where))
      .orderBy(desc(files.createdAt), desc(files.id))
      .limit(limit)
      .all()
    return rows
  },
  async setThumbnail(id, expectedVersion, thumbnail) {
    const changed = (await db
      .update(files)
      .set({
        thumbnailVersion: thumbnail.version,
        thumbnailBlobKey: thumbnail.blobKey,
        thumbnailContentType: thumbnail.contentType,
        thumbnailSize: thumbnail.size,
      })
      .where(and(eq(files.id, id), eq(files.thumbnailVersion, expectedVersion)))
      .run()) as { changes?: number; meta?: { changes?: number } }
    return (changed.changes ?? changed.meta?.changes ?? 0) > 0
  },
  async markDeleted(id, at) {
    await db
      .update(files)
      .set({ deletedAt: at, idempotencyKey: null })
      .where(eq(files.id, id))
      .run()
  },
  async delete(id) {
    await db.delete(files).where(eq(files.id, id)).run()
  },
})
