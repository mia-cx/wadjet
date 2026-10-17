import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll } from 'vitest'
import { blobStoreContract } from './blob-store.contract.ts'
import { memoryBlobStore } from './blob-store.ts'
import { filesystemBlobStore } from './blob-store-fs.ts'

blobStoreContract('memoryBlobStore', memoryBlobStore)

const dir = mkdtempSync(join(tmpdir(), 'wadjet-blobs-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
blobStoreContract('filesystemBlobStore', () => filesystemBlobStore(dir))
