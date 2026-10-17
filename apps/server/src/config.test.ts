import { spawnSync } from 'node:child_process'
import { fileURLToPath, URL } from 'node:url'
import { describe, expect, it } from 'vitest'
import { loadConfig } from './config.ts'

const GOOD = {
  WADJET_BASE_URL: 'https://w.mia.cx',
  WADJET_API_KEYS: `{"${'a'.repeat(64)}": "mia"}`,
}

describe('loadConfig', () => {
  it.each([
    ['missing WADJET_BASE_URL', { WADJET_API_KEYS: GOOD.WADJET_API_KEYS }, 'WADJET_BASE_URL'],
    ['non-URL base URL', { ...GOOD, WADJET_BASE_URL: 'not a url' }, 'WADJET_BASE_URL'],
    ['base URL with a path', { ...GOOD, WADJET_BASE_URL: 'https://w.mia.cx/x' }, 'WADJET_BASE_URL'],
    ['WADJET_API_KEYS not JSON', { ...GOOD, WADJET_API_KEYS: 'nope' }, 'WADJET_API_KEYS'],
    ['a non-hex key', { ...GOOD, WADJET_API_KEYS: '{"zzz": "mia"}' }, 'WADJET_API_KEYS'],
    ['PORT abc', { ...GOOD, PORT: 'abc' }, 'PORT'],
    [
      'WADJET_MAX_REQUEST_BYTES -1',
      { ...GOOD, WADJET_MAX_REQUEST_BYTES: '-1' },
      'WADJET_MAX_REQUEST_BYTES',
    ],
  ])('rejects %s', (_name, env, variable) => {
    expect(() => loadConfig(env)).toThrowError(
      expect.objectContaining({ message: expect.stringContaining(variable) }),
    )
  })

  it('defaults a minimal env', () => {
    const config = loadConfig(GOOD)
    expect(config.dataDir).toBe('./data')
    expect(config.port).toBe(8787)
    expect(config.limits).toEqual({
      maxRequestBytes: 100000000,
      partBytes: 67108864,
      maxFileBytes: null,
      maxThumbnailBytes: 262144,
    })
    expect(config.apiKeys.get('a'.repeat(64))).toBe('mia')
    expect(config.cloudflarePurge).toBeNull()
  })

  it('reads the Cloudflare purge pair', () => {
    const config = loadConfig({
      ...GOOD,
      WADJET_CLOUDFLARE_ZONE_ID: 'zone123',
      WADJET_CLOUDFLARE_API_TOKEN: 'token456',
    })
    expect(config.cloudflarePurge).toEqual({ zoneId: 'zone123', apiToken: 'token456' })
  })

  it.each([
    [
      'WADJET_CLOUDFLARE_API_TOKEN without a zone',
      { ...GOOD, WADJET_CLOUDFLARE_API_TOKEN: 'token456' },
      'WADJET_CLOUDFLARE_ZONE_ID',
    ],
    [
      'WADJET_CLOUDFLARE_ZONE_ID without a token',
      { ...GOOD, WADJET_CLOUDFLARE_ZONE_ID: 'zone123' },
      'WADJET_CLOUDFLARE_API_TOKEN',
    ],
  ])('rejects %s', (_name, env, variable) => {
    expect(() => loadConfig(env)).toThrowError(
      expect.objectContaining({ message: expect.stringContaining(variable) }),
    )
  })

  it('stops boot on a bad env', () => {
    const entry = fileURLToPath(new URL('./node.ts', import.meta.url))
    const result = spawnSync(process.execPath, [entry], {
      env: { PATH: process.env.PATH },
      encoding: 'utf8',
    })
    expect(result.status).not.toBe(0)
    expect(result.stderr).toContain('WADJET_BASE_URL')
  })
})
