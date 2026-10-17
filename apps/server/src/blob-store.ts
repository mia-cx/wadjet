export interface ByteRange {
  readonly offset: number
  readonly length: number
}

/** Blob storage keyed by paths such as `files/{id}`. */
export interface BlobStore {
  put(
    key: string,
    body: ReadableStream<Uint8Array>,
    length: number,
    contentType: string,
  ): Promise<void>
  /** The blob's bytes, or just `range` of them; undefined when no blob has the key. */
  get(key: string, range?: ByteRange): Promise<ReadableStream<Uint8Array> | undefined>
  /** Removes the blob; a missing key is not an error. */
  delete(key: string): Promise<void>
  /** Starts a storage-level multipart upload for `key`; returns the store's upload id. */
  startMultipart(key: string, contentType: string): Promise<string>
  /** Stores part `n` (replacing any earlier copy); returns its etag. */
  putPart(
    key: string,
    uploadId: string,
    n: number,
    body: ReadableStream<Uint8Array>,
    length: number,
  ): Promise<string>
  /** Assembles `key` from the parts, in `parts` order. */
  completeMultipart(
    key: string,
    uploadId: string,
    parts: readonly { number: number; etag: string }[],
  ): Promise<void>
  /** Frees the parts; aborting an unknown/finished upload is not an error. */
  abortMultipart(key: string, uploadId: string): Promise<void>
}

/** In-memory blob store for tests and the fixture replay. */
export const memoryBlobStore = (): BlobStore => {
  const blobs = new Map<string, Uint8Array>()
  // `${uploadId}:${key}` → part number → bytes
  const parts = new Map<string, Map<number, Uint8Array>>()
  return {
    async put(key, body) {
      const chunks: Uint8Array[] = []
      let size = 0
      for await (const chunk of body) {
        chunks.push(chunk)
        size += chunk.length
      }
      const bytes = new Uint8Array(size)
      let at = 0
      for (const chunk of chunks) {
        bytes.set(chunk, at)
        at += chunk.length
      }
      blobs.set(key, bytes)
    },
    get(key, range) {
      const bytes = blobs.get(key)
      if (!bytes) return Promise.resolve(undefined)
      const slice = range ? bytes.subarray(range.offset, range.offset + range.length) : bytes
      return Promise.resolve(
        new ReadableStream({
          start: (c) => {
            c.enqueue(slice)
            c.close()
          },
        }),
      )
    },
    delete(key) {
      blobs.delete(key)
      return Promise.resolve()
    },
    startMultipart(key, contentType) {
      void contentType
      const uploadId = crypto.randomUUID()
      parts.set(`${uploadId}:${key}`, new Map())
      return Promise.resolve(uploadId)
    },
    async putPart(key, uploadId, n, body) {
      const session = parts.get(`${uploadId}:${key}`)
      if (!session) throw new Error(`No multipart upload ${uploadId} for ${key}`)
      const bytes = new Uint8Array(await new Response(body).arrayBuffer())
      session.set(n, bytes)
      return `mem-${n}`
    },
    completeMultipart(key, uploadId, partList) {
      const session = parts.get(`${uploadId}:${key}`)
      if (!session) return Promise.reject(new Error(`No multipart upload ${uploadId} for ${key}`))
      const chunks: Uint8Array[] = []
      let size = 0
      for (const part of partList) {
        const bytes = session.get(part.number)
        if (!bytes) return Promise.reject(new Error(`Part ${part.number} was never uploaded`))
        chunks.push(bytes)
        size += bytes.length
      }
      const out = new Uint8Array(size)
      let at = 0
      for (const bytes of chunks) {
        out.set(bytes, at)
        at += bytes.length
      }
      blobs.set(key, out)
      parts.delete(`${uploadId}:${key}`)
      return Promise.resolve()
    },
    abortMultipart(key, uploadId) {
      parts.delete(`${uploadId}:${key}`)
      return Promise.resolve()
    },
  }
}
