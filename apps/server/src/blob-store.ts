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
}

/** In-memory blob store for tests and the fixture replay. */
export const memoryBlobStore = (): BlobStore => {
  const blobs = new Map<string, Uint8Array>()
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
  }
}
