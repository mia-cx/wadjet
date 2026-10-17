import { fileURLToPath } from 'node:url'
import Database from 'better-sqlite3'
import { and, desc, eq, lt, or, type SQL } from 'drizzle-orm'
import { drizzle } from 'drizzle-orm/better-sqlite3'
import { migrate } from 'drizzle-orm/better-sqlite3/migrator'
import { files } from './db/schema.ts'
import type { FileIndex } from './file-index.ts'

const migrationsFolder = fileURLToPath(new URL('../drizzle', import.meta.url))

/** File index backed by SQLite through Drizzle, for the Node server. */
export const sqliteFileIndex = (path: string): FileIndex => {
  const db = drizzle(new Database(path))
  migrate(db, { migrationsFolder })

  return {
    async insert(row) {
      const inserted = db
        .insert(files)
        .values(row)
        .onConflictDoNothing({ target: [files.owner, files.idempotencyKey] })
        .returning()
        .get()
      const key = row.idempotencyKey
      if (inserted || key === null) return inserted ?? row
      // The (owner, idempotency_key) conflict lost to an earlier row; hand it back.
      const earlier = db
        .select()
        .from(files)
        .where(and(eq(files.owner, row.owner), eq(files.idempotencyKey, key)))
        .get()
      if (!earlier) throw new Error(`Insert of ${row.id} conflicted but no earlier row exists`)
      return earlier
    },
    async get(id) {
      const row = db.select().from(files).where(eq(files.id, id)).get()
      return row
    },
    async findByIdempotencyKey(owner, key) {
      const row = db
        .select()
        .from(files)
        .where(and(eq(files.owner, owner), eq(files.idempotencyKey, key)))
        .get()
      return row
    },
    async list(owner, limit, after) {
      const where: SQL[] = [eq(files.owner, owner)]
      if (after) {
        const sameTime = and(eq(files.createdAt, after.createdAt), lt(files.id, after.id))
        const condition = sameTime
          ? or(lt(files.createdAt, after.createdAt), sameTime)
          : lt(files.createdAt, after.createdAt)
        if (condition) where.push(condition)
      }
      const rows = db
        .select()
        .from(files)
        .where(and(...where))
        .orderBy(desc(files.createdAt), desc(files.id))
        .limit(limit)
        .all()
      return rows
    },
    async delete(id) {
      db.delete(files).where(eq(files.id, id)).run()
    },
  }
}
