import { drizzle } from 'drizzle-orm/d1'
import type { UploadIndex } from './upload-index.ts'
import { drizzleUploadIndex } from './upload-index-drizzle.ts'

/** Upload index backed by D1 through Drizzle, for the Cloudflare Worker. */
export const d1UploadIndex = (db: D1Database): UploadIndex => drizzleUploadIndex(drizzle(db))
