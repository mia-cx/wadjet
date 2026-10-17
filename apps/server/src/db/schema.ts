import { Kind } from '@wadjet/protocol'
import { index, integer, sqliteTable, text, uniqueIndex } from 'drizzle-orm/sqlite-core'

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
  },
  (table) => [
    uniqueIndex('files_owner_idempotency').on(table.owner, table.idempotencyKey),
    index('files_owner_created').on(table.owner, table.createdAt, table.id),
  ],
)
