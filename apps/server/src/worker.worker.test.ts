import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test'
import { env, exports } from 'cloudflare:workers'
import { expect, it } from 'vitest'
import { REPLAY_API_KEY } from './test-helpers.ts'
import { createHandler, type Env } from './worker.ts'

it('serves /healthz through the exported handler', async () => {
  const response = await exports.default.fetch(new Request('https://w.mia.cx/healthz'))
  expect(response.status).toBe(200)
  expect(await response.json()).toEqual({ status: 'ok' })
})

const uploadPng = async (
  fetch: (input: string, init?: RequestInit) => Promise<Response>,
  body: Uint8Array,
) => {
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
  return (await upload.json()) as { id: string; url: string }
}

it('serves files from the edge cache when purging is configured', async () => {
  const handler = createHandler()
  const cachedEnv: Env = {
    ...env,
    WADJET_CLOUDFLARE_ZONE_ID: 'zone',
    WADJET_CLOUDFLARE_API_TOKEN: 'token',
  }
  const fetch = async (input: string, init?: RequestInit) => {
    const ctx = createExecutionContext()
    const request = new Request(input, init) as unknown as Request<
      unknown,
      IncomingRequestCfProperties
    >
    const response = await handler.fetch(request, cachedEnv, ctx)
    await waitOnExecutionContext(ctx)
    return response
  }

  const body = new Uint8Array([1, 2, 3, 4])
  const { url } = await uploadPng(fetch, body)

  // Cold: unsatisfiable and multi-range requests get the protocol's full-200 fallback.
  for (const range of ['bytes=9999-', 'bytes=0-1,3-4']) {
    const ranged = await fetch(url, { headers: { Range: range } })
    expect(ranged.status, range).toBe(200)
    expect(new Uint8Array(await ranged.arrayBuffer())).toEqual(body)
  }

  // Full GET warms the edge cache.
  expect((await fetch(url)).status).toBe(200)

  // Warm: ranges still bypass the cache and hit storage.
  for (const range of ['bytes=9999-', 'bytes=0-1,3-4']) {
    const ranged = await fetch(url, { headers: { Range: range } })
    expect(ranged.status, range).toBe(200)
    expect(new Uint8Array(await ranged.arrayBuffer())).toEqual(body)
  }
  const ranged = await fetch(url, { headers: { Range: 'bytes=1-2' } })
  expect(ranged.status).toBe(206)
  expect(ranged.headers.get('Content-Range')).toBe('bytes 1-2/4')
  expect(new Uint8Array(await ranged.arrayBuffer())).toEqual(new Uint8Array([2, 3]))

  const id = url.split('/').at(-1)?.split('.')[0]
  const { objects } = await env.BLOBS.list({ prefix: `files/${id}-` })
  for (const object of objects) await env.BLOBS.delete(object.key)

  // The blob is gone, but the edge copy still serves.
  const cached = await fetch(url)
  expect(cached.status).toBe(200)
  expect(new Uint8Array(await cached.arrayBuffer())).toEqual(body)
  expect(await caches.default.match(url)).toBeDefined()
})

it('does not cache without a purger', async () => {
  const handler = createHandler()
  const fetch = async (input: string, init?: RequestInit) => {
    const ctx = createExecutionContext()
    const request = new Request(input, init) as unknown as Request<
      unknown,
      IncomingRequestCfProperties
    >
    const response = await handler.fetch(request, env, ctx)
    await waitOnExecutionContext(ctx)
    return response
  }

  const body = new Uint8Array([1, 2, 3, 4])
  const { id, url } = await uploadPng(fetch, body)

  expect((await fetch(url)).status).toBe(200)
  expect(await caches.default.match(url)).toBeUndefined()

  const deleted = await fetch(`https://w.mia.cx/v1/files/${id}`, {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${REPLAY_API_KEY}` },
  })
  expect(deleted.status).toBe(204)
  expect((await fetch(url)).status).toBe(404)
})
