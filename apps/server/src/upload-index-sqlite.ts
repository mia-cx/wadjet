import { fileURLToPath } from 'node:url'
import Database from 'better-sqlite3'
import { drizzle } from 'drizzle-orm/better-sqlite3'
import { migrate } from 'drizzle-orm/better-sqlite3/migrator'
import type { UploadIndex } from './upload-index.ts'
import { drizzleUploadIndex } from './upload-index-drizzle.ts'

const migrationsFolder = fileURLToPath(new URL('../drizzle', import.meta.url).href)

/** Upload index backed by SQLite through Drizzle, for the Node server. */
export const sqliteUploadIndex = (path: string): UploadIndex => {
  const db = drizzle(new Database(path))
  migrate(db, { migrationsFolder })
  return drizzleUploadIndex(db)
}
