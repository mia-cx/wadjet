import { fileURLToPath } from 'node:url'
import { and, desc, eq, isNull, lt, or, type SQL } from 'drizzle-orm'
import { drizzle } from 'drizzle-orm/node-postgres'
import { migrate } from 'drizzle-orm/node-postgres/migrator'
import type pg from 'pg'
import { files } from './db/schema-pg.ts'
import type { FileIndex } from './file-index.ts'

const migrationsFolder = fileURLToPath(new URL('../drizzle-pg', import.meta.url).href)

// Serializes concurrent boots: drizzle's migrate races on a fresh database.
const MIGRATION_LOCK_KEY = 1879048912

/**
 * File index backed by Postgres through Drizzle, for the Node server.
 * Applies pending migrations on creation; the caller owns `pool`.
 */
export const postgresFileIndex = async (pool: pg.Pool): Promise<FileIndex> => {
  const client = await pool.connect()
  try {
    await client.query('SELECT pg_advisory_lock($1)', [MIGRATION_LOCK_KEY])
    await migrate(drizzle(client), { migrationsFolder })
  } finally {
    await client.query('SELECT pg_advisory_unlock($1)', [MIGRATION_LOCK_KEY])
    client.release()
  }

  const db = drizzle(pool)

  return {
    async insert(row) {
      const inserted = await db
        .insert(files)
        .values(row)
        .onConflictDoNothing({ target: [files.owner, files.idempotencyKey] })
        .returning()
      if (inserted[0] || row.idempotencyKey === null) return inserted[0] ?? row
      // The (owner, idempotency_key) conflict lost to an earlier row; hand it back.
      const earlier = await db
        .select()
        .from(files)
        .where(and(eq(files.owner, row.owner), eq(files.idempotencyKey, row.idempotencyKey)))
      if (!earlier[0]) throw new Error(`Insert of ${row.id} conflicted but no earlier row exists`)
      return earlier[0]
    },
    async get(id) {
      const rows = await db.select().from(files).where(eq(files.id, id))
      return rows[0]
    },
    async findByIdempotencyKey(owner, key) {
      const rows = await db
        .select()
        .from(files)
        .where(and(eq(files.owner, owner), eq(files.idempotencyKey, key)))
      return rows[0]
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
      return db
        .select()
        .from(files)
        .where(and(...where))
        .orderBy(desc(files.createdAt), desc(files.id))
        .limit(limit)
    },
    async setThumbnail(id, expectedVersion, thumbnail) {
      const changed = await db
        .update(files)
        .set({
          thumbnailVersion: thumbnail.version,
          thumbnailBlobKey: thumbnail.blobKey,
          thumbnailContentType: thumbnail.contentType,
          thumbnailSize: thumbnail.size,
        })
        .where(and(eq(files.id, id), eq(files.thumbnailVersion, expectedVersion)))
      return (changed.rowCount ?? 0) > 0
    },
    async markDeleted(id, at) {
      await db.update(files).set({ deletedAt: at, idempotencyKey: null }).where(eq(files.id, id))
    },
    async delete(id) {
      await db.delete(files).where(eq(files.id, id))
    },
  }
}
