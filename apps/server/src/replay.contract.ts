import { describe, expect, it } from 'vitest'
import type { Clock, IdGenerator, TokenGenerator } from './ports.ts'

export interface Fixture {
  name: string
  request: {
    method: string
    path: string
    headers: Record<string, string>
    body: unknown
  }
  response: {
    status: number
    headers: Record<string, string>
    body: unknown
  }
}

/**
 * The protocol fixtures plus `files`: each non-JSON fixture file name
 * (screenshot.png, *.bin, *.html…) mapped to its base64 contents.
 */
export interface ReplayFixtures {
  fixtures: Fixture[]
  files: Record<string, string>
}

export interface ReplaySeams {
  clock: Clock
  ids: IdGenerator
  tokens: TokenGenerator
}

/** The app surface the replay drives: anything with Hono's `.request`. */
export interface Replayable {
  request(path: string, init: RequestInit): Promise<Response> | Response
}

// Issues #51-#53 own these fixtures; they run as todo until those land.
const todos = new Map<string, string>([
  ['01-discovery', '#53: discovery advertises OAuth'],
  ['26-get-sharex-config', '#52'],
  ['27-get-deletion-page', '#52'],
  ['28-delete-by-link', '#52'],
  ['29-get-file-not-found', "#52: the file is gone only after 28's delete-by-link"],
])

const IDS = ['aB3xK9', 'Uq7Lm2', 'Pz2Wc5', 'Hn4Rt8']
const TOKENS = [
  '5mQeI1qnbywzZsvQ2MibRgZdGEmSSpZ_sh3HHTkl_FQ',
  'eIipUchuHMYCyF5sa-JRAMyV6a-jZ3htmkInxF4xd5A',
]

const peeking = (values: readonly string[], label: string) => {
  let index = 0
  return {
    peek: () => values[index],
    next: () => {
      const value = values[index++]
      if (value === undefined) throw new Error(`${label} generator exhausted`)
      return value
    },
  }
}

const fileBytes = (files: Record<string, string>, name: string): Uint8Array => {
  const base64 = files[name]
  if (base64 === undefined) throw new Error(`missing fixture file: ${name}`)
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0))
}

/**
 * Replays the protocol fixtures against an app as a single story: state and
 * seeded ids/tokens carry across the `it`s, in fixture order.
 */
export const replayContract = (
  name: string,
  { fixtures, files }: ReplayFixtures,
  makeApp: (seams: ReplaySeams) => Replayable,
) => {
  for (const name of todos.keys()) {
    if (!fixtures.some((fixture) => fixture.name === name))
      throw new Error(`todo map names a missing fixture: ${name}`)
  }

  return describe(name, () => {
    let clock = new Date(0)
    const ids = peeking(IDS, 'id')
    const tokens = peeking(TOKENS, 'token')

    const app = makeApp({ clock: () => clock, ids: ids.next, tokens: tokens.next })

    // A skipped fixture can still consume a seeded id or token; drain the
    // skipped fixtures that precede each running fixture, in story order.
    let previous = -1
    const drainSkipped = (index: number) => {
      for (const fixture of fixtures.slice(previous + 1, index)) {
        const body = fixture.response.body
        if (typeof body !== 'object' || body === null) continue
        const { id, deleteUrl } = body as { id?: unknown; deleteUrl?: unknown }
        if (id !== undefined && id === ids.peek()) ids.next()
        if (
          typeof deleteUrl === 'string' &&
          tokens.peek() !== undefined &&
          deleteUrl.split('/').at(-1) === tokens.peek()
        )
          tokens.next()
      }
      previous = index
    }

    for (const fixture of fixtures) {
      const reason = todos.get(fixture.name)
      if (reason !== undefined) {
        it.todo(`${fixture.name} (${reason})`)
        continue
      }
      it(fixture.name, async () => {
        drainSkipped(fixtures.indexOf(fixture))
        clock = new Date(fixture.response.headers.Date ?? 'Thu, 01 Jan 1970 00:00:00 GMT')

        let body: NonNullable<RequestInit['body']> | undefined
        if (fixture.request.body !== null) {
          body =
            fixture.request.headers['Content-Type'] === 'application/json'
              ? JSON.stringify(fixture.request.body)
              : fileBytes(files, fixture.request.body as string)
        }

        const init: RequestInit = {
          method: fixture.request.method,
          headers: fixture.request.headers,
        }
        if (body !== undefined) init.body = body
        const response = await app.request(fixture.request.path, init)

        expect(response.status).toBe(fixture.response.status)
        for (const [header, expected] of Object.entries(fixture.response.headers)) {
          expect(response.headers.get(header), header).toBe(expected)
        }
        const contentType = fixture.response.headers['Content-Type'] ?? ''
        if (fixture.response.body === null) {
          expect((await response.arrayBuffer()).byteLength).toBe(0)
        } else if (contentType === 'application/json') {
          expect(await response.json()).toEqual(fixture.response.body)
        } else {
          expect(new Uint8Array(await response.arrayBuffer())).toEqual(
            fileBytes(files, fixture.response.body as string),
          )
        }
      })
    }
  })
}
