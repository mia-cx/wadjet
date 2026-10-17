import {
  BearerHeaders,
  Discovery,
  ErrorBody,
  FilePage,
  File as FileSchema,
  Health,
  Id,
  ListQuery,
  PartHeaders,
  PartReceipt,
  ShareXConfig,
  StartUpload,
  StartUploadHeaders,
  UploadedFile,
  UploadFileHeaders,
  UploadSession,
  UploadStatus,
} from '@wadjet/protocol'
import { Schema } from 'effect'
import { type Context, Hono } from 'hono'
import type { ContentfulStatusCode } from 'hono/utils/http-status'
import { apiKeyAuth } from './auth.ts'
import type { BlobStore } from './blob-store.ts'
import { type AppConfig, discoveryOf } from './config.ts'
import { sha256Hex } from './crypto.ts'
import { invalidRequest, notFound, ProtocolError, tooLarge, unauthorized } from './errors.ts'
import type { FileIndex } from './file-index.ts'
import { createLibrary } from './library.ts'
import type { CachePurger, Clock, IdGenerator, TokenGenerator } from './ports.ts'
import { serveFile, serveThumbnail } from './serving.ts'
import type { UploadIndex } from './upload-index.ts'

const DEFAULT_LIST_LIMIT = 50

export interface AppDeps {
  readonly config: AppConfig
  readonly files: FileIndex
  readonly uploads: UploadIndex
  readonly blobs: BlobStore
  readonly purger: CachePurger
  readonly clock: Clock
  readonly ids: IdGenerator
  readonly tokens: TokenGenerator
}

type Env = { Variables: { owner: string } }

/** Decode a request part with a protocol schema; failures become 400 invalid_request. */
/** A route `:id` must be an Id, not just any path segment — an invalid one
 * is 404 like an unknown one, and never reaches a blob key. */
const idParam = (c: Context<Env>): string => {
  const id = c.req.param('id')
  if (!Schema.is(Id)(id)) throw notFound('No such id.')
  return id
}

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

const PAGE_SECURITY_HEADERS: Record<string, string> = {
  'Cache-Control': 'no-store',
  'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
}

const escapeHtml = (text: string): string =>
  text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')

const deletionPage = (filename: string, host: string): string =>
  `<!doctype html>
<meta charset="utf-8">
<meta name="robots" content="noindex">
<meta name="viewport" content="width=device-width">
<title>Delete ${escapeHtml(filename)}</title>
<form method="post">
<p>Delete ${escapeHtml(filename)} from ${escapeHtml(host)}?</p>
<button>Delete</button>
</form>
`

const deletedPage = (filename: string, host: string): string =>
  `<!doctype html>
<meta charset="utf-8">
<meta name="robots" content="noindex">
<meta name="viewport" content="width=device-width">
<title>Deleted ${escapeHtml(filename)}</title>
<p>Deleted ${escapeHtml(filename)} from ${escapeHtml(host)}.</p>
`

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

  // Deletion links are unauthenticated — the token is the credential. GET only
  // renders; link previews and prefetchers can't delete anything.
  const lookupLink = async (token: string) => {
    const row = await deps.files.findByDeleteTokenHash(await sha256Hex(token))
    if (!row || row.deletedAt) throw notFound('This link is dead.')
    return row
  }
  const host = new URL(deps.config.baseUrl).host

  app.get('/d/:token', async (c) => {
    const row = await lookupLink(c.req.param('token'))
    c.header('Content-Type', 'text/html; charset=utf-8')
    for (const [k, v] of Object.entries(PAGE_SECURITY_HEADERS)) c.header(k, v)
    return c.body(deletionPage(row.filename, host), 200)
  })

  app.post('/d/:token', async (c) => {
    const row = await library.deleteByToken(c.req.param('token'))
    c.header('Content-Type', 'text/html; charset=utf-8')
    for (const [k, v] of Object.entries(PAGE_SECURITY_HEADERS)) c.header(k, v)
    return c.body(deletedPage(row.filename, host), 200)
  })

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

  // A ready-made ShareX custom uploader with the caller's API key embedded.
  // An OAuth token gets 400 once #53 exists — non-`wdj_` credentials are 401 today.
  app.get('/v1/sharex.sxcu', async (c) => {
    const key = c.req.header('authorization')!.replace(/^Bearer\s+/, '')
    const base = deps.config.baseUrl
    const body = {
      Version: '21.0.0',
      Name: `Wadjet (${host})`,
      DestinationType: 'ImageUploader, FileUploader',
      RequestMethod: 'POST' as const,
      RequestURL: `${base}/v1/files`,
      Body: 'Binary' as const,
      Headers: {
        Authorization: `Bearer ${key}`,
        'Wadjet-Filename': '{filename}',
        'Wadjet-Device': 'ShareX',
      },
      URL: '{json:url}',
      DeletionURL: '{json:deleteUrl}',
      ErrorMessage: '{json:error.message}',
    }
    c.header('Content-Disposition', `attachment; filename="${host}.sxcu"`)
    return json(c, ShareXConfig, body, 200)
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
    await library.delete(c.get('owner'), idParam(c))
    return c.body(null, 204)
  })

  app.put('/v1/files/:id/thumbnail', async (c) => {
    const id = idParam(c)
    decode(BearerHeaders, c.req.header())
    const contentType = c.req.header('content-type')
    if (contentType !== 'image/webp' && contentType !== 'image/jpeg' && contentType !== 'image/png')
      throw new ProtocolError(
        415,
        'unsupported_media_type',
        `Thumbnails are image/webp, image/jpeg, or image/png; got ${contentType}.`,
      )
    const size = Number(c.req.header('content-length'))
    if (!Number.isInteger(size) || size < 0)
      throw invalidRequest('Content-Length is missing or not a number.')
    const file = await library.setThumbnail(
      c.get('owner'),
      id,
      c.req.raw.body ?? new ReadableStream({ start: (ctl) => ctl.close() }),
      size,
      contentType,
      { maxThumbnailBytes: deps.config.limits.maxThumbnailBytes },
    )
    return json(c, FileSchema, file, 200)
  })

  app.post('/v1/uploads', async (c) => {
    const headers = decode(StartUploadHeaders, c.req.header())
    const body = decode(StartUpload, await c.req.json().catch(() => ({})))
    const { limits } = deps.config
    const { session, created } = await library.startUpload({
      owner: c.get('owner'),
      contentType: body.contentType,
      size: body.size,
      filename: body.filename,
      kind: body.kind,
      device: body.device,
      idempotencyKey: headers['idempotency-key'],
      partBytes: limits.partBytes,
      maxFileBytes: limits.maxFileBytes,
    })
    return json(c, UploadSession, session, created ? 201 : 200)
  })

  app.get('/v1/uploads/:id', async (c) => {
    const id = idParam(c)
    decode(BearerHeaders, c.req.header())
    const status = await library.getUpload(c.get('owner'), id)
    return json(c, UploadStatus, status, 200)
  })

  app.put('/v1/uploads/:id/parts/:n', async (c) => {
    const id = idParam(c)
    const headers = decode(PartHeaders, c.req.header())
    const n = Number(c.req.param('n'))
    const receipt = await library.uploadPart(
      c.get('owner'),
      id,
      n,
      c.req.raw.body ?? new ReadableStream({ start: (ctl) => ctl.close() }),
      Number(headers['content-length']),
    )
    return json(c, PartReceipt, receipt, 200)
  })

  app.post('/v1/uploads/:id/complete', async (c) => {
    const id = idParam(c)
    decode(BearerHeaders, c.req.header())
    const { file, created } = await library.completeUpload(c.get('owner'), id)
    return json(c, UploadedFile, file, created ? 201 : 200)
  })

  app.delete('/v1/uploads/:id', async (c) => {
    const id = idParam(c)
    decode(BearerHeaders, c.req.header())
    await library.abortUpload(c.get('owner'), id)
    return c.body(null, 204)
  })

  app.get('/t/:id', async (c) => {
    const served = await serveThumbnail(
      { files: deps.files, blobs: deps.blobs, baseUrl: deps.config.baseUrl },
      c.req.param('id'),
      new URL(c.req.url).searchParams.get('v') ?? undefined,
      c.req.method,
      c.req.header('range'),
    )
    for (const [key, value] of Object.entries(served.headers)) c.header(key, value)
    if (!served.body) return c.body(null, served.status)
    return c.body(served.body, served.status)
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
