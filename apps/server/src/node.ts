import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { serve } from '@hono/node-server'
import pg from 'pg'
import { createApp } from './app.ts'
import { filesystemBlobStore } from './blob-store-fs.ts'
import { s3BlobStore } from './blob-store-s3.ts'
import { cloudflarePurger } from './cloudflare-purger.ts' 
import { ConfigError, loadConfig } from './config.ts'
import { randomId, randomToken } from './crypto.ts'
import { postgresFileIndex } from './file-index-postgres.ts'
import { sqliteFileIndex } from './file-index-sqlite.ts'
import { noopPurger } from './ports.ts'

const boot = () => {
  try {
    return loadConfig(process.env)
  } catch (error) {
    if (error instanceof ConfigError) {
      console.error(`Invalid config: ${error.message}`)
      process.exit(1)
    }
    throw error
  }
}
const config = boot()

mkdirSync(config.dataDir, { recursive: true })

const blobs =
  config.blobStore.kind === 's3'
    ? s3BlobStore(config.blobStore)
    : filesystemBlobStore(join(config.dataDir, 'blobs'))

const pool =
  config.databaseUrl === null ? null : new pg.Pool({ connectionString: config.databaseUrl })
// Without a listener, an error on an idle client (DB restart, pg_terminate_backend)
// is an uncaught exception and kills the process.
pool?.on('error', (error) => console.error('Postgres idle client error:', error))

const files =
  pool === null ? sqliteFileIndex(join(config.dataDir, 'wadjet.db')) : await postgresFileIndex(pool)

const app = createApp({
  config,
  blobs,
  files,
  purger: config.cloudflarePurge
    ? cloudflarePurger({ ...config.cloudflarePurge, fetch })
    : noopPurger,
  clock: () => new Date(),
  ids: randomId,
  tokens: randomToken,
})

const server = serve({ fetch: app.fetch, port: config.port }, (info) => {
  console.log(`Wadjet Server listening on http://localhost:${info.port}`)
})

// Node runs as PID 1 in the container, where default signal handlers don't
// apply; close the server on SIGTERM/SIGINT or `docker stop` waits out the kill timeout.
const shutdown = () => server.close(() => process.exit(0))
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
