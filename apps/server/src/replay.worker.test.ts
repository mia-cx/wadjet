import { env, exports } from 'cloudflare:workers'
import { expect, it } from 'vitest'
import { replayContract } from './replay.contract.ts'
import { appFor } from './worker.ts'

replayContract('worker (R2 + D1)', env.FIXTURES, (seams) => appFor(env, seams))

it('serves /healthz through the exported handler', async () => {
  const response = await exports.default.fetch(new Request('https://w.mia.cx/healthz'))
  expect(response.status).toBe(200)
  expect(await response.json()).toEqual({ status: 'ok' })
})
