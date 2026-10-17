import {
  BearerHeaders,
  Discovery,
  ErrorBody,
  FilePage,
  Health,
  ListQuery,
  UploadedFile,
  UploadFileHeaders,
} from '@wadjet/protocol'
import { Schema } from 'effect'
import { type Context, Hono } from 'hono'
import type { ContentfulStatusCode } from 'hono/utils/http-status'
import { apiKeyAuth } from './auth.ts'
import type { BlobStore } from './blob-store.ts'
import { type AppConfig, discoveryOf } from './config.ts'
import { invalidRequest, ProtocolError, tooLarge, unauthorized } from './errors.ts'
import type { FileIndex } from './file-index.ts'
import { createLibrary } from './library.ts'
import type { CachePurger, Clock, IdGenerator, TokenGenerator } from './ports.ts'
import { serveFile } from './serving.ts'

const DEFAULT_LIST_LIMIT = 50

export interface AppDeps {
  readonly config: AppConfig
  readonly files: FileIndex
  readonly blobs: BlobStore
  readonly purger: CachePurger
  readonly clock: Clock
  readonly ids: IdGenerator
  readonly tokens: TokenGenerator
}

type Env = { Variables: { owner: string } }

/** Decode a request part with a protocol schema; failures become 400 invalid_request. */
const decode = <S extends Schema.ConstraintDecoder<unknown>>(
  schema: S,
  value: unknown,
): S['Type'] => {
  try {
    return Schema.decodeUnknownSync(schema)(value)
  } catch (error) {
    throw invalidRequest(
      String(error)
        .replace(/^SchemaError:\s*/, '')
        .trim(),
    )
  }
}

/** Encode a JSON response through its protocol schema so the body can't drift from it. */
const json = <S extends Schema.ConstraintEncoder<unknown>>(
  c: Context,
  schema: S,
  value: S['Type'],
  status: ContentfulStatusCode,
) => c.json(Schema.encodeSync(schema)(value) as object, status)

const errorJson = (
  c: Context,
  code: (typeof ErrorBody.Type.error)['code'],
  message: string,
  status: ContentfulStatusCode,
) => c.json(Schema.encodeSync(ErrorBody)({ error: { code, message } }), status)

const percentDecode = (value: string | undefined): string | undefined => {
  if (value === undefined) return undefined
  try {
    return decodeURIComponent(value)
  } catch {
    return value // ShareX sends raw ASCII
  }
}

export const createApp = (deps: AppDeps): Hono<Env> => {
  const app = new Hono<Env>()
  const library = createLibrary({ ...deps, baseUrl: deps.config.baseUrl })
  const authenticate = apiKeyAuth(deps.config.apiKeys)

  app.use('*', async (c, next) => {
    await next()
    c.header('Date', deps.clock().toUTCString())
    c.header('X-Content-Type-Options', 'nosniff')
  })

  app.onError((error, c) => {
    if (error instanceof ProtocolError) {
      for (const [name, value] of Object.entries(error.headers ?? {})) c.header(name, value)
      return errorJson(c, error.code, error.message, error.status)
    }
    console.error(error)
    return errorJson(c, 'internal', 'The server failed.', 500)
  })

  app.notFound((c) => errorJson(c, 'not_found', `Nothing at ${c.req.path}.`, 404))

  app.get('/.well-known/wadjet', (c) => json(c, Discovery, discoveryOf(deps.config), 200))

  app.get('/healthz', (c) => json(c, Health, { status: 'ok' }, 200))

  app.use('/v1/*', async (c, next) => {
    const authorization = c.req.header('authorization')
    const owner = await authenticate(authorization)
    if (owner === undefined) {
      const hasBearerCredential = /^Bearer \S+$/.test(authorization ?? '')
      throw hasBearerCredential
        ? unauthorized('This API key is invalid or revoked.')
        : unauthorized('Send Authorization: Bearer <API key>.')
    }
    c.set('owner', owner)
    await next()
  })

  app.post('/v1/files', async (c) => {
    const headers = decode(UploadFileHeaders, c.req.header())
    const size = Number(headers['content-length'])
    const { limits } = deps.config
    if (size > limits.maxRequestBytes)
      throw tooLarge(`This server accepts up to ${limits.maxRequestBytes} bytes per request.`)
    if (limits.maxFileBytes !== null && size > limits.maxFileBytes)
      throw tooLarge(`This server accepts files up to ${limits.maxFileBytes} bytes.`)

    const { file, created } = await library.upload({
      owner: c.get('owner'),
      body: c.req.raw.body ?? new ReadableStream({ start: (ctl) => ctl.close() }),
      size,
      contentType: headers['content-type'],
      filename: percentDecode(headers['wadjet-filename']),
      kind: headers['wadjet-kind'],
      device: percentDecode(headers['wadjet-device']),
      idempotencyKey: headers['idempotency-key'],
    })
    return json(c, UploadedFile, file, created ? 201 : 200)
  })

  app.get('/v1/files', async (c) => {
    decode(BearerHeaders, c.req.header())
    const query = decode(ListQuery, new URL(c.req.url).searchParams)
    const page = await library.list(c.get('owner'), {
      cursor: query.cursor,
      limit: query.limit ?? DEFAULT_LIST_LIMIT,
    })
    return json(c, FilePage, page, 200)
  })

  app.delete('/v1/files/:id', async (c) => {
    await library.delete(c.get('owner'), c.req.param('id'))
    return c.body(null, 204)
  })

  // Serving route last so the API paths win.
  app.get('/:name', async (c) => {
    const served = await serveFile(
      { files: deps.files, blobs: deps.blobs, baseUrl: deps.config.baseUrl },
      c.req.param('name'),
      c.req.method,
      c.req.header('range'),
    )
    for (const [key, value] of Object.entries(served.headers)) c.header(key, value)
    if (!served.body) return c.body(null, served.status)
    return c.body(served.body, served.status)
  })

  return app
}
