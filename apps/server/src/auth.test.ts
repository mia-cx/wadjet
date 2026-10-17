import { describe, expect, it } from 'vitest'
import { TEST_KEY, testApp } from './test-helpers.ts'

describe('GET /v1/files auth', () => {
  const cases: { name: string; authorization?: string; status: number; code?: string }[] = [
    { name: 'valid key', authorization: `Bearer ${TEST_KEY}`, status: 200 },
    {
      name: 'unknown wdj_ key',
      authorization: 'Bearer wdj_unknown',
      status: 401,
      code: 'unauthorized',
    },
    {
      name: 'revoked wdj_ key',
      authorization: 'Bearer wdj_NwcSbBAhf6wp8yAOsoxK71ayVhjXPUVDpQPv4ZLmSKE',
      status: 401,
      code: 'unauthorized',
    },
    { name: 'missing header', status: 401, code: 'unauthorized' },
    {
      name: 'Basic scheme',
      authorization: 'Basic d2RqX3Rlc3Q6',
      status: 401,
      code: 'unauthorized',
    },
  ]

  for (const { name, authorization, status, code } of cases) {
    it(name, async () => {
      const { app } = testApp()
      const response = await app.request('/v1/files', {
        headers: authorization ? { Authorization: authorization } : {},
      })
      expect(response.status).toBe(status)
      if (code) {
        expect(response.headers.get('WWW-Authenticate')).toBe('Bearer')
        expect(((await response.json()) as { error: { code: string } }).error.code).toBe(code)
      }
    })
  }
})
