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

export default {
  fetch(request, env) {
    // Build lazily per isolate: a ConfigError rejects the request (visible in
    // logs, retryable) instead of being cached at startup.
    app ??= appFor(env)
    return app.fetch(request)
  },
} satisfies ExportedHandler<Env>
