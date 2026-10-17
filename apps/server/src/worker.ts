import { type AppDeps, createApp } from './app.ts'
import { r2BlobStore } from './blob-store-r2.ts'
import { cloudflarePurger } from './cloudflare-purger.ts'
import { loadConfig } from './config.ts'
import { randomId, randomToken } from './crypto.ts'
import { d1FileIndex } from './file-index-d1.ts'
import { noopPurger } from './ports.ts'

/** The Worker's bindings: R2 for blobs, D1 for the index, `WADJET_*` vars for config. */
export interface Env {
  readonly BLOBS: R2Bucket
  readonly DB: D1Database
  readonly [name: `WADJET_${string}`]: string | undefined
}

/**
 * Builds the app for a Worker environment. Tests override `seams` (clock, ids,
 * tokens) to replay fixtures deterministically.
 */
export const appFor = (
  env: Env,
  seams: Partial<Pick<AppDeps, 'clock' | 'ids' | 'tokens'>> = {},
) => {
  const vars: Record<string, string | undefined> = {}
  for (const [name, value] of Object.entries(env)) {
    if (name.startsWith('WADJET_') && typeof value === 'string') vars[name] = value
  }
  const config = loadConfig(vars)
  return createApp({
    config,
    blobs: r2BlobStore(env.BLOBS),
    files: d1FileIndex(env.DB),
    purger: config.cloudflarePurge
      ? cloudflarePurger({ ...config.cloudflarePurge, fetch })
      : noopPurger,
    clock: () => new Date(),
    ids: randomId,
    tokens: randomToken,
    ...seams,
  })
}

let app: ReturnType<typeof appFor> | undefined

/**
 * Serves file GETs from the zone's edge cache (`caches.default`), so the
 * `s-maxage` response and the purge-by-URL on delete actually reach the edge —
 * Workers responses never enter the zone cache by themselves.
 */
export default {
  async fetch(request, env, ctx) {
    // Build lazily per isolate: a ConfigError rejects the request (visible in
    // logs, retryable) instead of being cached at startup.
    app ??= appFor(env)
    if (request.method !== 'GET') return await app.fetch(request)
    // The cache key drops the query: it is exactly the URL the purger deletes.
    const url = new URL(request.url)
    const key = new URL(url.pathname, url.origin)
    const matched = await caches.default.match(new Request(key, { headers: request.headers }))
    if (matched) return matched
    const response = await app.fetch(request)
    if (
      response.status === 200 &&
      response.headers.get('Cache-Control')?.includes('public') &&
      !request.headers.has('Range')
    ) {
      ctx.waitUntil(caches.default.put(key, response.clone()))
    }
    return response
  },
} satisfies ExportedHandler<Env>
