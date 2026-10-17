import { describe, expect, it } from 'vitest'
import { cloudflarePurger } from './cloudflare-purger.ts'

const stubFetch = (...responses: Response[]) => {
  const calls: { url: string; init: RequestInit }[] = []
  const fetch = async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} })
    const response = responses.shift()
    if (!response) throw new Error('unexpected fetch')
    return response
  }
  return { calls, fetch: fetch as typeof globalThis.fetch }
}

const ok = () => Response.json({ success: true, errors: [] })

const purger = (fetch: typeof globalThis.fetch) =>
  cloudflarePurger({ zoneId: 'zone123', apiToken: 'token456', fetch })

describe('cloudflarePurger', () => {
  it('posts one URL in a single call', async () => {
    const { calls, fetch } = stubFetch(ok())
    await purger(fetch).purge(['https://w.mia.cx/files/aB3xK9'])

    expect(calls).toHaveLength(1)
    const call = calls[0]
    if (call === undefined) throw new Error('expected a call')
    const { url, init } = call
    expect(url).toBe('https://api.cloudflare.com/client/v4/zones/zone123/purge_cache')
    expect(init.method).toBe('POST')
    expect(init.headers).toEqual({
      Authorization: 'Bearer token456',
      'Content-Type': 'application/json',
    })
    expect(init.body).toBe('{"files":["https://w.mia.cx/files/aB3xK9"]}')
  })

  it('batches 61 URLs into calls of 30, 30, and 1', async () => {
    const { calls, fetch } = stubFetch(ok(), ok(), ok())
    const urls = [...Array(61).keys()].map((i) => `https://w.mia.cx/files/f${i}`)
    await purger(fetch).purge(urls)

    expect(calls).toHaveLength(3)
    const batches = calls.map(
      ({ init }) => (JSON.parse(init.body as string) as { files: string[] }).files,
    )
    expect(batches[0]).toEqual(urls.slice(0, 30))
    expect(batches[1]).toEqual(urls.slice(30, 60))
    expect(batches[2]).toEqual(urls.slice(60))
  })

  it('rejects on a 403 response', async () => {
    const { fetch } = stubFetch(Response.json({ success: false }, { status: 403 }))
    await expect(purger(fetch).purge(['https://w.mia.cx/a'])).rejects.toThrow('403')
  })

  it('rejects on a 200 response with success: false', async () => {
    const { fetch } = stubFetch(
      Response.json({ success: false, errors: [{ message: 'bad zone' }] }),
    )
    await expect(purger(fetch).purge(['https://w.mia.cx/a'])).rejects.toThrow('bad zone')
  })
})
