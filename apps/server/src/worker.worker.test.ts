import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test'
import { env, exports } from 'cloudflare:workers'
import { expect, it } from 'vitest'
import { REPLAY_API_KEY } from './test-helpers.ts'
import worker from './worker.ts'

it('serves /healthz through the exported handler', async () => {
  const response = await exports.default.fetch(new Request('https://w.mia.cx/healthz'))
  expect(response.status).toBe(200)
  expect(await response.json()).toEqual({ status: 'ok' })
})

it('serves files from the edge cache', async () => {
  // The default export called with our own ctx, so waitUntil'd cache puts are awaitable.
  const fetch = async (input: string, init?: RequestInit) => {
    const ctx = createExecutionContext()
    const request = new Request(input, init) as unknown as Request<
      unknown,
      IncomingRequestCfProperties
    >
    const response = await worker.fetch(request, env, ctx)
    await waitOnExecutionContext(ctx)
    return response
  }

  const body = new Uint8Array([1, 2, 3, 255])
  const upload = await fetch('https://w.mia.cx/v1/files', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${REPLAY_API_KEY}`,
      'Content-Type': 'image/png',
      'Content-Length': String(body.length),
    },
    body,
  })
  expect(upload.status).toBe(201)
  const { id, url } = (await upload.json()) as { id: string; url: string }
  expect(url).toBe(`https://w.mia.cx/${id}.png`)

  const first = await fetch(url)
  expect(first.status).toBe(200)
  expect(new Uint8Array(await first.arrayBuffer())).toEqual(body)

  const { objects } = await env.BLOBS.list({ prefix: `files/${id}-` })
  expect(objects).toHaveLength(1)
  for (const object of objects) await env.BLOBS.delete(object.key)

  // The blob is gone, but the edge copy still serves.
  const second = await fetch(url)
  expect(second.status).toBe(200)
  expect(new Uint8Array(await second.arrayBuffer())).toEqual(body)

  // The entry is keyed by the URL the purger sends.
  expect(await caches.default.match(`https://w.mia.cx/${id}.png`)).toBeDefined()

  const ranged = await fetch(url, { headers: { Range: 'bytes=1-2' } })
  expect(ranged.status).toBe(206)
  expect(new Uint8Array(await ranged.arrayBuffer())).toEqual(new Uint8Array([2, 3]))
})
