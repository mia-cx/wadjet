import { createReadStream, createWriteStream } from 'node:fs'
import { mkdir, open, rename, rm } from 'node:fs/promises'
import { dirname, resolve, sep } from 'node:path'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import type { ReadableStream as NodeReadableStream } from 'node:stream/web'
import type { BlobStore } from './blob-store.ts'

/** Blob store on the local filesystem. Keys map to files under `root`. */
export const filesystemBlobStore = (root: string): BlobStore => {
  // Every caller-facing name lands inside root or the request fails — keys
  // carry route-derived ids, so `..` must never reach the disk.
  const base = resolve(root)
  const inside = (...segments: string[]) => {
    const path = resolve(base, ...segments)
    if (!path.startsWith(base + sep))
      throw new Error(`blob key escapes the store root: ${segments.join('/')}`)
    return path
  }
  return {
    async put(key, body) {
      const path = inside(key)
      await mkdir(dirname(path), { recursive: true })
      const temp = `${path}.tmp-${crypto.randomUUID()}`
      try {
        await pipeline(
          Readable.fromWeb(body as unknown as NodeReadableStream),
          createWriteStream(temp),
        )
        await rename(temp, path)
      } catch (error) {
        await rm(temp, { force: true })
        throw error
      }
    },
    async get(key, range) {
      const path = inside(key)
      const options = range ? { start: range.offset, end: range.offset + range.length - 1 } : {}
      const stream = createReadStream(path, options)
      try {
        await new Promise<void>((resolve, reject) => {
          stream.once('open', () => resolve())
          stream.once('error', reject)
        })
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined
        throw error
      }
      return Readable.toWeb(stream) as unknown as ReadableStream<Uint8Array>
    },
    async delete(key) {
      await rm(inside(key), { force: true })
    },
    async startMultipart(_key, contentType) {
      void contentType
      const uploadId = crypto.randomUUID()
      await mkdir(inside('uploads', uploadId), { recursive: true })
      return uploadId
    },
    async putPart(key, uploadId, n, body, length) {
      void key
      const path = inside('uploads', uploadId, String(n))
      await mkdir(inside('uploads', uploadId), { recursive: true })
      const temp = `${path}.tmp-${crypto.randomUUID()}`
      try {
        await pipeline(
          Readable.fromWeb(body as unknown as NodeReadableStream),
          createWriteStream(temp),
        )
        await rename(temp, path)
      } catch (error) {
        await rm(temp, { force: true })
        throw error
      }
      return `fs-${n}-${length}`
    },
    async completeMultipart(key, uploadId, parts) {
      const dir = inside('uploads', uploadId)
      const path = inside(key)
      // Already completed: the parts dir is gone and the object exists.
      const partsDir = await open(dir).then(
        (d) => d.close().then(() => true),
        () => false,
      )
      const objectThere = await open(path).then(
        (f) => f.close().then(() => true),
        () => false,
      )
      if (!partsDir && objectThere) return
      await mkdir(dirname(path), { recursive: true })
      const temp = `${path}.tmp-${crypto.randomUUID()}`
      try {
        const out = await open(temp, 'w')
        try {
          for (const part of parts) {
            const input = await open(inside('uploads', uploadId, String(part.number)), 'r')
            try {
              for await (const chunk of input.createReadStream()) await out.write(chunk)
            } finally {
              await input.close()
            }
          }
        } finally {
          await out.close()
        }
        await rename(temp, path)
        await rm(dir, { recursive: true, force: true })
      } catch (error) {
        await rm(temp, { force: true })
        throw error
      }
    },
    async abortMultipart(key, uploadId) {
      void key
      await rm(inside('uploads', uploadId), { recursive: true, force: true })
    },
  }
}
