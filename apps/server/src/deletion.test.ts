import { describe, expect, it } from 'vitest'
import { memoryBlobStore } from './blob-store.ts'
import type { CachePurger } from './ports.ts'
import { testApp, upload } from './test-helpers.ts'

const AUTH = { Authorization: 'Bearer wdj_test' }

const uploadWithUrl = async (app: ReturnType<typeof testApp>['app']) => {
  const res = await upload(app, { body: new Uint8Array([1, 2, 3]) })
  expect(res.status).toBe(201)
  return (await res.json()) as { id: string; url: string; deleteUrl: string }
}

describe('deletion links', () => {
  it('GET renders and never deletes', async () => {
    const { app } = testApp()
    const file = await uploadWithUrl(app)
    const token = file.deleteUrl.split('/d/')[1]

    const page = await app.request(`/d/${token}`)
    expect(page.status).toBe(200)
    const html = await page.text()
    expect(html).toContain(file.id)
    expect(page.headers.get('Cache-Control')).toBe('no-store')

    // Still there: GETs are for previews and prefetchers.
    expect((await app.request(`/${file.id}.png`)).status).toBe(200)
    expect((await app.request(`/d/${token}`)).status).toBe(200)
  })

  it('POST deletes only that file and purges its URLs', async () => {
    const purged: string[][] = []
    const purger: CachePurger = {
      purge: (urls) => {
        purged.push([...urls])
        return Promise.resolve()
      },
    }
    const blobs = memoryBlobStore()
    const { app } = testApp({ purger, blobs })

    const gone = await uploadWithUrl(app)
    const kept = await uploadWithUrl(app)
    const thumb = await app.request(`/v1/files/${gone.id}/thumbnail`, {
      method: 'PUT',
      headers: { ...AUTH, 'Content-Type': 'image/webp', 'Content-Length': '2' },
      body: new Uint8Array([9, 9]),
    })
    expect(thumb.status).toBe(200)
    const token = gone.deleteUrl.split('/d/')[1]

    const deleted = await app.request(`/d/${token}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    })
    expect(deleted.status).toBe(200)
    expect(await deleted.text()).toContain(`Deleted ${gone.id}.png`)

    expect(purged).toEqual([
      [`https://w.mia.cx/${gone.id}.png`, `https://w.mia.cx/t/${gone.id}?v=1`],
    ])
    expect((await app.request(`/${gone.id}.png`)).status).toBe(404)
    expect((await app.request(`/${kept.id}.png`)).status).toBe(200)

    // The link is dead afterwards.
    expect((await app.request(`/d/${token}`)).status).toBe(404)
    const again = await app.request(`/d/${token}`, { method: 'POST' })
    expect(again.status).toBe(404)
  })

  it('an interrupted teardown resumes on the next POST', async () => {
    const purged: string[][] = []
    let fail = true
    const purger: CachePurger = {
      purge: (urls) => {
        purged.push([...urls])
        if (fail) return Promise.reject(new Error('injected purge failure'))
        return Promise.resolve()
      },
    }
    const { app } = testApp({ purger })

    const file = await uploadWithUrl(app)
    const token = file.deleteUrl.split('/d/')[1]

    // The first POST tombstones then dies on the purge: a 500, and the file
    // is already unreachable at its URL.
    const first = await app.request(`/d/${token}`, { method: 'POST' })
    expect(first.status).toBe(500)
    expect((await app.request(`/${file.id}.png`)).status).toBe(404)

    // The retry resumes the teardown and answers the deleted page.
    fail = false
    const second = await app.request(`/d/${token}`, { method: 'POST' })
    expect(second.status).toBe(200)
    expect(await second.text()).toContain(`Deleted ${file.id}.png`)
    expect(purged).toHaveLength(2)
    expect(purged[0]).toEqual(purged[1])

    // The row is gone: a third POST is a dead link.
    expect((await app.request(`/d/${token}`, { method: 'POST' })).status).toBe(404)
  })

  it('a link to a file already deleted is 404, not a second delete', async () => {
    const { app } = testApp()
    const file = await uploadWithUrl(app)
    const token = file.deleteUrl.split('/d/')[1]
    await app.request(`/v1/files/${file.id}`, { method: 'DELETE', headers: AUTH })
    // Tombstoned rows still resolve by hash — the link must not resurrect them.
    expect((await app.request(`/d/${token}`)).status).toBe(404)
    expect((await app.request(`/d/${token}`, { method: 'POST' })).status).toBe(404)
  })
})

describe('ShareX config', () => {
  it('returns a working .sxcu: the embedded key uploads and the JSON paths resolve', async () => {
    const { app } = testApp()

    const res = await app.request('/v1/sharex.sxcu', { headers: AUTH })
    expect(res.status).toBe(200)
    expect(res.headers.get('Content-Disposition')).toContain('.sxcu')
    const sxcu = (await res.json()) as {
      RequestURL: string
      Headers: Record<string, string>
      URL: string
      DeletionURL: string
    }
    expect(sxcu.RequestURL).toBe('https://w.mia.cx/v1/files')
    expect(sxcu.URL).toBe('{json:url}')
    expect(sxcu.DeletionURL).toBe('{json:deleteUrl}')
    expect(sxcu.Headers.Authorization).toBe('Bearer wdj_test')
    expect(sxcu.Headers['Wadjet-Filename']).toBe('{filename}')

    // Simulate ShareX: its headers, a binary body, no Wadjet-Kind — the
    // content type alone decides the kind.
    const sharex = await app.request(sxcu.RequestURL, {
      method: 'POST',
      headers: {
        Authorization: sxcu.Headers.Authorization!,
        'Content-Type': 'video/mp4',
        'Content-Length': '3',
        'Wadjet-Filename': 'clip.mp4',
      },
      body: new Uint8Array([1, 2, 3]),
    })
    expect(sharex.status).toBe(201)
    const file = (await sharex.json()) as { url: string; deleteUrl: string; kind: string }
    expect(file.kind).toBe('recording') // kindFor(contentType), no Wadjet-Kind
    expect(file.url).toMatch(/^https:\/\/w\.mia\.cx\//)
    expect(file.deleteUrl).toMatch(/^https:\/\/w\.mia\.cx\/d\//)
  })
})
