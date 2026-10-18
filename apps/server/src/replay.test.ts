import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll } from 'vitest'
import { createApp } from './app.ts'
import { memoryBlobStore } from './blob-store.ts'
import { filesystemBlobStore } from './blob-store-fs.ts'
import { loadConfig } from './config.ts'
import { memoryFileIndex } from './file-index.ts'
import { sqliteFileIndex } from './file-index-sqlite.ts'
import { noopPurger } from './ports.ts'
import { replayContract } from './replay.contract.ts'
import { loadFixtures, REPLAY_ENV } from './test-helpers.ts'
import { memoryUploadIndex } from './upload-index.ts'
import { sqliteUploadIndex } from './upload-index-sqlite.ts'

const fixtures = loadFixtures()

replayContract('memory', fixtures, (seams) =>
  createApp({
    config: loadConfig(REPLAY_ENV),
    blobs: memoryBlobStore(),
    files: memoryFileIndex(),
    uploads: memoryUploadIndex(),
    purger: noopPurger,
    ...seams,
  }),
)

const dir = mkdtempSync(join(tmpdir(), 'wadjet-replay-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
replayContract('filesystem + sqlite', fixtures, (seams) =>
  createApp({
    config: loadConfig(REPLAY_ENV),
    blobs: filesystemBlobStore(join(dir, 'blobs')),
    files: sqliteFileIndex(join(dir, 'wadjet.db')),
    uploads: sqliteUploadIndex(join(dir, 'wadjet.db')),
    purger: noopPurger,
    ...seams,
  }),
)
