import type { Discovery } from '@wadjet/protocol'
import { Schema } from 'effect'

export class ConfigError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ConfigError'
  }
}

export interface Config {
  readonly baseUrl: string
  readonly apiKeys: ReadonlyMap<string, string>
  readonly dataDir: string
  readonly port: number
  readonly limits: typeof Discovery.Type.limits
}

/** The config an App needs at request time. */
export type AppConfig = Pick<Config, 'baseUrl' | 'apiKeys' | 'limits'>

const fail = (name: string, reason: string): never => {
  throw new ConfigError(`${name}: ${reason}`)
}

const decode = <S extends Schema.ConstraintDecoder<unknown>>(
  name: string,
  schema: S,
  value: string,
): S['Type'] => {
  try {
    return Schema.decodeUnknownSync(schema)(value)
  } catch (error) {
    return fail(
      name,
      String(error)
        .replace(/^SchemaError:/, '')
        .trim(),
    )
  }
}

const intEnv = <S extends Schema.ConstraintDecoder<number>>(
  env: Record<string, string | undefined>,
  name: string,
  schema: S,
  fallback: number,
): number => {
  const value = env[name]
  return value === undefined ? fallback : decode(name, schema, value)
}

const int = Schema.NumberFromString.check(Schema.isInt())
const nonNegative = int.check(Schema.isGreaterThanOrEqualTo(0))
const positive = int.check(Schema.isGreaterThanOrEqualTo(1))
const port = int.check(Schema.isBetween({ minimum: 1, maximum: 65535 }))
const apiKeysSchema: Schema.ConstraintDecoder<Record<string, string>> = Schema.fromJsonString(
  Schema.Record(Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)), Schema.NonEmptyString),
)

const parseBaseUrl = (value: string): string => {
  let url: URL
  try {
    url = new URL(value)
  } catch {
    return fail('WADJET_BASE_URL', 'not a URL')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:')
    return fail('WADJET_BASE_URL', 'must be http or https')
  if (url.pathname !== '/' || url.search || url.hash)
    return fail('WADJET_BASE_URL', 'must have no path, query, or fragment')
  return url.origin
}

/**
 * Reads `WADJET_*` env vars into a Config. Throws ConfigError, whose message
 * names the offending variable, when any value is missing or malformed.
 */
export const loadConfig = (env: Record<string, string | undefined>): Config => {
  const baseUrlValue = env.WADJET_BASE_URL
  if (baseUrlValue === undefined) return fail('WADJET_BASE_URL', 'is required')
  const baseUrl = parseBaseUrl(baseUrlValue)

  const apiKeysValue = env.WADJET_API_KEYS
  if (apiKeysValue === undefined) return fail('WADJET_API_KEYS', 'is required')
  const apiKeys = decode('WADJET_API_KEYS', apiKeysSchema, apiKeysValue)
  if (Object.keys(apiKeys).length === 0) fail('WADJET_API_KEYS', 'needs at least one key')

  return {
    baseUrl,
    apiKeys: new Map(Object.entries(apiKeys)),
    dataDir: env.WADJET_DATA_DIR ?? './data',
    port: intEnv(env, 'PORT', port, 8787),
    limits: {
      maxRequestBytes: intEnv(env, 'WADJET_MAX_REQUEST_BYTES', nonNegative, 100_000_000),
      partBytes: intEnv(env, 'WADJET_PART_BYTES', positive, 67_108_864),
      maxFileBytes:
        env.WADJET_MAX_FILE_BYTES === undefined
          ? null
          : decode('WADJET_MAX_FILE_BYTES', nonNegative, env.WADJET_MAX_FILE_BYTES),
      maxThumbnailBytes: intEnv(env, 'WADJET_MAX_THUMBNAIL_BYTES', nonNegative, 262_144),
    },
  }
}

export const discoveryOf = (config: AppConfig): typeof Discovery.Type => ({
  protocol: 'wadjet',
  versions: [1],
  auth: { apiKey: true, oauth: null }, // oauth arrives in #53
  limits: config.limits,
})
