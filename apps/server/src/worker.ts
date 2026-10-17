import { type AppDeps, createApp } from './app.ts'
import { r2BlobStore } from './blob-store-r2.ts'
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
  seams: Partial<Pick<AppDeps, 'blobs' | 'files' | 'uploads' | 'clock' | 'ids' | 'tokens'>> = {},
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
    // No purger on the Worker: its responses never enter the zone cache, so
    // there is nothing to purge. Purge exists where ordinary zone caching
    // does — the Node/Docker server behind a proxied zone.
    purger: noopPurger,
    clock: () => new Date(),
    ids: randomId,
    tokens: randomToken,
    ...seams,
  })
}

/**
 * The Worker entrypoint. No edge-cache layer: `caches.default` entries can't
 * be purged by zone purge-by-URL, and a `waitUntil(cache.put)` can land after
 * a delete — every request goes straight to the app.
 */
export const createHandler = (
  seams: Parameters<typeof appFor>[1] = {},
): Required<Pick<ExportedHandler<Env>, 'fetch'>> => {
  let app: ReturnType<typeof appFor> | undefined
  return {
    async fetch(request, env) {
      // Build lazily per isolate: a ConfigError rejects the request (visible in
      // logs, retryable) instead of being cached at startup.
      app ??= appFor(env, seams)
      return await app.fetch(request)
    },
  }
}

export default createHandler()
