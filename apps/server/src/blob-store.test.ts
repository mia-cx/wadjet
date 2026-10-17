import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { blobStoreContract } from './blob-store.contract.ts'
import { memoryBlobStore } from './blob-store.ts'
import { filesystemBlobStore } from './blob-store-fs.ts'
import { s3BlobStore } from './blob-store-s3.ts'

blobStoreContract('memoryBlobStore', memoryBlobStore)

const dir = mkdtempSync(join(tmpdir(), 'wadjet-blobs-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
blobStoreContract('filesystemBlobStore', () => filesystemBlobStore(dir))

describe('filesystemBlobStore root', () => {
  it('rejects keys that resolve outside the root', async () => {
    const blobs = filesystemBlobStore(dir)
    const empty = () => new ReadableStream({ start: (ctl) => ctl.close() })
    await expect(blobs.put('../outside', empty(), 0, 'image/webp')).rejects.toThrow()
    await expect(blobs.delete('../../escape')).rejects.toThrow()
    // '..' in a stored upload id can't escape either.
    await expect(blobs.putPart('files/x', '../../up', 1, empty(), 0)).rejects.toThrow()
    await expect(blobs.abortMultipart('files/x', '../../up')).rejects.toThrow()
  })
})

describe('s3BlobStore complete', () => {
  // aws4fetch signs and then calls the global fetch — stub it, keep signing.
  const stubbed = (completeBody: string, completeStatus = 200, headStatus = 404) => {
    globalThis.fetch = async (input, init) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      // aws4fetch hands fetch a signed Request; take the method from it too.
      const method = init?.method ?? (input instanceof Request ? input.method : 'GET')
      if (method === 'POST' && url.includes('uploads'))
        return new Response(
          '<InitiateMultipartUploadResult><UploadId>u1</UploadId></InitiateMultipartUploadResult>',
        )
      if (method === 'PUT') return new Response(null, { status: 200, headers: { ETag: 'e1' } })
      if (method === 'POST' && url.includes('uploadId='))
        return new Response(completeBody, { status: completeStatus })
      if (method === 'HEAD') return new Response(null, { status: headStatus })
      return new Response(null, { status: 404 })
    }
    return s3BlobStore({
      endpoint: 'https://s3.test',
      bucket: 'b',
      region: 'r',
      accessKeyId: 'a',
      secretAccessKey: 's',
      forcePathStyle: true,
    })
  }

  it('a 200 with a real CompleteMultipartUploadResult succeeds', async () => {
    const realFetch = globalThis.fetch
    try {
      const blobs = stubbed(
        '<CompleteMultipartUploadResult><ETag>ok</ETag></CompleteMultipartUploadResult>',
      )
      const uploadId = await blobs.startMultipart('files/k', 'application/octet-stream')
      const etag = await blobs.putPart(
        'files/k',
        uploadId,
        1,
        new ReadableStream({
          start: (c) => {
            c.enqueue(new Uint8Array([1]))
            c.close()
          },
        }),
        1,
      )
      await expect(
        blobs.completeMultipart('files/k', uploadId, [{ number: 1, etag }]),
      ).resolves.toBeUndefined()
    } finally {
      globalThis.fetch = realFetch
    }
  })

  it('a 200 with an <Error> body is a failure, not a success', async () => {
    const realFetch = globalThis.fetch
    try {
      const blobs = stubbed('<Error><Code>InternalError</Code></Error>')
      const uploadId = await blobs.startMultipart('files/k', 'application/octet-stream')
      const etag = await blobs.putPart(
        'files/k',
        uploadId,
        1,
        new ReadableStream({
          start: (c) => {
            c.enqueue(new Uint8Array([1]))
            c.close()
          },
        }),
        1,
      )
      await expect(
        blobs.completeMultipart('files/k', uploadId, [{ number: 1, etag }]),
      ).rejects.toThrow('completeMultipart')
    } finally {
      globalThis.fetch = realFetch
    }
  })
})
