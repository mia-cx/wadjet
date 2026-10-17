import { fileURLToPath, URL } from 'node:url'
import Database from 'better-sqlite3'
import { drizzle } from 'drizzle-orm/better-sqlite3'
import { migrate } from 'drizzle-orm/better-sqlite3/migrator'
import type { FileIndex } from './file-index.ts'
import { drizzleFileIndex } from './file-index-drizzle.ts'

const migrationsFolder = fileURLToPath(new URL('../drizzle', import.meta.url))

/** File index backed by SQLite through Drizzle, for the Node server. */
export const sqliteFileIndex = (path: string): FileIndex => {
  const db = drizzle(new Database(path))
  migrate(db, { migrationsFolder })
  return drizzleFileIndex(db)
}
