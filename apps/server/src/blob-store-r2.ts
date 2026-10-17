import type { BlobStore } from './blob-store.ts'

/** Blob store backed by an R2 bucket, for the Cloudflare Worker. */
export const r2BlobStore = (bucket: R2Bucket): BlobStore => ({
  async put(key, body, length, contentType) {
    // R2 rejects streams of unknown length, so pipe through a FixedLengthStream.
    const fixed = new FixedLengthStream(length)
    await Promise.all([
      body.pipeTo(fixed.writable),
      bucket.put(key, fixed.readable, { httpMetadata: { contentType } }),
    ])
  },
  async get(key, range) {
    const object = await bucket.get(key, range ? { range } : undefined)
    return object?.body
  },
  async delete(key) {
    await bucket.delete(key)
  },
})
