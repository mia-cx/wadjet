import { env } from 'cloudflare:workers'
import { blobStoreContract } from './blob-store.contract.ts'
import { r2BlobStore } from './blob-store-r2.ts'
import { fileIndexContract } from './file-index.contract.ts'
import { d1FileIndex } from './file-index-d1.ts'
import { uploadIndexContract } from './upload-index.contract.ts'
import { d1UploadIndex } from './upload-index-d1.ts'

blobStoreContract('r2BlobStore', () => r2BlobStore(env.BLOBS), { minPartBytes: 5 * 1024 * 1024 })

fileIndexContract('d1FileIndex', async () => {
  await env.DB.prepare('DELETE FROM files').run()
  return d1FileIndex(env.DB)
})

uploadIndexContract('d1UploadIndex', async () => {
  await env.DB.prepare('DELETE FROM upload_parts').run()
  await env.DB.prepare('DELETE FROM uploads').run()
  return d1UploadIndex(env.DB)
})
