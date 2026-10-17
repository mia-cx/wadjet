import { Kind } from '@wadjet/protocol'
import {
  bigint,
  customType,
  index,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uniqueIndex,
} from 'drizzle-orm/pg-core'

/**
 * Text that Postgres orders bytewise, like SQLite and the memory index do.
 * Postgres' default collation orders 'a' before 'Z'; base62 ids need code-point order.
 */
const collatedText = customType<{ data: string }>({
  dataType: () => 'text COLLATE "C"',
})

export const files = pgTable(
  'files',
  {
    id: collatedText('id').primaryKey(),
    owner: text('owner').notNull(),
    filename: text('filename').notNull(),
    extension: text('extension'),
    kind: text('kind', { enum: Kind.literals }).notNull(),
    contentType: text('content_type').notNull(),
    size: bigint('size', { mode: 'number' }).notNull(),
    device: text('device'),
    createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull(),
    blobKey: text('blob_key').notNull(),
    deleteTokenHash: text('delete_token_hash').notNull(),
    idempotencyKey: text('idempotency_key'),
    deletedAt: timestamp('deleted_at', { withTimezone: true, mode: 'date' }),
    thumbnailVersion: bigint('thumbnail_version', { mode: 'number' }).notNull().default(0),
    thumbnailBlobKey: text('thumbnail_blob_key'),
    thumbnailContentType: text('thumbnail_content_type'),
    thumbnailSize: bigint('thumbnail_size', { mode: 'number' }),
  },
  (table) => [
    uniqueIndex('files_owner_idempotency').on(table.owner, table.idempotencyKey),
    index('files_owner_created').on(table.owner, table.createdAt, table.id),
  ],
)

export const uploads = pgTable(
  'uploads',
  {
    id: collatedText('id').primaryKey(),
    owner: text('owner').notNull(),
    blobKey: text('blob_key').notNull(),
    storageUploadId: text('storage_upload_id').notNull(),
    filename: text('filename').notNull(),
    kind: text('kind', { enum: ['screenshot', 'recording'] }).notNull(),
    contentType: text('content_type').notNull(),
    size: bigint('size', { mode: 'number' }).notNull(),
    device: text('device'),
    partBytes: bigint('part_bytes', { mode: 'number' }).notNull(),
    partCount: bigint('part_count', { mode: 'number' }).notNull(),
    idempotencyKey: text('idempotency_key'),
    createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true, mode: 'date' }).notNull(),
    state: text('state', { enum: ['open', 'completed', 'expired'] }).notNull(),
    fileId: collatedText('file_id'),
  },
  (table) => [uniqueIndex('uploads_owner_idempotency').on(table.owner, table.idempotencyKey)],
)

export const uploadParts = pgTable(
  'upload_parts',
  {
    uploadId: collatedText('upload_id')
      .notNull()
      .references(() => uploads.id, { onDelete: 'cascade' }),
    number: bigint('number', { mode: 'number' }).notNull(),
    size: bigint('size', { mode: 'number' }).notNull(),
    etag: text('etag').notNull(),
  },
  (table) => [primaryKey({ columns: [table.uploadId, table.number] })],
)
