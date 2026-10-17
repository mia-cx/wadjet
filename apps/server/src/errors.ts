import type { ErrorCode } from '@wadjet/protocol'

export type ErrorCodeType = typeof ErrorCode.Type

/** Every status the protocol's error codes produce. */
type ErrorStatus = 400 | 401 | 404 | 409 | 410 | 413 | 415 | 500

/** A failure that maps to a protocol error response (status ≥ 400 with an ErrorBody). */
export class ProtocolError extends Error {
  readonly status: ErrorStatus
  readonly code: ErrorCodeType
  readonly headers: Readonly<Record<string, string>> | undefined

  constructor(
    status: ErrorStatus,
    code: ErrorCodeType,
    message: string,
    headers?: Readonly<Record<string, string>>,
  ) {
    super(message)
    this.name = 'ProtocolError'
    this.status = status
    this.code = code
    this.headers = headers
  }
}

export const invalidRequest = (message: string) =>
  new ProtocolError(400, 'invalid_request', message)

export const unauthorized = (message: string) =>
  new ProtocolError(401, 'unauthorized', message, { 'WWW-Authenticate': 'Bearer' })

export const notFound = (message: string) => new ProtocolError(404, 'not_found', message)

export const tooLarge = (message: string) => new ProtocolError(413, 'too_large', message)
