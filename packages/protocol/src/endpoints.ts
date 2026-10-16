import type { Schema } from 'effect'
import {
  BearerHeaders,
  Discovery,
  File,
  FilePage,
  Health,
  ListQuery,
  PartHeaders,
  PartReceipt,
  ShareXConfig,
  StartUpload,
  StartUploadHeaders,
  ThumbnailHeaders,
  UploadedFile,
  UploadFileHeaders,
  UploadSession,
  UploadStatus,
} from './schema.js'

/** Auth scheme for an endpoint: open, bearer API key, or a single-use deletion token. */
export type Auth = 'none' | 'bearer' | 'token'

/**
 * One endpoint of the Wadjet Server v1 protocol. `path` is a template such as
 * `/v1/files/{id}`; `headers`, `query`, and `body` are the request schemas when
 * defined. `responses` maps each success status to its JSON body schema, or
 * `null` when the body is empty or raw (binary, HTML). Any status ≥ 400 carries
 * an `ErrorBody` and is not listed.
 */
export interface Endpoint {
  readonly name: string
  readonly method: 'GET' | 'HEAD' | 'POST' | 'PUT' | 'DELETE'
  readonly path: string
  readonly auth: Auth
  readonly headers?: Schema.Decoder<unknown>
  readonly query?: Schema.Decoder<unknown>
  readonly body?: Schema.Decoder<unknown>
  readonly responses: Readonly<Record<number, Schema.Decoder<unknown> | null>>
}

/**
 * Ordered endpoint table for the Wadjet Server v1 protocol. First match wins,
 * so literal paths come before `/{id}` catch-alls.
 */
export const endpoints = [
  {
    name: 'discovery',
    method: 'GET',
    path: '/.well-known/wadjet',
    auth: 'none',
    responses: { 200: Discovery },
  },
  { name: 'healthz', method: 'GET', path: '/healthz', auth: 'none', responses: { 200: Health } },
  {
    name: 'get-sharex-config',
    method: 'GET',
    path: '/v1/sharex.sxcu',
    auth: 'bearer',
    headers: BearerHeaders,
    responses: { 200: ShareXConfig },
  },
  {
    name: 'upload-file',
    method: 'POST',
    path: '/v1/files',
    auth: 'bearer',
    headers: UploadFileHeaders,
    responses: { 201: UploadedFile, 200: UploadedFile },
  },
  {
    name: 'list-files',
    method: 'GET',
    path: '/v1/files',
    auth: 'bearer',
    headers: BearerHeaders,
    query: ListQuery,
    responses: { 200: FilePage },
  },
  {
    name: 'delete-file',
    method: 'DELETE',
    path: '/v1/files/{id}',
    auth: 'bearer',
    headers: BearerHeaders,
    responses: { 204: null },
  },
  {
    name: 'attach-thumbnail',
    method: 'PUT',
    path: '/v1/files/{id}/thumbnail',
    auth: 'bearer',
    headers: ThumbnailHeaders,
    responses: { 200: File },
  },
  {
    name: 'start-upload',
    method: 'POST',
    path: '/v1/uploads',
    auth: 'bearer',
    headers: StartUploadHeaders,
    body: StartUpload,
    responses: { 201: UploadSession, 200: UploadSession },
  },
  {
    name: 'upload-part',
    method: 'PUT',
    path: '/v1/uploads/{id}/parts/{n}',
    auth: 'bearer',
    headers: PartHeaders,
    responses: { 200: PartReceipt },
  },
  {
    name: 'get-upload',
    method: 'GET',
    path: '/v1/uploads/{id}',
    auth: 'bearer',
    headers: BearerHeaders,
    responses: { 200: UploadStatus },
  },
  {
    name: 'complete-upload',
    method: 'POST',
    path: '/v1/uploads/{id}/complete',
    auth: 'bearer',
    headers: BearerHeaders,
    responses: { 201: UploadedFile, 200: UploadedFile },
  },
  {
    name: 'abort-upload',
    method: 'DELETE',
    path: '/v1/uploads/{id}',
    auth: 'bearer',
    headers: BearerHeaders,
    responses: { 204: null },
  },
  { name: 'get-thumbnail', method: 'GET', path: '/t/{id}', auth: 'none', responses: { 200: null } },
  {
    name: 'get-deletion-page',
    method: 'GET',
    path: '/d/{token}',
    auth: 'token',
    responses: { 200: null },
  },
  {
    name: 'delete-by-link',
    method: 'POST',
    path: '/d/{token}',
    auth: 'token',
    responses: { 200: null },
  },
  {
    name: 'get-file-ext',
    method: 'GET',
    path: '/{id}.{ext}',
    auth: 'none',
    responses: { 200: null, 206: null },
  },
  {
    name: 'head-file-ext',
    method: 'HEAD',
    path: '/{id}.{ext}',
    auth: 'none',
    responses: { 200: null, 206: null },
  },
  {
    name: 'get-file',
    method: 'GET',
    path: '/{id}',
    auth: 'none',
    responses: { 200: null, 206: null },
  },
  {
    name: 'head-file',
    method: 'HEAD',
    path: '/{id}',
    auth: 'none',
    responses: { 200: null, 206: null },
  },
] as const satisfies readonly Endpoint[]

const matcher = (template: string): RegExp => {
  const pattern = template
    .split('/')
    .map((segment) =>
      segment
        .split(/(\{[^}]+\})/)
        .map((part) =>
          part.startsWith('{') ? '[^/]+' : part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'),
        )
        .join(''),
    )
    .join('/')
  return new RegExp(`^${pattern}$`)
}

const compiled = endpoints.map((endpoint) => ({ endpoint, regex: matcher(endpoint.path) }))

/**
 * Find the endpoint for a request. `pathWithQuery` may include a query string,
 * which is stripped before matching against the ordered endpoint table.
 */
export const matchEndpoint = (method: string, pathWithQuery: string): Endpoint | undefined => {
  const path = pathWithQuery.split('?', 1)[0] ?? pathWithQuery
  return compiled.find(({ endpoint, regex }) => endpoint.method === method && regex.test(path))
    ?.endpoint
}
