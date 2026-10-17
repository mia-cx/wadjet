import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import type { AppDeps } from './app.ts'
import type { BlobStore } from './blob-store.ts'
import { memoryBlobStore } from './blob-store.ts'
import { filesystemBlobStore } from './blob-store-fs.ts'
import type { FileIndex } from './file-index.ts'
import { memoryFileIndex } from './file-index.ts'
import { sqliteFileIndex } from './file-index-sqlite.ts'
import { testApp, upload } from './test-helpers.ts'

type Adapters = { blobs: BlobStore; files: FileIndex }

const suite = (name: string, adapters: () => Adapters) =>
  describe(name, () => {
    const appWith = (overrides: Partial<AppDeps>) => testApp({ ...adapters(), ...overrides }).app

    it('a collided id keeps the first file’s bytes', async () => {
      const ids = ['aB3xK9', 'aB3xK9', 'Zz9Yy8']
      const app = appWith({ ids: () => ids.shift() ?? 'exhstd' })

      const first = await upload(app, { body: new Uint8Array([1, 2, 3]) })
      expect(first.status).toBe(201)
      expect(((await first.json()) as { id: string }).id).toBe('aB3xK9')

      const second = await upload(app, { body: new Uint8Array([4, 5, 6]) })
      expect(second.status).toBe(201)
      expect(((await second.json()) as { id: string }).id).toBe('Zz9Yy8')

      const served = await app.request('/aB3xK9.png')
      expect(new Uint8Array(await served.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]))
    })

    it('overlapping uploads with one Idempotency-Key resolve to one file', async () => {
      const app = appWith({})

      let release!: () => void
      const body = new ReadableStream<Uint8Array>({
        start: (controller) => {
          release = () => {
            controller.enqueue(new Uint8Array([1, 2, 3]))
            controller.close()
          }
        },
      })
      const headers = {
        Authorization: 'Bearer wdj_test',
        'Content-Type': 'image/png',
        'Content-Length': '3',
        'Idempotency-Key': 'same-request',
      }
      const first = app.request('/v1/files', {
        method: 'POST',
        headers,
        body,
        duplex: 'half',
      } as RequestInit)

      const second = await app.request('/v1/files', {
        method: 'POST',
        headers,
        body: new Uint8Array([4, 5, 6]),
      })
      expect(second.status).toBe(201)
      const winner = (await second.json()) as { id: string }

      release()
      const repeat = await first
      expect(repeat.status).toBe(200)
      const file = (await repeat.json()) as { id: string; deleteUrl: string | null }
      expect(file.id).toBe(winner.id)
      expect(file.deleteUrl).toBeNull()

      const list = await app.request('/v1/files', {
        headers: { Authorization: 'Bearer wdj_test' },
      })
      expect(((await list.json()) as { items: unknown[] }).items).toHaveLength(1)
    })
  })

suite('memory', () => ({ blobs: memoryBlobStore(), files: memoryFileIndex() }))

const dir = mkdtempSync(join(tmpdir(), 'wadjet-uploads-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
suite('filesystem + sqlite', () => ({
  blobs: filesystemBlobStore(join(dir, `blobs-${crypto.randomUUID()}`)),
  files: sqliteFileIndex(join(dir, `wadjet-${crypto.randomUUID()}.db`)),
}))
