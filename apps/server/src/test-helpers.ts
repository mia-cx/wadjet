import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath, URL } from 'node:url'
import { type AppDeps, createApp } from './app.ts'
import { memoryBlobStore } from './blob-store.ts'
import { memoryFileIndex } from './file-index.ts'
import { noopPurger } from './ports.ts'
import type { Fixture, ReplayFixtures } from './replay.contract.ts'
import { memoryUploadIndex } from './upload-index.ts'

/** sha256('wdj_test') */
export const TEST_KEY = 'wdj_test'
export const TEST_KEY_HASH = '03f36b92ae4ec74db2353830df8ae8eb9fc0ddccf990550f8934952709c6ceba'
/** sha256('wdj_a'), sha256('wdj_b') */
export const KEY_A = 'wdj_a'
export const KEY_A_HASH = '10cd3c65166fb74bb130baa1a8a2439cef8b394598b50256053f27efe41917d9'
export const KEY_B = 'wdj_b'
export const KEY_B_HASH = 'f04d1ba2b4d1bffbe35b8d23001bfdd677f61757358d792ed915565088193637'

/** The API key the protocol fixtures authenticate with. */
export const REPLAY_API_KEY = 'wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g'
/** sha256(REPLAY_API_KEY) */
const REPLAY_API_KEY_HASH = '3eaed6f03b7ae41f089a96edcd9c729ed0e3d8309d8abc07b5ed76efaa5ceaf7'

/** The replay config in `WADJET_*` env-var form, for `loadConfig` on either runtime. */
export const REPLAY_ENV = {
  WADJET_BASE_URL: 'https://w.mia.cx',
  WADJET_API_KEYS: JSON.stringify({ [REPLAY_API_KEY_HASH]: 'mia' }),
  WADJET_MAX_REQUEST_BYTES: '4096',
  WADJET_PART_BYTES: '1024',
  WADJET_MAX_THUMBNAIL_BYTES: '1024',
}

const fixturesDir = fileURLToPath(new URL('../../../packages/protocol/fixtures/', import.meta.url))

/** Reads packages/protocol/fixtures: `*.json` as fixtures, other files base64-encoded. */
export const loadFixtures = (): ReplayFixtures => {
  const fixtures: Fixture[] = []
  const files: Record<string, string> = {}
  for (const name of readdirSync(fixturesDir).sort()) {
    const content = readFileSync(join(fixturesDir, name))
    if (name.endsWith('.json')) fixtures.push(JSON.parse(content.toString('utf8')) as Fixture)
    else files[name] = content.toString('base64')
  }
  return { fixtures, files }
}

/** An app on the memory adapters for endpoint tests; every dep is overridable. */
export const testApp = (overrides: Partial<AppDeps> = {}) => {
  const files = memoryFileIndex()
  const blobs = memoryBlobStore()
  let idCounter = 0
  let tokenCounter = 0
  const app = createApp({
    uploads: memoryUploadIndex(),
    config: {
      baseUrl: 'https://w.mia.cx',
      apiKeys: new Map([[TEST_KEY_HASH, 'mia']]),
      limits: {
        maxRequestBytes: 100_000_000,
        partBytes: 67_108_864,
        maxFileBytes: null,
        maxThumbnailBytes: 262_144,
      },
    },
    files,
    blobs,
    purger: noopPurger,
    clock: () => new Date('2026-10-16T12:00:00Z'),
    ids: () => `id${String(idCounter++).padStart(4, '0')}`,
    tokens: () => `token${tokenCounter++}`,
    ...overrides,
  })
  return { app, files, blobs }
}

export const upload = (
  app: ReturnType<typeof createApp>,
  init: { body?: Uint8Array; headers?: Record<string, string>; key?: string } = {},
) => {
  const body = init.body ?? new Uint8Array([1, 2, 3])
  return app.request('/v1/files', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${init.key ?? TEST_KEY}`,
      'Content-Type': 'image/png',
      'Content-Length': String(body.byteLength),
      ...init.headers,
    },
    body,
  })
}
