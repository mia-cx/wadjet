import type { Discovery } from '@wadjet/protocol'
import { Schema } from 'effect'
import type { S3BlobStoreOptions } from './blob-store-s3.ts'

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
  readonly blobStore:
    | { readonly kind: 'filesystem' }
    | ({ readonly kind: 's3' } & S3BlobStoreOptions)
  /** Null means the SQLite index under dataDir. */
  readonly databaseUrl: string | null
  readonly cloudflarePurge: { readonly zoneId: string; readonly apiToken: string } | null
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

const requireEnv = (env: Record<string, string | undefined>, name: string): string => {
  const value = env[name]
  if (value === undefined || value === '') return fail(name, 'is required')
  return value
}

const parseBlobStore = (env: Record<string, string | undefined>): Config['blobStore'] => {
  const kind = env.WADJET_BLOB_STORE ?? 'filesystem'
  if (kind === 'filesystem') return { kind }
  if (kind !== 's3') return fail('WADJET_BLOB_STORE', 'must be filesystem or s3')

  const endpoint = requireEnv(env, 'WADJET_S3_ENDPOINT')
  let url: URL
  try {
    url = new URL(endpoint)
  } catch {
    return fail('WADJET_S3_ENDPOINT', 'not a URL')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:')
    return fail('WADJET_S3_ENDPOINT', 'must be http or https')

  const pathStyle = env.WADJET_S3_FORCE_PATH_STYLE
  if (pathStyle !== undefined && pathStyle !== 'true' && pathStyle !== 'false')
    return fail('WADJET_S3_FORCE_PATH_STYLE', 'must be true or false')

  return {
    kind,
    endpoint,
    bucket: requireEnv(env, 'WADJET_S3_BUCKET'),
    region: env.WADJET_S3_REGION ?? 'auto',
    accessKeyId: requireEnv(env, 'WADJET_S3_ACCESS_KEY_ID'),
    secretAccessKey: requireEnv(env, 'WADJET_S3_SECRET_ACCESS_KEY'),
    forcePathStyle: pathStyle === 'true',
  }
}

const parseDatabaseUrl = (env: Record<string, string | undefined>): string | null => {
  const value = env.WADJET_DATABASE_URL
  if (value === undefined) return null
  if (!value.startsWith('postgres://') && !value.startsWith('postgresql://'))
    return fail('WADJET_DATABASE_URL', 'must be a postgres:// or postgresql:// URL')
  return value
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

  // '' is unset: Docker/compose ships empty vars for the unset case.
  const zoneId = env.WADJET_CLOUDFLARE_ZONE_ID || undefined
  const apiToken = env.WADJET_CLOUDFLARE_API_TOKEN || undefined
  if (zoneId !== undefined && apiToken === undefined)
    fail('WADJET_CLOUDFLARE_API_TOKEN', 'is required when WADJET_CLOUDFLARE_ZONE_ID is set')
  if (apiToken !== undefined && zoneId === undefined)
    fail('WADJET_CLOUDFLARE_ZONE_ID', 'is required when WADJET_CLOUDFLARE_API_TOKEN is set')

  const blobStore = parseBlobStore(env)
  const partBytes = intEnv(env, 'WADJET_PART_BYTES', positive, 67_108_864)
  // S3 rejects non-final multipart parts under 5 MiB.
  const S3_MIN_PART_BYTES = 5 * 1024 * 1024
  if (blobStore.kind === 's3' && partBytes < S3_MIN_PART_BYTES)
    fail('WADJET_PART_BYTES', `must be at least ${S3_MIN_PART_BYTES} for the S3 blob store`)

  return {
    baseUrl,
    apiKeys: new Map(Object.entries(apiKeys)),
    dataDir: env.WADJET_DATA_DIR ?? './data',
    cloudflarePurge: zoneId !== undefined && apiToken !== undefined ? { zoneId, apiToken } : null,
    port: intEnv(env, 'PORT', port, 8787),
    blobStore,
    databaseUrl: parseDatabaseUrl(env),
    limits: {
      maxRequestBytes: intEnv(env, 'WADJET_MAX_REQUEST_BYTES', nonNegative, 100_000_000),
      partBytes,
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
