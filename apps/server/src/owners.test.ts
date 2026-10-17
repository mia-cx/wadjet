import { describe, expect, it } from 'vitest'
import type { CachePurger } from './ports.ts'
import { KEY_A, KEY_A_HASH, KEY_B, KEY_B_HASH, testApp, upload } from './test-helpers.ts'

/** Waits until `ok` holds — the in-memory deps settle within a few macrotasks. */
const until = async (ok: () => boolean) => {
  for (let i = 0; i < 100 && !ok(); i++) await new Promise((resolve) => setTimeout(resolve, 5))
}

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
    // The tombstone already hides the file: nothing can refill the edge cache.
    expect((await app.request(`/${id}.png`)).status).toBe(404)

    const second = await app.request(`/v1/files/${id}`, {
      method: 'DELETE',
      headers: { Authorization: 'Bearer wdj_test' },
    })
    expect(second.status).toBe(204)
    expect((await app.request(`/${id}.png`)).status).toBe(404)
    expect(purged).toEqual([[`https://w.mia.cx/${id}.png`], [`https://w.mia.cx/${id}.png`]])
  })

  it('stops serving the file while its purge runs', async () => {
    const statuses: number[] = []
    const purger: CachePurger = {
      purge: async (urls) => {
        for (const url of urls) statuses.push((await app.request(new URL(url).pathname)).status)
      },
    }
    const { app } = testApp({ purger })

    const uploadResponse = await upload(app, { body: new Uint8Array([1, 2, 3]) })
    const { id } = (await uploadResponse.json()) as { id: string }

    const deleted = await app.request(`/v1/files/${id}`, {
      method: 'DELETE',
      headers: { Authorization: 'Bearer wdj_test' },
    })
    expect(deleted.status).toBe(204)
    expect(statuses).toEqual([404])
  })

  it('frees the idempotency key while a failed delete is still pending', async () => {
    const purged: string[][] = []
    let rejectFirst = (_error: Error) => {}
    const firstPurge = new Promise<void>((_resolve, reject) => (rejectFirst = reject))
    const purger: CachePurger = {
      purge: (urls) => {
        purged.push([...urls])
        return purged.length === 1 ? firstPurge : Promise.resolve()
      },
    }
    const { app } = testApp({ purger })

    const uploadedA = await upload(app, { headers: { 'Idempotency-Key': 'key-k' } })
    const a = (await uploadedA.json()) as { id: string }

    const deletedA = app.request(`/v1/files/${a.id}`, {
      method: 'DELETE',
      headers: { Authorization: 'Bearer wdj_test' },
    })
    await until(() => purged.length === 1)

    // The tombstone released the key, so the retry is a new file, not a replay.
    const uploadedB = await upload(app, { headers: { 'Idempotency-Key': 'key-k' } })
    expect(uploadedB.status).toBe(201)
    const b = (await uploadedB.json()) as { id: string }
    expect(b.id).not.toBe(a.id)

    rejectFirst(new Error('edge down'))
    expect((await deletedA).status).toBe(500)
    expect((await app.request(`/${a.id}.png`)).status).toBe(404)

    const retry = await app.request(`/v1/files/${a.id}`, {
      method: 'DELETE',
      headers: { Authorization: 'Bearer wdj_test' },
    })
    expect(retry.status).toBe(204)

    const list = await app.request('/v1/files', {
      headers: { Authorization: 'Bearer wdj_test' },
    })
    expect(
      ((await list.json()) as { items: { id: string }[] }).items.map((file) => file.id),
    ).toEqual([b.id])
    expect((await app.request(`/${b.id}.png`)).status).toBe(200)
  })

  it('an overlapping delete cannot resurrect the file', async () => {
    const purged: string[][] = []
    let rejectFirst = (_error: Error) => {}
    const firstPurge = new Promise<void>((_resolve, reject) => (rejectFirst = reject))
    const purger: CachePurger = {
      purge: (urls) => {
        purged.push([...urls])
        return purged.length === 1 ? firstPurge : Promise.resolve()
      },
    }
    const { app } = testApp({ purger })

    const uploaded = await upload(app, { body: new Uint8Array([1, 2, 3]) })
    const { id } = (await uploaded.json()) as { id: string }

    const loser = app.request(`/v1/files/${id}`, {
      method: 'DELETE',
      headers: { Authorization: 'Bearer wdj_test' },
    })
    await until(() => purged.length === 1)

    const winner = await app.request(`/v1/files/${id}`, {
      method: 'DELETE',
      headers: { Authorization: 'Bearer wdj_test' },
    })
    expect(winner.status).toBe(204)

    rejectFirst(new Error('edge down'))
    expect((await loser).status).toBe(500)

    const list = await app.request('/v1/files', {
      headers: { Authorization: 'Bearer wdj_test' },
    })
    expect(((await list.json()) as { items: unknown[] }).items).toEqual([])
    expect((await app.request(`/${id}.png`)).status).toBe(404)

    const again = await app.request(`/v1/files/${id}`, {
      method: 'DELETE',
      headers: { Authorization: 'Bearer wdj_test' },
    })
    expect(again.status).toBe(404)
  })
})
