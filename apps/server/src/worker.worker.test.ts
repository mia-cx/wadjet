import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test'
import { env } from 'cloudflare:workers'
import { expect, it } from 'vitest'
import { createHandler, type Env } from './worker.ts'

/** Real partBytes: the REPLAY_ENV binding is 1024, which R2 rejects for multipart. */
const prodEnv: Env = { ...env, WADJET_PART_BYTES: String(6 * 1024 * 1024) }

it('serves /healthz through the exported handler', async () => {
  const handler = createHandler()
  const ctx = createExecutionContext()
  const request = new Request('https://w.mia.cx/healthz') as unknown as Request<
    unknown,
    IncomingRequestCfProperties
  >
  const response = await handler.fetch(request, prodEnv, ctx)
  await waitOnExecutionContext(ctx)
  expect(response.status).toBe(200)
  expect(await response.json()).toEqual({ status: 'ok' })
})
