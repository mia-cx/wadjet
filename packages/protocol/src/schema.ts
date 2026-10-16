import { Schema } from 'effect'

const int = Schema.Number.check(Schema.isInt())
const positiveInt = int.check(Schema.isGreaterThanOrEqualTo(1))
const nonNegativeInt = int.check(Schema.isGreaterThanOrEqualTo(0))

/** File kind: a still capture or a screen recording. */
export const Kind = Schema.Literals(['screenshot', 'recording'])

/** Six-character alphanumeric file or upload identifier. */
export const Id = Schema.String.check(Schema.isPattern(/^[0-9A-Za-z]{6}$/))

/** RFC 3339 UTC timestamp with second precision, such as `2026-10-16T12:02:13Z`. */
export const Time = Schema.String.check(Schema.isPattern(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/))

/** Server discovery document served at `/.well-known/wadjet`. */
export const Discovery = Schema.Struct({
  protocol: Schema.Literal('wadjet'),
  versions: Schema.NonEmptyArray(positiveInt),
  auth: Schema.Struct({
    apiKey: Schema.Boolean,
    oauth: Schema.NullOr(
      Schema.Struct({
        issuer: Schema.String,
        clientId: Schema.String,
        scopes: Schema.Array(Schema.String),
      }),
    ),
  }),
  limits: Schema.Struct({
    maxRequestBytes: nonNegativeInt,
    partBytes: positiveInt,
    maxFileBytes: Schema.NullOr(nonNegativeInt),
    maxThumbnailBytes: nonNegativeInt,
  }),
})

/** A stored file as returned by the API; `thumbnailUrl` carries the current `?v={n}` version. */
export const File = Schema.Struct({
  id: Id,
  url: Schema.String,
  filename: Schema.String,
  kind: Kind,
  contentType: Schema.String,
  size: nonNegativeInt,
  device: Schema.NullOr(Schema.String),
  createdAt: Time,
  thumbnailUrl: Schema.NullOr(
    Schema.String.check(Schema.isPattern(/\/t\/[0-9A-Za-z]{6}\?v=[1-9]\d*$/)),
  ),
})

/** A stored file after upload, with a deletion URL unless the upload was an idempotent repeat. */
export const UploadedFile = Schema.Struct({
  ...File.fields,
  deleteUrl: Schema.NullOr(Schema.String),
})

/** One page of the file list. */
export const FilePage = Schema.Struct({
  items: Schema.Array(File),
  nextCursor: Schema.NullOr(Schema.String),
})

/** Query parameters for `GET /v1/files`, decoded from the URL query string. */
export const ListQuery = Schema.fromURLSearchParams(
  Schema.Struct({
    cursor: Schema.optionalKey(Schema.String),
    limit: Schema.optionalKey(
      Schema.NumberFromString.check(Schema.isInt(), Schema.isBetween({ minimum: 1, maximum: 200 })),
    ),
  }),
)

/** Query for the canonical thumbnail URL `/t/{id}?v={n}`; any other query answers `301`. */
export const ThumbnailQuery = Schema.fromURLSearchParams(
  Schema.Struct({
    v: Schema.NumberFromString.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1)),
  }),
)

/** Request body for `POST /v1/uploads` (start a multipart upload). */
export const StartUpload = Schema.Struct({
  filename: Schema.optionalKey(Schema.String),
  kind: Schema.optionalKey(Kind),
  contentType: Schema.String,
  size: nonNegativeInt,
  device: Schema.optionalKey(Schema.String),
})

/** A multipart upload session. */
export const UploadSession = Schema.Struct({
  id: Id,
  partBytes: positiveInt,
  partCount: positiveInt,
  expiresAt: Time,
})

/** An upload session plus the part numbers received so far. */
export const UploadStatus = Schema.Struct({
  ...UploadSession.fields,
  receivedParts: Schema.Array(positiveInt),
})

/** Acknowledgement of a received upload part. */
export const PartReceipt = Schema.Struct({
  number: positiveInt,
  size: nonNegativeInt,
})

/** Machine-readable error codes for every non-2xx response. */
export const ErrorCode = Schema.Literals([
  'unauthorized',
  'not_found',
  'too_large',
  'invalid_request',
  'unsupported_media_type',
  'upload_incomplete',
  'upload_expired',
  'internal',
])

/** Error envelope returned for every status ≥ 400. */
export const ErrorBody = Schema.Struct({
  error: Schema.Struct({
    code: ErrorCode,
    message: Schema.String,
  }),
})

/** Health check response; `200` once the server is ready. */
export const Health = Schema.Struct({
  status: Schema.Literal('ok'),
})

/** ShareX custom-uploader config served at `/v1/sharex.sxcu` (field names are ShareX's). */
export const ShareXConfig = Schema.Struct({
  Version: Schema.String,
  Name: Schema.String,
  DestinationType: Schema.String,
  RequestMethod: Schema.Literal('POST'),
  RequestURL: Schema.String,
  Headers: Schema.Record(Schema.String, Schema.String),
  Body: Schema.Literal('Binary'),
  URL: Schema.String,
  DeletionURL: Schema.String,
  ErrorMessage: Schema.String,
})

// Struct decoding ignores undeclared keys, so extra headers are allowed.
const bearer = Schema.String.check(Schema.isPattern(/^Bearer \S+$/))

/** Any request carrying an `Authorization: Bearer <key>` header. */
export const BearerHeaders = Schema.Struct({
  authorization: bearer,
})

const contentLength = Schema.NumberFromString.check(
  Schema.isInt(),
  Schema.isGreaterThanOrEqualTo(0),
)

/** Headers for `POST /v1/files` (direct upload). */
export const UploadFileHeaders = Schema.Struct({
  ...BearerHeaders.fields,
  'content-type': Schema.String,
  'content-length': contentLength,
  'wadjet-filename': Schema.optionalKey(Schema.String),
  'wadjet-kind': Schema.optionalKey(Kind),
  'wadjet-device': Schema.optionalKey(Schema.String),
  'idempotency-key': Schema.optionalKey(Schema.String),
})

/** Headers for `POST /v1/uploads` (start multipart upload). */
export const StartUploadHeaders = Schema.Struct({
  ...BearerHeaders.fields,
  'idempotency-key': Schema.optionalKey(Schema.String),
})

/** Headers for `PUT /v1/uploads/{id}/parts/{n}`. */
export const PartHeaders = Schema.Struct({
  ...BearerHeaders.fields,
  'content-type': Schema.String,
  'content-length': contentLength,
})

/** Headers for `PUT /v1/files/{id}/thumbnail`. */
export const ThumbnailHeaders = Schema.Struct({
  ...BearerHeaders.fields,
  'content-type': Schema.Literals(['image/webp', 'image/jpeg', 'image/png']),
  'content-length': contentLength,
})
