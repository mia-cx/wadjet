import { Kind } from '@wadjet/protocol'
import {
  bigint,
  customType,
  index,
  pgTable,
  text,
  timestamp,
  uniqueIndex,
} from 'drizzle-orm/pg-core'

/**
 * Text that Postgres orders bytewise, like SQLite and the memory index do.
 * The default collation orders 'Z' before 'a'; base62 ids need code-point order.
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
  },
  (table) => [
    uniqueIndex('files_owner_idempotency').on(table.owner, table.idempotencyKey),
    index('files_owner_created').on(table.owner, table.createdAt, table.id),
  ],
)
