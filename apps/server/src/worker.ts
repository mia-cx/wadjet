import { type AppDeps, createApp } from './app.ts'
import { r2BlobStore } from './blob-store-r2.ts'
import { cloudflarePurger } from './cloudflare-purger.ts'
import { ConfigError, loadConfig } from './config.ts'
import { randomId, randomToken } from './crypto.ts'
import { d1FileIndex } from './file-index-d1.ts'
import { noopPurger } from './ports.ts'
import { d1UploadIndex } from './upload-index-d1.ts'

/** The Worker's bindings: R2 for blobs, D1 for the index, `WADJET_*` vars for config. */
export interface Env {
  readonly BLOBS: R2Bucket
  readonly DB: D1Database
  readonly [name: `WADJET_${string}`]: string | undefined
}

/** The `WADJET_*` string bindings in `env` as a Config. */
const configFor = (env: Env) => {
  const vars: Record<string, string | undefined> = {}
  for (const [name, value] of Object.entries(env)) {
    if (name.startsWith('WADJET_') && typeof value === 'string') vars[name] = value
  }
  return loadConfig(vars)
}

/**
 * Builds the app for a Worker environment. Tests override `seams` (clock, ids,
 * tokens) to replay fixtures deterministically.
 */
// R2 rejects non-final multipart parts under 5 MiB.
const R2_MIN_PART_BYTES = 5 * 1024 * 1024

export const appFor = (
  env: Env,
  seams: Partial<
    Pick<AppDeps, 'blobs' | 'files' | 'uploads' | 'purger' | 'clock' | 'ids' | 'tokens'>
  > = {},
) => {
  const config = configFor(env)
  const blobs = seams.blobs ?? r2BlobStore(env.BLOBS)
  if (seams.blobs === undefined && config.limits.partBytes < R2_MIN_PART_BYTES)
    throw new ConfigError(
      `WADJET_PART_BYTES must be at least ${R2_MIN_PART_BYTES}: R2 rejects smaller multipart parts.`,
    )
  return createApp({
    config,
    blobs,
    files: d1FileIndex(env.DB),
    uploads: d1UploadIndex(env.DB),
    purger: config.cloudflarePurge
      ? cloudflarePurger({ ...config.cloudflarePurge, fetch })
      : noopPurger,
    clock: () => new Date(),
    ids: randomId,
    tokens: randomToken,
    ...seams,
  })
}

/**
 * The Worker entrypoint. Caches file GETs at the zone's edge — only when a
 * purger exists to clear them, since Workers responses never enter the zone
 * cache by themselves. Range requests always go to storage: `cache.match`
 * applies its own Range handling, which breaks the protocol's full-200
 * fallback for unsatisfiable and multi-range requests.
 */
export const createHandler = (
  seams: Parameters<typeof appFor>[1] = {},
): Required<Pick<ExportedHandler<Env>, 'fetch'>> => {
  let state: { app: ReturnType<typeof appFor>; edgeCache: boolean } | undefined
  return {
    async fetch(request, env, ctx) {
      // Build lazily per isolate: a ConfigError rejects the request (visible in
      // logs, retryable) instead of being cached at startup.
      state ??= { app: appFor(env, seams), edgeCache: configFor(env).cloudflarePurge !== null }
      if (!state.edgeCache || request.method !== 'GET' || request.headers.has('Range')) {
        return await state.app.fetch(request)
      }
      // The cache key is exactly the URL the purger deletes: path only for
      // files, `/t/{id}?v={n}` (the only meaningful param) for thumbnails.
      const url = new URL(request.url)
      const v = url.searchParams.get('v')
      const key = new URL(
        url.pathname.startsWith('/t/') && v !== null ? `${url.pathname}?v=${v}` : url.pathname,
        url.origin,
      )
      const matched = await caches.default.match(new Request(key))
      if (matched) return matched
      const response = await state.app.fetch(request)
      if (
        (response.status === 200 || response.status === 206) &&
        response.headers.get('Cache-Control')?.includes('public')
      ) {
        ctx.waitUntil(caches.default.put(key, response.clone()))
      }
      return response
    },
  }
}

export default createHandler()
