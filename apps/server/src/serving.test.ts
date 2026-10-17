import { describe, expect, it } from 'vitest'
import { testApp, upload } from './test-helpers.ts'

const PNG = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13])

const uploadFile = async (
  app: ReturnType<typeof testApp>['app'],
  contentType = 'image/png',
  body: Uint8Array = PNG,
  headers: Record<string, string> = {},
) => {
  const response = await upload(app, { body, headers: { 'Content-Type': contentType, ...headers } })
  expect(response.status).toBe(201)
  return (await response.json()) as { id: string; url: string; filename: string }
}

describe('serving', () => {
  it('serves a PNG inline', async () => {
    const { app } = testApp()
    const file = await uploadFile(app)
    const response = await app.request('/id0000.png')
    expect(response.status).toBe(200)
    expect(response.headers.get('Content-Type')).toBe('image/png')
    expect(response.headers.get('Content-Disposition')).toContain('inline')
    expect(response.headers.get('Accept-Ranges')).toBe('bytes')
    expect(response.headers.get('ETag')).toBe(`"${file.id}"`)
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(PNG)
  })

  it.each([
    ['text/html', '<b>x</b>'],
    ['image/svg+xml', '<svg/>'],
  ])('serves %s as attachment', async (contentType, body) => {
    const { app } = testApp()
    await uploadFile(app, contentType, new TextEncoder().encode(body))
    const name = contentType === 'text/html' ? '/id0000.html' : '/id0000.svg'
    const response = await app.request(name)
    expect(response.status).toBe(200)
    expect(response.headers.get('Content-Disposition')).toContain('attachment')
  })

  it('percent-encodes the filename in Content-Disposition', async () => {
    const { app } = testApp()
    await upload(app, {
      body: PNG,
      headers: { 'Wadjet-Filename': 'Mia%27s%20%C3%BC%09.png' },
    })
    const response = await app.request('/id0000.png')
    expect(response.headers.get('Content-Disposition')).toBe(
      "inline; filename*=UTF-8''Mia%27s%20%C3%BC%09.png",
    )
  })

  it('answers HEAD with headers and no body', async () => {
    const { app, blobs } = testApp()
    await uploadFile(app)
    let opened = false
    const original = blobs.get.bind(blobs)
    blobs.get = async (...args: Parameters<typeof original>) => {
      opened = true
      return original(...args)
    }
    const response = await app.request('/id0000.png', { method: 'HEAD' })
    expect(response.status).toBe(200)
    expect(response.headers.get('Content-Length')).toBe(String(PNG.length))
    expect((await response.arrayBuffer()).byteLength).toBe(0)
    expect(opened).toBe(false)
  })

  it.each([
    ['bytes=0-9', 206, 'bytes 0-9/12', PNG.subarray(0, 10)],
    ['bytes=5-', 206, 'bytes 5-11/12', PNG.subarray(5)],
    ['bytes=-3', 206, 'bytes 9-11/12', PNG.subarray(9)],
    ['bytes=9999-', 200, null, PNG],
    ['bytes=0-1,3-4', 200, null, PNG],
  ])('Range %s', async (range, status, contentRange, expected) => {
    const { app } = testApp()
    await uploadFile(app)
    const response = await app.request('/id0000.png', { headers: { Range: range } })
    expect(response.status).toBe(status)
    if (contentRange) expect(response.headers.get('Content-Range')).toBe(contentRange)
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(expected)
  })

  it('redirects a non-canonical name to the canonical URL', async () => {
    const { app } = testApp()
    await uploadFile(app)
    for (const name of ['/id0000', '/id0000.gif']) {
      const response = await app.request(name)
      expect(response.status).toBe(301)
      expect(response.headers.get('Location')).toBe('https://w.mia.cx/id0000.png')
      expect(response.headers.get('Cache-Control')).toBe('public, max-age=300, s-maxage=31536000')
    }
  })

  it('sets nosniff on every kind of response', async () => {
    const { app } = testApp()
    await uploadFile(app)
    const responses = await Promise.all([
      app.request('/.well-known/wadjet'), // discovery 200
      app.request('/v1/files', { headers: { Authorization: 'Bearer wdj_bad' } }), // 401
      app.request('/nothing-here'), // 404
      upload(app, { body: PNG }), // upload 201
      app.request('/id0000.png'), // file 200
      app.request('/id0000'), // 301
    ])
    for (const response of responses) {
      expect(response.headers.get('X-Content-Type-Options')).toBe('nosniff')
    }
  })
})
