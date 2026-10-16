import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { Schema } from 'effect'
import { describe, expect, it } from 'vitest'
import { ErrorBody, matchEndpoint } from './index.js'

const fixturesDir = join(import.meta.dirname, '../fixtures')
const protocolPath = join(import.meta.dirname, '../PROTOCOL.md')

interface Side {
  readonly headers: Record<string, string>
  readonly body: unknown
}

interface Fixture {
  readonly name: string
  readonly request: Side & { readonly method: string; readonly path: string }
  readonly response: Side & { readonly status: number }
}

const fixtureNames = readdirSync(fixturesDir)
  .filter((file) => file.endsWith('.json'))
  .map((file) => file.slice(0, -'.json'.length))
  .sort()

const loadFixture = (name: string): Fixture =>
  JSON.parse(readFileSync(join(fixturesDir, `${name}.json`), 'utf8'))

const lowerKeys = (headers: Record<string, string>): Record<string, string> =>
  Object.fromEntries(Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value]))

const isJson = (side: Side): boolean =>
  lowerKeys(side.headers)['content-type']?.startsWith('application/json') ?? false

/** Resolve a fixture body: null = empty, JSON content type = decoded value, else a sibling filename. */
const bodyOf = (side: Side): unknown => {
  if (side.body === null) return null
  if (isJson(side)) return side.body
  const file = join(fixturesDir, String(side.body))
  expect(existsSync(file), `raw body file ${side.body}`).toBe(true)
  const length = lowerKeys(side.headers)['content-length']
  if (length !== undefined) {
    expect(statSync(file).size, `byte length of ${side.body}`).toBe(Number(length))
  }
  return null
}

describe("every fixture decodes with its endpoint's schemas", () => {
  it.each(fixtureNames)('%s', (name) => {
    const fixture = loadFixture(name)
    expect(fixture.name).toBe(name)

    const endpoint = matchEndpoint(fixture.request.method, fixture.request.path)
    expect(endpoint, 'matchEndpoint found no endpoint').toBeDefined()

    const requestHeaders = lowerKeys(fixture.request.headers)
    if (endpoint?.headers !== undefined) {
      Schema.decodeUnknownSync(endpoint.headers)(requestHeaders)
    }
    if (endpoint?.query !== undefined) {
      const query = fixture.request.path.split('?')[1] ?? ''
      Schema.decodeUnknownSync(endpoint.query)(new URLSearchParams(query))
    }
    const requestBody = bodyOf(fixture.request)
    if (endpoint?.body !== undefined && requestBody !== null) {
      Schema.decodeUnknownSync(endpoint.body)(requestBody)
    }

    const status = fixture.response.status
    if (status >= 400) {
      expect(isJson(fixture.response), 'error response is not JSON').toBe(true)
      expect(fixture.response.body, 'error response has no body').not.toBeNull()
      Schema.decodeUnknownSync(ErrorBody)(fixture.response.body)
      return
    }
    const listed = endpoint?.responses[status]
    expect(
      Object.keys(endpoint?.responses ?? {}).map(Number),
      `status ${status} not listed`,
    ).toContain(status)
    bodyOf(fixture.response)
    if (listed != null && fixture.response.body !== null) {
      Schema.decodeUnknownSync(listed)(fixture.response.body)
    }
  })
})

describe('PROTOCOL.md quotes every fixture exactly', () => {
  const quoted = () => [
    ...readFileSync(protocolPath, 'utf8').matchAll(
      /<!-- fixture: (\S+) -->\s*(?:\n\s*\n)?```json\n([\s\S]*?)```/g,
    ),
  ]

  it('quotes each fixture once', () => {
    expect(
      quoted()
        .map((match) => match[1])
        .sort(),
    ).toEqual(fixtureNames)
  })

  it.each(fixtureNames)('%s is quoted verbatim', (name) => {
    const quote = quoted().find((match) => match[1] === name)?.[2]
    expect(quote, 'fixture not quoted in PROTOCOL.md').toBeDefined()
    expect(JSON.stringify(JSON.parse(quote ?? ''))).toBe(
      JSON.stringify(JSON.parse(readFileSync(join(fixturesDir, `${name}.json`), 'utf8'))),
    )
  })
})
