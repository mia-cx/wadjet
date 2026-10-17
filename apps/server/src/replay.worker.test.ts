import { env } from 'cloudflare:workers'
import { memoryBlobStore } from './blob-store.ts'
import { r2BlobStore } from './blob-store-r2.ts'
import { replayContract } from './replay.contract.ts'
import { appFor } from './worker.ts'

// R2 rejects the fixtures' 1024-byte parts at complete (its 5 MiB minimum), so
// multipart storage is emulated in memory while everything else stays on R2.
const memoryParts = memoryBlobStore()
const r2 = r2BlobStore(env.BLOBS)
const blobs: typeof r2 = {
  ...r2,
  startMultipart: memoryParts.startMultipart,
  putPart: memoryParts.putPart,
  completeMultipart: async (key, uploadId, parts) => {
    await memoryParts.completeMultipart(key, uploadId, parts)
    const body = await memoryParts.get(key)
    if (!body) throw new Error(`emulated multipart produced no ${key}`)
    const bytes = new Uint8Array(await new Response(body).arrayBuffer())
    await r2.put(
      key,
      new ReadableStream({
        start: (c) => {
          c.enqueue(bytes)
          c.close()
        },
      }),
      bytes.length,
      'application/octet-stream',
    )
  },
  abortMultipart: memoryParts.abortMultipart,
}

replayContract('worker (R2 + D1)', env.FIXTURES, (seams) => appFor(env, { ...seams, blobs }))
