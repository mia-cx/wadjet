import { describe, expect, it } from 'vitest'
import { memoryBlobStore } from './blob-store.ts'
import type { CachePurger } from './ports.ts'
import { testApp, upload } from './test-helpers.ts'

const AUTH = { Authorization: 'Bearer wdj_test' }

const startUpload = (app: ReturnType<typeof testApp>['app'], size: number) =>
  app.request('/v1/uploads', {
    method: 'POST',
    headers: { ...AUTH, 'Content-Type': 'application/json' },
    body: JSON.stringify({ contentType: 'video/mp4', size, filename: 'rec.mp4' }),
  })

const putPart = (
  app: ReturnType<typeof testApp>['app'],
  id: string,
  n: number,
  bytes: Uint8Array,
) =>
  app.request(`/v1/uploads/${id}/parts/${n}`, {
    method: 'PUT',
    headers: {
      ...AUTH,
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(bytes.length),
    },
    body: bytes,
  })

const complete = (app: ReturnType<typeof testApp>['app'], id: string) =>
  app.request(`/v1/uploads/${id}/complete`, { method: 'POST', headers: AUTH })

const putThumbnail = (
  app: ReturnType<typeof testApp>['app'],
  id: string,
  bytes: Uint8Array,
  type = 'image/webp',
) =>
  app.request(`/v1/files/${id}/thumbnail`, {
    method: 'PUT',
    headers: { ...AUTH, 'Content-Type': type, 'Content-Length': String(bytes.length) },
    body: bytes,
  })

describe('multipart sessions', () => {
  it('overlapping completes create exactly one file', async () => {
    const blobs = memoryBlobStore()
    // Hold the storage complete until the second request's transition loses.
    let release!: () => void
    const gate = new Promise<void>((resolve) => (release = resolve))
    const inner = blobs.completeMultipart.bind(blobs)
    let calls = 0
    blobs.completeMultipart = async (key, uploadId, parts) => {
      if (++calls === 1) await gate
      return inner(key, uploadId, parts)
    }
    const { app } = testApp({ blobs })

    const started = await startUpload(app, 3)
    const { id } = (await started.json()) as { id: string }
    expect(started.status).toBe(201)
    await putPart(app, id, 1, new Uint8Array([1, 2, 3]))

    const first = complete(app, id)
    for (let i = 0; i < 100 && calls === 0; i++) await new Promise((r) => setTimeout(r, 5))
    const second = await complete(app, id)
    expect(second.status).toBe(409) // mid-completion: the loser backs off

    release()
    expect((await first).status).toBe(201)

    // Once finished, a repeat complete returns the same file without a deleteUrl.
    const again = await complete(app, id)
    expect(again.status).toBe(200)
    const file = (await again.json()) as { id: string; deleteUrl: string | null }
    expect(file.id).toBe(id)
    expect(file.deleteUrl).toBeNull()

    const list = await app.request('/v1/files', { headers: AUTH })
    expect(((await list.json()) as { items: { id: string }[] }).items).toEqual([
      expect.objectContaining({ id }),
    ])
    expect(calls).toBe(1)
  })

  it('an overdue session answers 410 and frees its storage parts', async () => {
    const blobs = memoryBlobStore()
    let aborted = 0
    const inner = blobs.abortMultipart.bind(blobs)
    blobs.abortMultipart = async (key, uploadId) => {
      aborted++
      return inner(key, uploadId)
    }
    let now = new Date('2026-10-16T12:00:00Z')
    const { app } = testApp({ blobs, clock: () => now })

    const started = await startUpload(app, 3)
    const { id } = (await started.json()) as { id: string }
    expect((await putPart(app, id, 1, new Uint8Array([1, 2, 3]))).status).toBe(200)

    now = new Date('2026-10-18T00:00:00Z') // past expiresAt
    const status = await app.request(`/v1/uploads/${id}`, { headers: AUTH })
    expect(status.status).toBe(410)
    expect(((await status.json()) as { error: { code: string } }).error.code).toBe('upload_expired')
    expect(aborted).toBe(1)

    const part = await putPart(app, id, 1, new Uint8Array([1, 2, 3]))
    expect(part.status).toBe(410)
  })
})

describe('thumbnails', () => {
  const trackingPurger = () => {
    const purged: string[][] = []
    const purger: CachePurger = {
      purge: (urls) => {
        purged.push([...urls])
        return Promise.resolve()
      },
    }
    return { purged, purger }
  }

  it('replacing bumps the version, purges the old URL, and frees the old blob', async () => {
    const { purged, purger } = trackingPurger()
    const blobs = memoryBlobStore()
    const { app } = testApp({ purger, blobs })

    const uploaded = await upload(app, { body: new Uint8Array([1, 2, 3]) })
    const { id } = (await uploaded.json()) as { id: string }

    const first = await putThumbnail(app, id, new Uint8Array([9, 9]), 'image/webp')
    expect(first.status).toBe(200)
    expect(((await first.json()) as { thumbnailUrl: string }).thumbnailUrl).toBe(
      `https://w.mia.cx/t/${id}?v=1`,
    )

    const second = await putThumbnail(app, id, new Uint8Array([8, 8, 8]), 'image/png')
    expect(second.status).toBe(200)
    expect(((await second.json()) as { thumbnailUrl: string }).thumbnailUrl).toBe(
      `https://w.mia.cx/t/${id}?v=2`,
    )
    expect(purged).toEqual([[`https://w.mia.cx/t/${id}?v=1`]])
    expect(await blobs.get(`thumbnails/${id}-v1`)).toBeUndefined()

    // The old version redirects to the current one, uncached.
    const old = await app.request(`/t/${id}?v=1`)
    expect(old.status).toBe(301)
    expect(old.headers.get('Location')).toBe(`https://w.mia.cx/t/${id}?v=2`)
    expect(old.headers.get('Cache-Control')).toBe('no-store')

    const current = await app.request(`/t/${id}?v=2`)
    expect(current.status).toBe(200)
    expect(current.headers.get('Content-Type')).toBe('image/png')
    expect(new Uint8Array(await current.arrayBuffer())).toEqual(new Uint8Array([8, 8, 8]))
  })

  it('a rejected content type is 415 and an oversized body is 413', async () => {
    const { app } = testApp()
    const uploaded = await upload(app, { body: new Uint8Array([1, 2, 3]) })
    const { id } = (await uploaded.json()) as { id: string }

    const wrong = await putThumbnail(app, id, new Uint8Array([1]), 'image/gif')
    expect(wrong.status).toBe(415)
    expect(((await wrong.json()) as { error: { code: string } }).error.code).toBe(
      'unsupported_media_type',
    )

    const big = await putThumbnail(app, id, new Uint8Array(262_145), 'image/webp')
    expect(big.status).toBe(413)
    expect(((await big.json()) as { error: { code: string } }).error.code).toBe('too_large')
  })

  it('delete purges the file and thumbnail URLs and frees both blobs', async () => {
    const { purged, purger } = trackingPurger()
    const blobs = memoryBlobStore()
    const { app } = testApp({ purger, blobs })

    const uploaded = await upload(app, { body: new Uint8Array([1, 2, 3]) })
    const { id } = (await uploaded.json()) as { id: string }
    await putThumbnail(app, id, new Uint8Array([9]), 'image/webp')

    const deleted = await app.request(`/v1/files/${id}`, { method: 'DELETE', headers: AUTH })
    expect(deleted.status).toBe(204)
    expect(purged).toEqual([[`https://w.mia.cx/${id}.png`, `https://w.mia.cx/t/${id}?v=1`]])
    expect(await blobs.get(`thumbnails/${id}-v1`)).toBeUndefined()

    const thumb = await app.request(`/t/${id}?v=1`)
    expect(thumb.status).toBe(404)
  })
})
