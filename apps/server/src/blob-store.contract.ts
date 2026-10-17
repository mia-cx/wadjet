import { describe, expect, it } from 'vitest'
import type { BlobStore } from './blob-store.ts'

const streamOf = (bytes: Uint8Array) =>
  new ReadableStream<Uint8Array>({
    start: (controller) => {
      controller.enqueue(bytes)
      controller.close()
    },
  })

const bytes = async (stream: ReadableStream<Uint8Array>) =>
  new Uint8Array(await new Response(stream).arrayBuffer())

const must = <T>(value: T | undefined): T => {
  if (value === undefined) throw new Error('expected a blob')
  return value
}

/** The behaviour every BlobStore implementation must satisfy. */
export const blobStoreContract = (
  name: string,
  store: () => BlobStore | Promise<BlobStore>,
  options: { minPartBytes?: number } = {},
) =>
  describe(name, () => {
    // R2 and S3 reject non-final parts under 5 MiB; emulations take anything.
    const partBytes = options.minPartBytes ?? 1024
    it('round-trips bytes', async () => {
      const blobs = await store()
      const data = new Uint8Array([0, 1, 2, 255, 10])
      await blobs.put('files/aB3xK9', streamOf(data), data.length, 'image/png')
      expect(await bytes(must(await blobs.get('files/aB3xK9')))).toEqual(data)
    })

    it('returns a mid-file range', async () => {
      const blobs = await store()
      const data = new Uint8Array([...Array(20).keys()])
      await blobs.put('k', streamOf(data), data.length, 'application/octet-stream')
      expect(await bytes(must(await blobs.get('k', { offset: 5, length: 4 })))).toEqual(
        new Uint8Array([5, 6, 7, 8]),
      )
    })

    it('returns undefined for a missing key', async () => {
      expect(await (await store()).get('nope')).toBeUndefined()
    })

    it('forgets deleted blobs and ignores deleting a missing key', async () => {
      const blobs = await store()
      const data = new Uint8Array([9])
      await blobs.put('k', streamOf(data), 1, 'image/png')
      await blobs.delete('k')
      expect(await blobs.get('k')).toBeUndefined()
      await expect(blobs.delete('k')).resolves.toBeUndefined()
    })

    const part = (fill: number) => new Uint8Array(partBytes).fill(fill)
    const tail = new Uint8Array([7, 8, 9]) // the last part may be small

    it('completes a multipart upload whose parts landed out of order', async () => {
      const blobs = await store()
      const uploadId = await blobs.startMultipart('files/mp', 'application/octet-stream')
      const p1 = part(1)
      const etags = new Map<number, string>()
      // Parts can land in any order; the complete list sets the byte order.
      etags.set(2, await blobs.putPart('files/mp', uploadId, 2, streamOf(tail), tail.length))
      etags.set(1, await blobs.putPart('files/mp', uploadId, 1, streamOf(p1), p1.length))
      await blobs.completeMultipart('files/mp', uploadId, [
        { number: 1, etag: etags.get(1)! },
        { number: 2, etag: etags.get(2)! },
      ])
      const joined = new Uint8Array(p1.length + tail.length)
      joined.set(p1, 0)
      joined.set(tail, p1.length)
      expect(await bytes(must(await blobs.get('files/mp')))).toEqual(joined)
    }, 60_000)

    it('a resent part replaces the earlier copy', async () => {
      const blobs = await store()
      const uploadId = await blobs.startMultipart('files/re', 'application/octet-stream')
      const first = part(1)
      const second = part(2)
      await blobs.putPart('files/re', uploadId, 1, streamOf(first), first.length)
      const etag = await blobs.putPart('files/re', uploadId, 1, streamOf(second), second.length)
      const tailEtag = await blobs.putPart('files/re', uploadId, 2, streamOf(tail), tail.length)
      await blobs.completeMultipart('files/re', uploadId, [
        { number: 1, etag },
        { number: 2, etag: tailEtag },
      ])
      const joined = new Uint8Array(second.length + tail.length)
      joined.set(second, 0)
      joined.set(tail, second.length)
      expect(await bytes(must(await blobs.get('files/re')))).toEqual(joined)
    }, 60_000)

    it('completing a finished upload again is a no-op', async () => {
      const blobs = await store()
      const uploadId = await blobs.startMultipart('files/tw', 'application/octet-stream')
      const p1 = part(3)
      const etag = await blobs.putPart('files/tw', uploadId, 1, streamOf(p1), p1.length)
      const parts = [{ number: 1, etag }]
      await blobs.completeMultipart('files/tw', uploadId, parts)
      // A retried complete (the upload row was gone but the object landed)
      // must not error — completeMultipart is idempotent.
      await blobs.completeMultipart('files/tw', uploadId, parts)
      expect(await bytes(must(await blobs.get('files/tw')))).toEqual(p1)
    }, 60_000)

    it("abort frees an upload's parts and writes no blob", async () => {
      const blobs = await store()
      const uploadId = await blobs.startMultipart('files/ab', 'application/octet-stream')
      const p1 = part(1)
      await blobs.putPart('files/ab', uploadId, 1, streamOf(p1), p1.length)
      await blobs.abortMultipart('files/ab', uploadId)
      expect(await blobs.get('files/ab')).toBeUndefined()
      // Aborting twice or on an unknown id is not an error.
      await expect(blobs.abortMultipart('files/ab', uploadId)).resolves.toBeUndefined()
      await expect(blobs.abortMultipart('files/ab', 'nope')).resolves.toBeUndefined()
    }, 60_000)
  })
