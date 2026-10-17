import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { type BlobStore, memoryBlobStore } from './blob-store.ts'
import { filesystemBlobStore } from './blob-store-fs.ts'

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

const contract = (name: string, store: () => BlobStore) =>
  describe(name, () => {
    it('round-trips bytes', async () => {
      const blobs = store()
      const data = new Uint8Array([0, 1, 2, 255, 10])
      await blobs.put('files/aB3xK9', streamOf(data), data.length, 'image/png')
      expect(await bytes(must(await blobs.get('files/aB3xK9')))).toEqual(data)
    })

    it('returns a mid-file range', async () => {
      const blobs = store()
      const data = new Uint8Array([...Array(20).keys()])
      await blobs.put('k', streamOf(data), data.length, 'application/octet-stream')
      expect(await bytes(must(await blobs.get('k', { offset: 5, length: 4 })))).toEqual(
        new Uint8Array([5, 6, 7, 8]),
      )
    })

    it('returns undefined for a missing key', async () => {
      expect(await store().get('nope')).toBeUndefined()
    })

    it('forgets deleted blobs and ignores deleting a missing key', async () => {
      const blobs = store()
      const data = new Uint8Array([9])
      await blobs.put('k', streamOf(data), 1, 'image/png')
      await blobs.delete('k')
      expect(await blobs.get('k')).toBeUndefined()
      await expect(blobs.delete('k')).resolves.toBeUndefined()
    })
  })

contract('memoryBlobStore', memoryBlobStore)

const dir = mkdtempSync(join(tmpdir(), 'wadjet-blobs-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
contract('filesystemBlobStore', () => filesystemBlobStore(dir))
