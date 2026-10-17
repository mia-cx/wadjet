import { describe, expect, it } from 'vitest'
import { memoryBlobStore } from './blob-store.ts'
import type { CachePurger } from './ports.ts'
import { testApp, upload } from './test-helpers.ts'
import { memoryUploadIndex, type UploadRow } from './upload-index.ts'

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

const bytes = async (
  blobs: ReturnType<typeof memoryBlobStore>,
  key: string,
): Promise<Uint8Array> => {
  const body = await blobs.get(key)
  if (!body) throw new Error(`no blob ${key}`)
  return new Uint8Array(await new Response(body).arrayBuffer())
}

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
    const second = complete(app, id)

    release()
    const [a, b] = await Promise.all([first, second])
    // One request wins the file insert and gets 201 + the delete token; the
    // other reconciles to 200 with no deleteUrl. Exactly one file exists.
    const statuses = [a.status, b.status].sort()
    expect(statuses).toEqual([200, 201])
    const bodies = [a, b].map(
      async (r) => (await r.json()) as { id: string; deleteUrl: string | null },
    )
    const pairs = await Promise.all(bodies)
    expect(pairs.filter((f) => f.deleteUrl !== null)).toHaveLength(1)

    const again = await complete(app, id)
    expect(again.status).toBe(200)
    const file = (await again.json()) as { id: string; deleteUrl: string | null }
    expect(file.id).toBe(id)
    expect(file.deleteUrl).toBeNull()

    const list = await app.request('/v1/files', { headers: AUTH })
    expect(((await list.json()) as { items: { id: string }[] }).items).toEqual([
      expect.objectContaining({ id }),
    ])
    expect(calls).toBe(2) // both ran completeMultipart; the second was idempotent
  })

  it('a session left completed-without-fileId finishes on retry', async () => {
    const uploads = memoryUploadIndex()
    const blobs = memoryBlobStore()
    const { app } = testApp({ uploads, blobs })

    const started = await startUpload(app, 3)
    const { id } = (await started.json()) as { id: string }
    await putPart(app, id, 1, new Uint8Array([1, 2, 3]))

    // A request crashed between completeMultipart and markCompleted.
    const row = (await uploads.get(id))!
    const crashed: UploadRow = { ...row, state: 'completed', fileId: null }
    await uploads.delete(id)
    await uploads.insert(crashed)
    await uploads.putPart(id, { number: 1, size: 3, etag: 'e' })

    const done = await complete(app, id)
    expect(done.status).toBe(201)
  })

  it('a markCompleted failure retries to 200, not a duplicate-id 500', async () => {
    const uploads = memoryUploadIndex()
    const inner = uploads.markCompleted.bind(uploads)
    let calls = 0
    uploads.markCompleted = async (id, fileId) => {
      if (++calls === 1) throw new Error('injected markCompleted failure')
      return inner(id, fileId)
    }
    const { app } = testApp({ uploads })

    const started = await startUpload(app, 3)
    const { id } = (await started.json()) as { id: string }
    await putPart(app, id, 1, new Uint8Array([1, 2, 3]))

    const first = await complete(app, id)
    expect(first.status).toBe(500) // file row exists; only the session update failed

    const retry = await complete(app, id)
    expect(retry.status).toBe(200)
    const file = (await retry.json()) as { id: string; deleteUrl: string | null }
    expect(file.id).toBe(id)
    expect(file.deleteUrl).toBeNull()
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

  it('a failed abort on expiry leaves the row open so the next call retries', async () => {
    const blobs = memoryBlobStore()
    let aborts = 0
    const inner = blobs.abortMultipart.bind(blobs)
    blobs.abortMultipart = async (key, uploadId) => {
      aborts++
      if (aborts === 1) throw new Error('injected abort failure')
      return inner(key, uploadId)
    }
    let now = new Date('2026-10-16T12:00:00Z')
    const { app } = testApp({ blobs, clock: () => now })

    const started = await startUpload(app, 3)
    const { id } = (await started.json()) as { id: string }
    now = new Date('2026-10-18T00:00:00Z') // past expiresAt

    // First call: abort fails, row stays open → 500, not a lying 410.
    expect((await app.request(`/v1/uploads/${id}`, { headers: AUTH })).status).toBe(500)
    // Retry: the abort succeeds, the row expires, parts are freed.
    expect((await app.request(`/v1/uploads/${id}`, { headers: AUTH })).status).toBe(410)
    expect(aborts).toBe(2)
  })

  it('the lazy sweep retries a failed session and still cleans the rest', async () => {
    const blobs = memoryBlobStore()
    const aborted: string[] = []
    const inner = blobs.abortMultipart.bind(blobs)
    let failNext = true
    blobs.abortMultipart = async (key, uploadId) => {
      aborted.push(key)
      if (failNext) {
        failNext = false
        throw new Error('injected sweep abort failure')
      }
      return inner(key, uploadId)
    }
    let now = new Date('2026-10-16T12:00:00Z')
    const { app } = testApp({ blobs, clock: () => now })

    const a = (await (await startUpload(app, 3)).json()) as { id: string }
    const b = (await (await startUpload(app, 3)).json()) as { id: string }
    now = new Date('2026-10-18T00:00:00Z')

    // This start sweeps both: the first's abort fails (skipped + logged, this
    // POST still works), the second's succeeds and is marked expired.
    const third = await startUpload(app, 3)
    expect(third.status).toBe(201)
    expect((await app.request(`/v1/uploads/${a.id}`, { headers: AUTH })).status).toBe(410)
    expect((await app.request(`/v1/uploads/${b.id}`, { headers: AUTH })).status).toBe(410)
    expect(aborted.length).toBeGreaterThanOrEqual(3) // a's retry + b + a's first attempt
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

  it('a failed replace-cleanup is absorbed; delete still sweeps every version', async () => {
    const purged: string[][] = []
    let failV1 = true
    const purger: CachePurger = {
      purge: async (urls) => {
        if (failV1 && urls.every((u) => u.endsWith('?v=1'))) {
          failV1 = false
          throw new Error('injected purge failure')
        }
        purged.push([...urls])
      },
    }
    const blobs = memoryBlobStore()
    const { app } = testApp({ purger, blobs })

    const uploaded = await upload(app, { body: new Uint8Array([1, 2, 3]) })
    const { id } = (await uploaded.json()) as { id: string }
    await putThumbnail(app, id, new Uint8Array([9]), 'image/webp')
    // The v1 purge fails — the PUT still answers 200 with v2.
    const second = await putThumbnail(app, id, new Uint8Array([8]), 'image/webp')
    expect(second.status).toBe(200)
    expect(((await second.json()) as { thumbnailUrl: string }).thumbnailUrl).toBe(
      `https://w.mia.cx/t/${id}?v=2`,
    )

    const deleted = await app.request(`/v1/files/${id}`, { method: 'DELETE', headers: AUTH })
    expect(deleted.status).toBe(204)
    expect(purged).toEqual([
      [
        `https://w.mia.cx/${id}.png`,
        `https://w.mia.cx/t/${id}?v=1`,
        `https://w.mia.cx/t/${id}?v=2`,
      ],
    ])
    expect(await blobs.get(`thumbnails/${id}-v1`)).toBeUndefined()
    expect(await blobs.get(`thumbnails/${id}-v2`)).toBeUndefined()
  })

  it('overlapping thumbnail PUTs each get their own version', async () => {
    const blobs = memoryBlobStore()
    const inner = blobs.put.bind(blobs)
    let gated = 0
    let release!: () => void
    const gate = new Promise<void>((resolve) => (release = resolve))
    blobs.put = async (key, body, length, contentType) => {
      if (key.startsWith('thumbnails/') && ++gated === 1) await gate
      return inner(key, body, length, contentType)
    }
    const { app } = testApp({ blobs })

    const uploaded = await upload(app, { body: new Uint8Array([1, 2, 3]) })
    const { id } = (await uploaded.json()) as { id: string }

    const first = putThumbnail(app, id, new Uint8Array([1, 1, 1]), 'image/webp')
    for (let i = 0; i < 100 && gated === 0; i++) await new Promise((r) => setTimeout(r, 5))
    const second = await putThumbnail(app, id, new Uint8Array([2, 2, 2]), 'image/png')
    release()
    const [a, b] = await Promise.all([first, second])
    const versions = await Promise.all(
      [a, b].map(async (r) => ((await r.json()) as { thumbnailUrl: string }).thumbnailUrl),
    )
    expect(versions.sort()).toEqual([
      `https://w.mia.cx/t/${id}?v=1`,
      `https://w.mia.cx/t/${id}?v=2`,
    ])

    // Each version's blob holds its own bytes; ?v=2 is current and serves
    // them, while ?v=1 redirects (only the current version streams).
    expect(await bytes(blobs, `thumbnails/${id}-v1`)).toEqual(new Uint8Array([1, 1, 1]))
    expect(await bytes(blobs, `thumbnails/${id}-v2`)).toEqual(new Uint8Array([2, 2, 2]))
    const v2 = await app.request(`/t/${id}?v=2`)
    expect(v2.status).toBe(200)
    expect(new Uint8Array(await v2.arrayBuffer())).toEqual(new Uint8Array([2, 2, 2]))
    const v1 = await app.request(`/t/${id}?v=1`)
    expect(v1.status).toBe(301)
    expect(v1.headers.get('Location')).toBe(`https://w.mia.cx/t/${id}?v=2`)
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
