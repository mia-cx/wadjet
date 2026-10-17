import { fileURLToPath } from 'node:url'
import { and, asc, eq, lte } from 'drizzle-orm'
import { drizzle } from 'drizzle-orm/node-postgres'
import { migrate } from 'drizzle-orm/node-postgres/migrator'
import type pg from 'pg'
import { uploadParts, uploads } from './db/schema-pg.ts'
import type { UploadIndex } from './upload-index.ts'

const migrationsFolder = fileURLToPath(new URL('../drizzle-pg', import.meta.url).href)

// Same advisory lock as postgresFileIndex — they share the migration journal.
const MIGRATION_LOCK_KEY = 1879048912

/**
 * Upload index backed by Postgres through Drizzle, for the Node server.
 * Applies pending migrations on creation; the caller owns `pool`.
 */
export const postgresUploadIndex = async (pool: pg.Pool): Promise<UploadIndex> => {
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
        .insert(uploads)
        .values(row)
        .onConflictDoNothing({ target: [uploads.owner, uploads.idempotencyKey] })
        .returning()
      if (inserted[0] || row.idempotencyKey === null) return inserted[0] ?? row
      const earlier = await db
        .select()
        .from(uploads)
        .where(and(eq(uploads.owner, row.owner), eq(uploads.idempotencyKey, row.idempotencyKey)))
      if (!earlier[0]) throw new Error(`Insert of ${row.id} conflicted but no earlier row exists`)
      return earlier[0]
    },
    async get(id) {
      const rows = await db.select().from(uploads).where(eq(uploads.id, id))
      return rows[0]
    },
    async putPart(uploadId, part) {
      await db
        .insert(uploadParts)
        .values({ uploadId, ...part })
        .onConflictDoUpdate({
          target: [uploadParts.uploadId, uploadParts.number],
          set: { size: part.size, etag: part.etag },
        })
    },
    async parts(uploadId) {
      const rows = await db
        .select({ number: uploadParts.number, size: uploadParts.size, etag: uploadParts.etag })
        .from(uploadParts)
        .where(eq(uploadParts.uploadId, uploadId))
        .orderBy(asc(uploadParts.number))
      return rows
    },
    async transition(id, from, to, fileId) {
      const changed = await db
        .update(uploads)
        .set({ state: to, ...(fileId === undefined ? {} : { fileId }) })
        .where(and(eq(uploads.id, id), eq(uploads.state, from)))
      return (changed.rowCount ?? 0) > 0
    },
    async delete(id) {
      await db.delete(uploads).where(eq(uploads.id, id))
    },
    async expired(now, limit) {
      const due = await db
        .select()
        .from(uploads)
        .where(and(eq(uploads.state, 'open'), lte(uploads.expiresAt, now)))
        .limit(limit)
      for (const row of due) {
        await db
          .update(uploads)
          .set({ state: 'expired' })
          .where(and(eq(uploads.id, row.id), eq(uploads.state, 'open')))
      }
      return due
    },
  }
}
