import { drizzle } from 'drizzle-orm/d1'
import type { FileIndex } from './file-index.ts'
import { drizzleFileIndex } from './file-index-drizzle.ts'

/** File index backed by D1. Migrations are applied by Wrangler, not here. */
export const d1FileIndex = (d1: D1Database): FileIndex => drizzleFileIndex(drizzle(d1))
