import { Kind } from '@wadjet/protocol'
import { index, integer, primaryKey, sqliteTable, text, uniqueIndex } from 'drizzle-orm/sqlite-core'

export const files = sqliteTable(
  'files',
  {
    id: text('id').primaryKey(),
    owner: text('owner').notNull(),
    filename: text('filename').notNull(),
    extension: text('extension'),
    kind: text('kind', { enum: Kind.literals }).notNull(),
    contentType: text('content_type').notNull(),
    size: integer('size').notNull(),
    device: text('device'),
    createdAt: integer('created_at', { mode: 'timestamp' }).notNull(),
    blobKey: text('blob_key').notNull(),
    deleteTokenHash: text('delete_token_hash').notNull(),
    idempotencyKey: text('idempotency_key'),
    deletedAt: integer('deleted_at', { mode: 'timestamp' }),
    thumbnailVersion: integer('thumbnail_version').notNull().default(0),
    thumbnailBlobKey: text('thumbnail_blob_key'),
    thumbnailContentType: text('thumbnail_content_type'),
    thumbnailSize: integer('thumbnail_size'),
  },
  (table) => [
    uniqueIndex('files_owner_idempotency').on(table.owner, table.idempotencyKey),
    index('files_owner_created').on(table.owner, table.createdAt, table.id),
  ],
)

/** A multipart upload session; its parts live in uploadParts. */
export const uploads = sqliteTable(
  'uploads',
  {
    id: text('id').primaryKey(),
    owner: text('owner').notNull(),
    blobKey: text('blob_key').notNull(),
    storageUploadId: text('storage_upload_id').notNull(),
    filename: text('filename').notNull(),
    kind: text('kind', { enum: ['screenshot', 'recording'] }).notNull(),
    contentType: text('content_type').notNull(),
    size: integer('size').notNull(),
    device: text('device'),
    partBytes: integer('part_bytes').notNull(),
    partCount: integer('part_count').notNull(),
    idempotencyKey: text('idempotency_key'),
    createdAt: integer('created_at', { mode: 'timestamp' }).notNull(),
    expiresAt: integer('expires_at', { mode: 'timestamp' }).notNull(),
    state: text('state', { enum: ['open', 'completing', 'completed', 'expired'] }).notNull(),
    fileId: text('file_id'),
    /// Lease on an in-flight complete; a stale one can be taken over.
    completingUntil: integer('completing_until', { mode: 'timestamp' }),
  },
  (table) => [uniqueIndex('uploads_owner_idempotency').on(table.owner, table.idempotencyKey)],
)

/** One received part of a multipart upload; resends upsert by (uploadId, number). */
export const uploadParts = sqliteTable(
  'upload_parts',
  {
    uploadId: text('upload_id')
      .notNull()
      .references(() => uploads.id, { onDelete: 'cascade' }),
    number: integer('number').notNull(),
    size: integer('size').notNull(),
    etag: text('etag').notNull(),
  },
  (table) => [primaryKey({ columns: [table.uploadId, table.number] })],
)
