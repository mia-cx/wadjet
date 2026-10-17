import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterAll, describe, expect, it } from 'vitest'
import { createApp } from './app.ts'
import { type BlobStore, memoryBlobStore } from './blob-store.ts'
import { filesystemBlobStore } from './blob-store-fs.ts'
import { sha256Hex } from './crypto.ts'
import { type FileIndex, memoryFileIndex } from './file-index.ts'
import { sqliteFileIndex } from './file-index-sqlite.ts'
import { noopPurger } from './ports.ts'

const fixturesDir = fileURLToPath(new URL('../../../packages/protocol/fixtures/', import.meta.url))

interface Fixture {
  name: string
  request: {
    method: string
    path: string
    headers: Record<string, string>
    body: unknown
  }
  response: {
    status: number
    headers: Record<string, string>
    body: unknown
  }
}

const fixtures = readdirSync(fixturesDir)
  .filter((file) => file.endsWith('.json'))
  .sort()
  .map((file) => JSON.parse(readFileSync(join(fixturesDir, file), 'utf8')) as Fixture)

// Issues #51-#53 own these fixtures; they run as todo until those land.
const todos = new Map<string, string>([
  ['01-discovery', '#53: discovery advertises OAuth'],
  ['05-attach-thumbnail', '#51: thumbnails and multipart'],
  ['06-start-upload', '#51: thumbnails and multipart'],
  ['07-upload-part-1', '#51: thumbnails and multipart'],
  ['08-upload-part-3', '#51: thumbnails and multipart'],
  ['09-complete-upload-incomplete', '#51: thumbnails and multipart'],
  ['10-get-upload', '#51: thumbnails and multipart'],
  ['11-upload-part-2', '#51: thumbnails and multipart'],
  ['12-complete-upload', '#51: thumbnails and multipart'],
  ['13-complete-upload-repeat', '#51: thumbnails and multipart'],
  ['14-start-upload-to-abort', '#51: thumbnails and multipart'],
  ['15-abort-upload', '#51: thumbnails and multipart'],
  ['16-get-upload-not-found', '#51: thumbnails and multipart'],
  ['17-list-files', '#51: list shows the multipart Recording and a thumbnailUrl'],
  ['18-list-files-next-page', '#51: list shows the multipart Recording and a thumbnailUrl'],
  ['23-get-file-range', '#51: serves the multipart Recording'],
  ['24-get-thumbnail', '#51'],
  ['25-get-thumbnail-redirect', '#51'],
  ['26-get-sharex-config', '#52'],
  ['27-get-deletion-page', '#52'],
  ['28-delete-by-link', '#52'],
  ['29-get-file-not-found', "#52: the file is gone only after 28's delete-by-link"],
  ['30-delete-file', '#51: deletes the multipart Recording'],
  ['32-start-upload-to-expire', '#51'],
  ['33-upload-part-expired', '#51'],
])

for (const name of todos.keys()) {
  if (!fixtures.some((fixture) => fixture.name === name))
    throw new Error(`todo map names a missing fixture: ${name}`)
}

const API_KEY = 'wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g'
const API_KEY_HASH = await sha256Hex(API_KEY)
const IDS = ['aB3xK9', 'Uq7Lm2', 'Pz2Wc5', 'Hn4Rt8']
const TOKENS = [
  '5mQeI1qnbywzZsvQ2MibRgZdGEmSSpZ_sh3HHTkl_FQ',
  'eIipUchuHMYCyF5sa-JRAMyV6a-jZ3htmkInxF4xd5A',
]

const peeking = (values: readonly string[], label: string) => {
  let index = 0
  return {
    peek: () => values[index],
    next: () => {
      const value = values[index++]
      if (value === undefined) throw new Error(`${label} generator exhausted`)
      return value
    },
  }
}

const replay = (name: string, adapters: () => { blobs: BlobStore; files: FileIndex }) =>
  describe(name, () => {
    let clock = new Date(0)
    const ids = peeking(IDS, 'id')
    const tokens = peeking(TOKENS, 'token')

    const app = createApp({
      ...adapters(),
      config: {
        baseUrl: 'https://w.mia.cx',
        apiKeys: new Map([[API_KEY_HASH, 'mia']]),
        limits: {
          maxRequestBytes: 4096,
          partBytes: 1024,
          maxFileBytes: null,
          maxThumbnailBytes: 1024,
        },
      },
      purger: noopPurger,
      clock: () => clock,
      ids: ids.next,
      tokens: tokens.next,
    })

    // A skipped fixture can still consume a seeded id or token; drain the
    // skipped fixtures that precede each running fixture, in story order.
    let previous = -1
    const drainSkipped = (index: number) => {
      for (const fixture of fixtures.slice(previous + 1, index)) {
        const body = fixture.response.body
        if (typeof body !== 'object' || body === null) continue
        const { id, deleteUrl } = body as { id?: unknown; deleteUrl?: unknown }
        if (id !== undefined && id === ids.peek()) ids.next()
        if (
          typeof deleteUrl === 'string' &&
          tokens.peek() !== undefined &&
          deleteUrl.split('/').at(-1) === tokens.peek()
        )
          tokens.next()
      }
      previous = index
    }

    for (const fixture of fixtures) {
      const reason = todos.get(fixture.name)
      if (reason !== undefined) {
        it.todo(`${fixture.name} (${reason})`)
        continue
      }
      it(fixture.name, async () => {
        drainSkipped(fixtures.indexOf(fixture))
        clock = new Date(fixture.response.headers.Date ?? 'Thu, 01 Jan 1970 00:00:00 GMT')

        let body: NonNullable<RequestInit['body']> | undefined
        if (fixture.request.body !== null) {
          body =
            fixture.request.headers['Content-Type'] === 'application/json'
              ? JSON.stringify(fixture.request.body)
              : readFileSync(join(fixturesDir, fixture.request.body as string))
        }

        const init: RequestInit = {
          method: fixture.request.method,
          headers: fixture.request.headers,
        }
        if (body !== undefined) init.body = body
        const response = await app.request(fixture.request.path, init)

        expect(response.status).toBe(fixture.response.status)
        for (const [header, expected] of Object.entries(fixture.response.headers)) {
          expect(response.headers.get(header), header).toBe(expected)
        }
        const contentType = fixture.response.headers['Content-Type'] ?? ''
        if (fixture.response.body === null) {
          expect((await response.arrayBuffer()).byteLength).toBe(0)
        } else if (contentType === 'application/json') {
          expect(await response.json()).toEqual(fixture.response.body)
        } else {
          const expected = readFileSync(join(fixturesDir, fixture.response.body as string))
          expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array(expected))
        }
      })
    }
  })

replay('memory', () => ({ blobs: memoryBlobStore(), files: memoryFileIndex() }))

const dir = mkdtempSync(join(tmpdir(), 'wadjet-replay-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
replay('filesystem + sqlite', () => ({
  blobs: filesystemBlobStore(join(dir, 'blobs')),
  files: sqliteFileIndex(join(dir, 'wadjet.db')),
}))
