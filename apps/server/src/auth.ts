import { sha256Hex } from './crypto.ts'

/** Resolves an `Authorization` header value to an owner, or undefined when invalid. */
export type Authenticate = (authorization: string | undefined) => Promise<string | undefined>

/** API keys are `wdj_`-prefixed; the map holds their SHA-256 hex hashes to owners. */
export const apiKeyAuth =
  (apiKeys: ReadonlyMap<string, string>): Authenticate =>
  async (authorization) => {
    const credential = authorization?.match(/^Bearer (\S+)$/)?.[1]
    if (!credential?.startsWith('wdj_')) return undefined
    return apiKeys.get(await sha256Hex(credential))
  }
