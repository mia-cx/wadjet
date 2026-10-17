import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { serve } from '@hono/node-server'
import { createApp } from './app.ts'
import { filesystemBlobStore } from './blob-store-fs.ts'
import { cloudflarePurger } from './cloudflare-purger.ts'
import { ConfigError, loadConfig } from './config.ts'
import { randomId, randomToken } from './crypto.ts'
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

const app = createApp({
  config,
  blobs: filesystemBlobStore(join(config.dataDir, 'blobs')),
  files: sqliteFileIndex(join(config.dataDir, 'wadjet.db')),
  purger: config.cloudflarePurge
    ? cloudflarePurger({ ...config.cloudflarePurge, fetch })
    : noopPurger,
  clock: () => new Date(),
  ids: randomId,
  tokens: randomToken,
})

serve({ fetch: app.fetch, port: config.port }, (info) => {
  console.log(`Wadjet Server listening on http://localhost:${info.port}`)
})
