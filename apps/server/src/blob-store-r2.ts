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
  // R2 enforces its 5 MiB non-final-part minimum at `complete`.
  async startMultipart(key, contentType) {
    const upload = await bucket.createMultipartUpload(key, {
      httpMetadata: { contentType },
    })
    return upload.uploadId
  },
  async putPart(key, uploadId, n, body, length) {
    const part = await bucket
      .resumeMultipartUpload(key, uploadId)
      .uploadPart(n, new Uint8Array(await new Response(body).arrayBuffer()))
    void length
    return part.etag
  },
  async completeMultipart(key, uploadId, parts) {
    await bucket
      .resumeMultipartUpload(key, uploadId)
      .complete(parts.map((p) => ({ partNumber: p.number, etag: p.etag })))
  },
  async abortMultipart(key, uploadId) {
    // Spec: aborting a finished or never-started upload is not an error.
    try {
      await bucket.resumeMultipartUpload(key, uploadId).abort()
    } catch {
      // gone already
    }
  },
})
