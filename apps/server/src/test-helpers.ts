import { type AppDeps, createApp } from './app.ts'
import { memoryBlobStore } from './blob-store.ts'
import { memoryFileIndex } from './file-index.ts'
import { noopPurger } from './ports.ts'

/** sha256('wdj_test') */
export const TEST_KEY = 'wdj_test'
export const TEST_KEY_HASH = '03f36b92ae4ec74db2353830df8ae8eb9fc0ddccf990550f8934952709c6ceba'
/** sha256('wdj_a'), sha256('wdj_b') */
export const KEY_A = 'wdj_a'
export const KEY_A_HASH = '10cd3c65166fb74bb130baa1a8a2439cef8b394598b50256053f27efe41917d9'
export const KEY_B = 'wdj_b'
export const KEY_B_HASH = 'f04d1ba2b4d1bffbe35b8d23001bfdd677f61757358d792ed915565088193637'

/** An app on the memory adapters for endpoint tests; every dep is overridable. */
export const testApp = (overrides: Partial<AppDeps> = {}) => {
  const files = memoryFileIndex()
  const blobs = memoryBlobStore()
  let idCounter = 0
  let tokenCounter = 0
  const app = createApp({
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
