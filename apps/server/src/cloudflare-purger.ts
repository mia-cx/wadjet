import type { CachePurger } from './ports.ts'

// Purge-by-URL limit per call on non-Enterprise plans.
const URLS_PER_PURGE = 30

interface CloudflarePurgerOptions {
  readonly zoneId: string
  readonly apiToken: string
  readonly fetch: typeof globalThis.fetch
}

interface PurgeResponse {
  readonly success?: boolean
  readonly errors?: readonly unknown[]
}

/** Purges URLs from a Cloudflare zone's edge cache after a file is deleted. */
export const cloudflarePurger = (options: CloudflarePurgerOptions): CachePurger => {
  const { zoneId, apiToken, fetch } = options
  return {
    async purge(urls) {
      for (let at = 0; at < urls.length; at += URLS_PER_PURGE) {
        const response = await fetch(
          `https://api.cloudflare.com/client/v4/zones/${zoneId}/purge_cache`,
          {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${apiToken}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({ files: urls.slice(at, at + URLS_PER_PURGE) }),
          },
        )
        // A gateway error can answer with HTML; keep the status in the error.
        const body = (await response.json().catch(() => ({}))) as PurgeResponse
        if (!response.ok || body.success !== true) {
          throw new Error(
            `Cloudflare purge failed (${response.status}): ${JSON.stringify(body.errors ?? body)}`,
          )
        }
      }
    },
  }
}
