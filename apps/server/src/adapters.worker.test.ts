import { env } from 'cloudflare:workers'
import { blobStoreContract } from './blob-store.contract.ts'
import { r2BlobStore } from './blob-store-r2.ts'
import { fileIndexContract } from './file-index.contract.ts'
import { d1FileIndex } from './file-index-d1.ts'

blobStoreContract('r2BlobStore', () => r2BlobStore(env.BLOBS))

fileIndexContract('d1FileIndex', async () => {
  await env.DB.prepare('DELETE FROM files').run()
  return d1FileIndex(env.DB)
})
