import { describe, expect, it } from 'vitest'
import type { CachePurger } from './ports.ts'
import { KEY_A, KEY_A_HASH, KEY_B, KEY_B_HASH, testApp, upload } from './test-helpers.ts'

const twoOwners = (purger?: CachePurger) =>
  testApp({
    config: {
      baseUrl: 'https://w.mia.cx',
      apiKeys: new Map([
        [KEY_A_HASH, 'owner-a'],
        [KEY_B_HASH, 'owner-b'],
      ]),
      limits: {
        maxRequestBytes: 100_000_000,
        partBytes: 67_108_864,
        maxFileBytes: null,
        maxThumbnailBytes: 262_144,
      },
    },
    ...(purger ? { purger } : {}),
  })

describe('owner isolation', () => {
  it('B cannot delete A’s file; A’s delete purges the canonical URL', async () => {
    const purged: string[][] = []
    const purger: CachePurger = {
      purge: (urls) => {
        purged.push([...urls])
        return Promise.resolve()
      },
    }
    const { app } = twoOwners(purger)

    const uploadResponse = await upload(app, { key: KEY_A, body: new Uint8Array([1, 2, 3]) })
    const { id } = (await uploadResponse.json()) as { id: string }

    const denied = await app.request(`/v1/files/${id}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${KEY_B}` },
    })
    expect(denied.status).toBe(404)
    expect(((await denied.json()) as { error: { code: string } }).error.code).toBe('not_found')

    expect((await app.request(`/${id}.png`)).status).toBe(200)

    const list = await app.request('/v1/files', {
      headers: { Authorization: `Bearer ${KEY_B}` },
    })
    expect(((await list.json()) as { items: unknown[] }).items).toEqual([])

    const deleted = await app.request(`/v1/files/${id}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${KEY_A}` },
    })
    expect(deleted.status).toBe(204)
    expect(purged).toEqual([[`https://w.mia.cx/${id}.png`]])
  })
})

describe('deletes', () => {
  it('purges even when the blob delete fails', async () => {
    const purged: string[][] = []
    const purger: CachePurger = {
      purge: (urls) => {
        purged.push([...urls])
        return Promise.resolve()
      },
    }
    const { app, blobs } = testApp({ purger })
    blobs.delete = () => Promise.reject(new Error('blob store down'))

    const uploadResponse = await upload(app, { body: new Uint8Array([1, 2, 3]) })
    const { id } = (await uploadResponse.json()) as { id: string }

    const deleted = await app.request(`/v1/files/${id}`, {
      method: 'DELETE',
      headers: { Authorization: 'Bearer wdj_test' },
    })
    expect(deleted.status).toBe(500)
    expect(((await deleted.json()) as { error: { code: string } }).error.code).toBe('internal')
    expect(purged).toEqual([[`https://w.mia.cx/${id}.png`]])

    expect((await app.request(`/${id}.png`)).status).toBe(404)
  })

  it('stays retryable when the purge fails', async () => {
    const purged: string[][] = []
    const purger: CachePurger = {
      purge: (urls) => {
        purged.push([...urls])
        return purged.length === 1 ? Promise.reject(new Error('edge down')) : Promise.resolve()
      },
    }
    const { app } = testApp({ purger })

    const uploadResponse = await upload(app, { body: new Uint8Array([1, 2, 3]) })
    const { id } = (await uploadResponse.json()) as { id: string }

    const first = await app.request(`/v1/files/${id}`, {
      method: 'DELETE',
      headers: { Authorization: 'Bearer wdj_test' },
    })
    expect(first.status).toBe(500)
    expect((await app.request(`/${id}.png`)).status).toBe(200)

    const second = await app.request(`/v1/files/${id}`, {
      method: 'DELETE',
      headers: { Authorization: 'Bearer wdj_test' },
    })
    expect(second.status).toBe(204)
    expect((await app.request(`/${id}.png`)).status).toBe(404)
    expect(purged).toEqual([[`https://w.mia.cx/${id}.png`], [`https://w.mia.cx/${id}.png`]])
  })
})
