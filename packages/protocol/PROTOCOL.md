# Wadjet Server protocol, v1

A Wadjet Server takes Captures from wadjet over HTTP: upload, list, and delete, signed in with an API key or OAuth.
This doc is the contract.
The Swift client in `apps/macos` and the server in `apps/server` both test against the fixtures it quotes, so neither side reads the other's code.

Every example below is a fixture file, quoted in full.
A test fails when a quote and its file disagree.

## Basics

- The user gives wadjet a base URL, such as `https://w.mia.cx`. Everything else comes from [discovery](#discovery).
- Every API path starts with `/v1`.
- Request and response bodies are JSON, unless they carry a file. JSON bodies use `Content-Type: application/json`.
- Times are RFC 3339 in UTC with second precision: `2026-10-16T12:02:13Z`.
- Sizes are bytes.
- File ids are 6 characters from `0-9A-Za-z`. A finished multipart upload keeps its upload's id.
- Clients ignore JSON fields they don't know.

| Method and path | Auth | Purpose |
| --- | --- | --- |
| `GET /.well-known/wadjet` | none | [Discovery](#discovery) |
| `POST /v1/files` | bearer | [Single upload](#single-upload), raw body |
| `GET /v1/files?cursor=&limit=` | bearer | [List](#list), newest first |
| `DELETE /v1/files/{id}` | bearer | [Delete](#delete) |
| `PUT /v1/files/{id}/thumbnail` | bearer | [Attach the thumbnail](#thumbnail) |
| `POST /v1/uploads` | bearer | [Start a multipart upload](#multipart-upload) |
| `PUT /v1/uploads/{id}/parts/{n}` | bearer | Send part `n`, raw body, counting from 1 |
| `GET /v1/uploads/{id}` | bearer | Which parts landed, for resume |
| `POST /v1/uploads/{id}/complete` | bearer | Finish; returns the file |
| `DELETE /v1/uploads/{id}` | bearer | Abort |
| `GET /v1/sharex.sxcu` | bearer | [ShareX config](#sharex-config) |
| `GET /{id}.{ext}`, `GET /{id}` | none | [The file](#files-and-thumbnails), with `HEAD` and `Range` |
| `GET /t/{id}` | none | The thumbnail |
| `GET /d/{token}`, `POST /d/{token}` | token | [Single-file deletion link](#deletion-link) |
| `GET /healthz` | none | [Health](#health) |

## Discovery

`GET /.well-known/wadjet` tells the client what this server speaks.

- `versions` lists the protocol versions the server supports. A client refuses a server whose list doesn't include a version it speaks.
- `auth.apiKey` is `true` when the server accepts API keys.
- `auth.oauth` is `null` when the server has no identity provider. Otherwise the client runs OAuth with PKCE against the `issuer`'s own OIDC discovery, with `clientId` and `scopes`.
- `limits` holds the sizes the client checks before it uploads. `maxFileBytes` is `null` when files have no cap.

The fixtures come from a server with tiny limits, so every body fits in the repo.
[Limits](#limits) lists the real defaults.
Clients read limits from discovery and never hardcode them.

<!-- fixture: 01-discovery -->
```json
{
  "name": "01-discovery",
  "request": {
    "method": "GET",
    "path": "/.well-known/wadjet",
    "headers": {},
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:00:00 GMT"
    },
    "body": {
      "protocol": "wadjet",
      "versions": [
        1
      ],
      "auth": {
        "apiKey": true,
        "oauth": {
          "issuer": "https://hecate.example",
          "clientId": "wadjet",
          "scopes": [
            "openid",
            "wadjet"
          ]
        }
      },
      "limits": {
        "maxRequestBytes": 4096,
        "partBytes": 1024,
        "maxFileBytes": null,
        "maxThumbnailBytes": 1024
      }
    }
  }
}
```

## Auth

Every `/v1` call sends `Authorization: Bearer <credential>`, except where the table says otherwise.

- **API key.** A random key that starts with `wdj_`. The server stores only a SHA-256 hash of each key, mapped to an owner. Each Mac gets its own key, so revoking one leaves the others working.
- **OAuth.** A JWT access token from the issuer in discovery. The server checks issuer, audience, expiry, and its access claim, and uses `sub` as the owner.

The server tells them apart by the `wdj_` prefix.
A missing, unknown, revoked, or expired credential gets `401` with `unauthorized`.
Every file belongs to an owner, and a caller only ever sees its owner's files.

<details>
<summary>A revoked API key</summary>

<!-- fixture: 19-list-files-unauthorized -->
```json
{
  "name": "19-list-files-unauthorized",
  "request": {
    "method": "GET",
    "path": "/v1/files",
    "headers": {
      "Authorization": "Bearer wdj_NwcSbBAhf6wp8yAOsoxK71ayVhjXPUVDpQPv4ZLmSKE"
    },
    "body": null
  },
  "response": {
    "status": 401,
    "headers": {
      "Content-Type": "application/json",
      "WWW-Authenticate": "Bearer",
      "Date": "Fri, 16 Oct 2026 12:20:02 GMT"
    },
    "body": {
      "error": {
        "code": "unauthorized",
        "message": "This API key is invalid or revoked."
      }
    }
  }
}
```

</details>

## Single upload

`POST /v1/files` uploads a whole file in one request.
The body is the raw file.
Clients use it for files up to `partBytes`, and [multipart](#multipart-upload) above that.

| Header | Required | Meaning |
| --- | --- | --- |
| `Content-Type` | yes | The file's MIME type. |
| `Content-Length` | yes | The body's size. R2 needs a known length to stream a body. |
| `Wadjet-Filename` | no | The file's name, percent-encoded UTF-8. Without it, the server names the file after its id and type, such as `aB3xK9.png`. |
| `Wadjet-Kind` | no | `screenshot` or `recording`. Without it, `video/*` and `image/gif` mean `recording`, and anything else means `screenshot`. |
| `Wadjet-Device` | no | The Mac's name, percent-encoded UTF-8. |
| `Idempotency-Key` | no | Any unique string, such as a UUID. A repeat with the same key and owner returns the first result. |

Percent-encoding keeps `A-Z a-z 0-9 - . _ ~` and encodes every other UTF-8 byte as `%XX`, so `Mia's MacBook Pro` becomes `Mia%27s%20MacBook%20Pro`.
The server also accepts a raw ASCII value, because ShareX sends `{filename}` unencoded.

The response is `201` with the [file object](#the-file-object) plus `deleteUrl`, the file's [deletion link](#deletion-link).
The link ends in the filename's extension, or the content type's when there's no filename.

<!-- fixture: 02-upload-file -->
```json
{
  "name": "02-upload-file",
  "request": {
    "method": "POST",
    "path": "/v1/files",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
      "Content-Type": "image/png",
      "Content-Length": "126",
      "Wadjet-Filename": "Screenshot%202026-10-16%20at%2014.02.11.png",
      "Wadjet-Kind": "screenshot",
      "Wadjet-Device": "Mia%27s%20MacBook%20Pro",
      "Idempotency-Key": "edb739d4-a2ed-422a-b927-2846efd3a794"
    },
    "body": "screenshot.png"
  },
  "response": {
    "status": 201,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:02:13 GMT"
    },
    "body": {
      "id": "aB3xK9",
      "url": "https://w.mia.cx/aB3xK9.png",
      "filename": "Screenshot 2026-10-16 at 14.02.11.png",
      "kind": "screenshot",
      "contentType": "image/png",
      "size": 126,
      "device": "Mia's MacBook Pro",
      "createdAt": "2026-10-16T12:02:13Z",
      "thumbnailUrl": null,
      "deleteUrl": "https://w.mia.cx/d/5mQeI1qnbywzZsvQ2MibRgZdGEmSSpZ_sh3HHTkl_FQ"
    }
  }
}
```

The server stores only a hash of the deletion token, so it can't show the link again.
A repeat with the same `Idempotency-Key` returns `200` with the first file and `deleteUrl: null`.
wadjet deletes with `DELETE /v1/files/{id}` and never needs the link.

<details>
<summary>A retried upload with the same <code>Idempotency-Key</code></summary>

<!-- fixture: 03-upload-file-repeat -->
```json
{
  "name": "03-upload-file-repeat",
  "request": {
    "method": "POST",
    "path": "/v1/files",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
      "Content-Type": "image/png",
      "Content-Length": "126",
      "Wadjet-Filename": "Screenshot%202026-10-16%20at%2014.02.11.png",
      "Wadjet-Kind": "screenshot",
      "Wadjet-Device": "Mia%27s%20MacBook%20Pro",
      "Idempotency-Key": "edb739d4-a2ed-422a-b927-2846efd3a794"
    },
    "body": "screenshot.png"
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:02:20 GMT"
    },
    "body": {
      "id": "aB3xK9",
      "url": "https://w.mia.cx/aB3xK9.png",
      "filename": "Screenshot 2026-10-16 at 14.02.11.png",
      "kind": "screenshot",
      "contentType": "image/png",
      "size": 126,
      "device": "Mia's MacBook Pro",
      "createdAt": "2026-10-16T12:02:13Z",
      "thumbnailUrl": null,
      "deleteUrl": null
    }
  }
}
```

</details>

A `Content-Length` over `maxRequestBytes` gets `413` with `too_large`, before the server reads the body.

<details>
<summary>A body over <code>maxRequestBytes</code></summary>

<!-- fixture: 04-upload-file-too-large -->
```json
{
  "name": "04-upload-file-too-large",
  "request": {
    "method": "POST",
    "path": "/v1/files",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
      "Content-Type": "application/octet-stream",
      "Content-Length": "4097"
    },
    "body": "too-large.bin"
  },
  "response": {
    "status": 413,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:02:30 GMT"
    },
    "body": {
      "error": {
        "code": "too_large",
        "message": "This server accepts up to 4096 bytes per request."
      }
    }
  }
}
```

</details>

### The file object

Single upload, multipart complete, thumbnail, and list all return the same file object.

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | The 6-character id. |
| `url` | string | The short link. |
| `filename` | string | The decoded filename. |
| `kind` | string | `screenshot` or `recording`. |
| `contentType` | string | The MIME type the upload sent. |
| `size` | integer | Bytes. |
| `device` | string or `null` | The Mac's name, decoded. |
| `createdAt` | time | When the upload finished. |
| `thumbnailUrl` | string or `null` | The [thumbnail](#thumbnail), once attached. |

Upload and complete responses add `deleteUrl`. Nothing else returns it.

## Thumbnail

`PUT /v1/files/{id}/thumbnail` attaches a small preview, so other Macs show the Capture without downloading it.
The body is a raw `image/webp`, `image/jpeg`, or `image/png` up to `maxThumbnailBytes`.
wadjet makes the thumbnail. The server never decodes or resizes images.

The response is `200` with the file object, `thumbnailUrl` set.
Sending a thumbnail again replaces it.
A body over `maxThumbnailBytes` gets `413` with `too_large`, and another type gets `415` with `unsupported_media_type`.

<!-- fixture: 05-attach-thumbnail -->
```json
{
  "name": "05-attach-thumbnail",
  "request": {
    "method": "PUT",
    "path": "/v1/files/aB3xK9/thumbnail",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
      "Content-Type": "image/webp",
      "Content-Length": "122"
    },
    "body": "thumbnail.webp"
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:02:31 GMT"
    },
    "body": {
      "id": "aB3xK9",
      "url": "https://w.mia.cx/aB3xK9.png",
      "filename": "Screenshot 2026-10-16 at 14.02.11.png",
      "kind": "screenshot",
      "contentType": "image/png",
      "size": 126,
      "device": "Mia's MacBook Pro",
      "createdAt": "2026-10-16T12:02:13Z",
      "thumbnailUrl": "https://w.mia.cx/t/aB3xK9"
    }
  }
}
```

## Multipart upload

Files bigger than `partBytes` upload in numbered parts, so a dropped connection costs one part instead of the whole file.

1. `POST /v1/uploads` with `{filename, kind, contentType, size, device}`. `contentType` and `size` are required; the rest follow the single-upload headers. It returns `201` with `{id, partBytes, partCount, expiresAt}`. A `size` over `maxFileBytes` gets `413`.
2. `PUT /v1/uploads/{id}/parts/{n}` for each part, from 1 to `partCount`, in any order. Every part except the last is exactly `partBytes`, because R2 needs equal part sizes. Sending a part again replaces it. Each returns `200` with `{number, size}`.
3. After a dropped connection, `GET /v1/uploads/{id}` returns the session plus `receivedParts`. The client sends the rest.
4. `POST /v1/uploads/{id}/complete` checks that every part landed. It returns `201` with the file object and `deleteUrl`. A missing part gets `409` with `upload_incomplete`.
5. `DELETE /v1/uploads/{id}` aborts the upload and frees its parts. It returns `204`.

`POST /v1/uploads` takes `Idempotency-Key` too. A repeat returns `200` with the first session.
Completing a finished upload again returns `200` with its file and `deleteUrl: null`, so a lost response is safe to retry.
A part of the wrong size, or a number outside `1..partCount`, gets `400` with `invalid_request`.

Unfinished uploads expire at `expiresAt`, 24 hours after they start.
After that, every call on the upload gets `410` with `upload_expired`, and the server frees its parts.

This Recording is 2517 bytes, so it goes up in three parts of 1024, 1024, and 469 bytes.
Part 2 drops, and the client completes too early.

<!-- fixture: 06-start-upload -->
```json
{
  "name": "06-start-upload",
  "request": {
    "method": "POST",
    "path": "/v1/uploads",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
      "Content-Type": "application/json",
      "Idempotency-Key": "cfbbb16f-9187-4cfa-aa64-936dc4a7b7dd"
    },
    "body": {
      "filename": "Recording 2026-10-16 at 14.05.31.mp4",
      "kind": "recording",
      "contentType": "video/mp4",
      "size": 2517,
      "device": "Mia's MacBook Pro"
    }
  },
  "response": {
    "status": 201,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:05:42 GMT"
    },
    "body": {
      "id": "Uq7Lm2",
      "partBytes": 1024,
      "partCount": 3,
      "expiresAt": "2026-10-17T12:05:42Z"
    }
  }
}
```

<details>
<summary>Parts 1 and 3 land</summary>

<!-- fixture: 07-upload-part-1 -->
```json
{
  "name": "07-upload-part-1",
  "request": {
    "method": "PUT",
    "path": "/v1/uploads/Uq7Lm2/parts/1",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
      "Content-Type": "application/octet-stream",
      "Content-Length": "1024"
    },
    "body": "recording.part1.bin"
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:05:43 GMT"
    },
    "body": {
      "number": 1,
      "size": 1024
    }
  }
}
```

<!-- fixture: 08-upload-part-3 -->
```json
{
  "name": "08-upload-part-3",
  "request": {
    "method": "PUT",
    "path": "/v1/uploads/Uq7Lm2/parts/3",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
      "Content-Type": "application/octet-stream",
      "Content-Length": "469"
    },
    "body": "recording.part3.bin"
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:05:44 GMT"
    },
    "body": {
      "number": 3,
      "size": 469
    }
  }
}
```

</details>

<details>
<summary>Completing with part 2 missing</summary>

<!-- fixture: 09-complete-upload-incomplete -->
```json
{
  "name": "09-complete-upload-incomplete",
  "request": {
    "method": "POST",
    "path": "/v1/uploads/Uq7Lm2/complete",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g"
    },
    "body": null
  },
  "response": {
    "status": 409,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:05:45 GMT"
    },
    "body": {
      "error": {
        "code": "upload_incomplete",
        "message": "Part 2 of 3 is missing."
      }
    }
  }
}
```

</details>

The client asks which parts landed, sends part 2, and completes.

<!-- fixture: 10-get-upload -->
```json
{
  "name": "10-get-upload",
  "request": {
    "method": "GET",
    "path": "/v1/uploads/Uq7Lm2",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g"
    },
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:05:58 GMT"
    },
    "body": {
      "id": "Uq7Lm2",
      "partBytes": 1024,
      "partCount": 3,
      "expiresAt": "2026-10-17T12:05:42Z",
      "receivedParts": [
        1,
        3
      ]
    }
  }
}
```

<details>
<summary>Part 2 lands</summary>

<!-- fixture: 11-upload-part-2 -->
```json
{
  "name": "11-upload-part-2",
  "request": {
    "method": "PUT",
    "path": "/v1/uploads/Uq7Lm2/parts/2",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
      "Content-Type": "application/octet-stream",
      "Content-Length": "1024"
    },
    "body": "recording.part2.bin"
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:05:59 GMT"
    },
    "body": {
      "number": 2,
      "size": 1024
    }
  }
}
```

</details>

<!-- fixture: 12-complete-upload -->
```json
{
  "name": "12-complete-upload",
  "request": {
    "method": "POST",
    "path": "/v1/uploads/Uq7Lm2/complete",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g"
    },
    "body": null
  },
  "response": {
    "status": 201,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:06:00 GMT"
    },
    "body": {
      "id": "Uq7Lm2",
      "url": "https://w.mia.cx/Uq7Lm2.mp4",
      "filename": "Recording 2026-10-16 at 14.05.31.mp4",
      "kind": "recording",
      "contentType": "video/mp4",
      "size": 2517,
      "device": "Mia's MacBook Pro",
      "createdAt": "2026-10-16T12:06:00Z",
      "thumbnailUrl": null,
      "deleteUrl": "https://w.mia.cx/d/eIipUchuHMYCyF5sa-JRAMyV6a-jZ3htmkInxF4xd5A"
    }
  }
}
```

<details>
<summary>A retried complete</summary>

<!-- fixture: 13-complete-upload-repeat -->
```json
{
  "name": "13-complete-upload-repeat",
  "request": {
    "method": "POST",
    "path": "/v1/uploads/Uq7Lm2/complete",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g"
    },
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:06:05 GMT"
    },
    "body": {
      "id": "Uq7Lm2",
      "url": "https://w.mia.cx/Uq7Lm2.mp4",
      "filename": "Recording 2026-10-16 at 14.05.31.mp4",
      "kind": "recording",
      "contentType": "video/mp4",
      "size": 2517,
      "device": "Mia's MacBook Pro",
      "createdAt": "2026-10-16T12:06:00Z",
      "thumbnailUrl": null,
      "deleteUrl": null
    }
  }
}
```

</details>

<details>
<summary>Aborting an upload</summary>

<!-- fixture: 14-start-upload-to-abort -->
```json
{
  "name": "14-start-upload-to-abort",
  "request": {
    "method": "POST",
    "path": "/v1/uploads",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
      "Content-Type": "application/json",
      "Idempotency-Key": "03e77487-4b0a-4218-8607-bd00aea4555e"
    },
    "body": {
      "filename": "Recording 2026-10-16 at 14.06.48.mp4",
      "kind": "recording",
      "contentType": "video/mp4",
      "size": 3000,
      "device": "Mia's MacBook Pro"
    }
  },
  "response": {
    "status": 201,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:07:00 GMT"
    },
    "body": {
      "id": "Pz2Wc5",
      "partBytes": 1024,
      "partCount": 3,
      "expiresAt": "2026-10-17T12:07:00Z"
    }
  }
}
```

<!-- fixture: 15-abort-upload -->
```json
{
  "name": "15-abort-upload",
  "request": {
    "method": "DELETE",
    "path": "/v1/uploads/Pz2Wc5",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g"
    },
    "body": null
  },
  "response": {
    "status": 204,
    "headers": {
      "Date": "Fri, 16 Oct 2026 12:07:05 GMT"
    },
    "body": null
  }
}
```

<!-- fixture: 16-get-upload-not-found -->
```json
{
  "name": "16-get-upload-not-found",
  "request": {
    "method": "GET",
    "path": "/v1/uploads/Pz2Wc5",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g"
    },
    "body": null
  },
  "response": {
    "status": 404,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:07:06 GMT"
    },
    "body": {
      "error": {
        "code": "not_found",
        "message": "No upload Pz2Wc5."
      }
    }
  }
}
```

</details>

<details>
<summary>A part sent after the upload expired</summary>

<!-- fixture: 31-start-upload-to-expire -->
```json
{
  "name": "31-start-upload-to-expire",
  "request": {
    "method": "POST",
    "path": "/v1/uploads",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
      "Content-Type": "application/json",
      "Idempotency-Key": "e517a5ce-dc99-4282-9dd7-7018ed73e995"
    },
    "body": {
      "filename": "Recording 2026-10-16 at 14.32.51.mp4",
      "kind": "recording",
      "contentType": "video/mp4",
      "size": 3000,
      "device": "Mia's MacBook Pro"
    }
  },
  "response": {
    "status": 201,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:33:00 GMT"
    },
    "body": {
      "id": "Hn4Rt8",
      "partBytes": 1024,
      "partCount": 3,
      "expiresAt": "2026-10-17T12:33:00Z"
    }
  }
}
```

<!-- fixture: 32-upload-part-expired -->
```json
{
  "name": "32-upload-part-expired",
  "request": {
    "method": "PUT",
    "path": "/v1/uploads/Hn4Rt8/parts/1",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
      "Content-Type": "application/octet-stream",
      "Content-Length": "1024"
    },
    "body": "recording.part1.bin"
  },
  "response": {
    "status": 410,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Sat, 17 Oct 2026 12:33:01 GMT"
    },
    "body": {
      "error": {
        "code": "upload_expired",
        "message": "This upload expired at 2026-10-17T12:33:00Z."
      }
    }
  }
}
```

</details>

## List

`GET /v1/files?cursor=&limit=` returns `{items, nextCursor}`.
Items are file objects without `deleteUrl`, newest first.
Only finished uploads appear.

- `limit` defaults to 50, with a maximum of 200.
- `cursor` is opaque. It encodes the last item's `(createdAt, id)`, so new uploads never shift a page.
- `nextCursor` is `null` on the last page.

The server never pushes changes. wadjet lists when the History window opens and on Refresh.

<!-- fixture: 17-list-files -->
```json
{
  "name": "17-list-files",
  "request": {
    "method": "GET",
    "path": "/v1/files?limit=1",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g"
    },
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:20:00 GMT"
    },
    "body": {
      "items": [
        {
          "id": "Uq7Lm2",
          "url": "https://w.mia.cx/Uq7Lm2.mp4",
          "filename": "Recording 2026-10-16 at 14.05.31.mp4",
          "kind": "recording",
          "contentType": "video/mp4",
          "size": 2517,
          "device": "Mia's MacBook Pro",
          "createdAt": "2026-10-16T12:06:00Z",
          "thumbnailUrl": null
        }
      ],
      "nextCursor": "WyIyMDI2LTEwLTE2VDEyOjA2OjAwWiIsIlVxN0xtMiJd"
    }
  }
}
```

<details>
<summary>The next page</summary>

<!-- fixture: 18-list-files-next-page -->
```json
{
  "name": "18-list-files-next-page",
  "request": {
    "method": "GET",
    "path": "/v1/files?cursor=WyIyMDI2LTEwLTE2VDEyOjA2OjAwWiIsIlVxN0xtMiJd&limit=1",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g"
    },
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:20:01 GMT"
    },
    "body": {
      "items": [
        {
          "id": "aB3xK9",
          "url": "https://w.mia.cx/aB3xK9.png",
          "filename": "Screenshot 2026-10-16 at 14.02.11.png",
          "kind": "screenshot",
          "contentType": "image/png",
          "size": 126,
          "device": "Mia's MacBook Pro",
          "createdAt": "2026-10-16T12:02:13Z",
          "thumbnailUrl": "https://w.mia.cx/t/aB3xK9"
        }
      ],
      "nextCursor": null
    }
  }
}
```

</details>

## Delete

`DELETE /v1/files/{id}` returns `204`.
It removes the file, its thumbnail, and its row, then purges both URLs from every cache, Cloudflare's edge included.
An unknown id, or someone else's file, gets `404` with `not_found`, never `403`.

<!-- fixture: 29-delete-file -->
```json
{
  "name": "29-delete-file",
  "request": {
    "method": "DELETE",
    "path": "/v1/files/Uq7Lm2",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g"
    },
    "body": null
  },
  "response": {
    "status": 204,
    "headers": {
      "Date": "Fri, 16 Oct 2026 12:32:00 GMT"
    },
    "body": null
  }
}
```

<details>
<summary>Deleting it again</summary>

<!-- fixture: 30-delete-file-not-found -->
```json
{
  "name": "30-delete-file-not-found",
  "request": {
    "method": "DELETE",
    "path": "/v1/files/Uq7Lm2",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g"
    },
    "body": null
  },
  "response": {
    "status": 404,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:32:01 GMT"
    },
    "body": {
      "error": {
        "code": "not_found",
        "message": "No file Uq7Lm2."
      }
    }
  }
}
```

</details>

## Files and thumbnails

`GET /{id}.{ext}` and `GET /{id}` stream the file, with no auth.
The extension is cosmetic: the server finds the file by id and sends its stored type.
`GET /t/{id}` streams the thumbnail the same way.
All three answer `HEAD` too.

- `Range` takes one byte range and returns `206` with `Content-Range`. The server sends the whole file with `200` for a range it can't satisfy, or for several ranges.
- `Cache-Control: public, max-age=31536000, immutable`, because ids never come back.
- Images, video, audio, PDF, and plain text display inline. Everything else downloads as an attachment, HTML and SVG included, so an upload never runs as a page on the server's domain.
- `X-Content-Type-Options: nosniff` on every file and thumbnail.
- An `ETag`, whose value the server chooses.

<!-- fixture: 20-get-file -->
```json
{
  "name": "20-get-file",
  "request": {
    "method": "GET",
    "path": "/aB3xK9.png",
    "headers": {},
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "image/png",
      "Content-Length": "126",
      "Accept-Ranges": "bytes",
      "Cache-Control": "public, max-age=31536000, immutable",
      "Content-Disposition": "inline; filename*=UTF-8''Screenshot%202026-10-16%20at%2014.02.11.png",
      "X-Content-Type-Options": "nosniff",
      "Date": "Fri, 16 Oct 2026 12:21:00 GMT"
    },
    "body": "screenshot.png"
  }
}
```

<details>
<summary>Without the extension</summary>

<!-- fixture: 21-get-file-without-extension -->
```json
{
  "name": "21-get-file-without-extension",
  "request": {
    "method": "GET",
    "path": "/aB3xK9",
    "headers": {},
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "image/png",
      "Content-Length": "126",
      "Accept-Ranges": "bytes",
      "Cache-Control": "public, max-age=31536000, immutable",
      "Content-Disposition": "inline; filename*=UTF-8''Screenshot%202026-10-16%20at%2014.02.11.png",
      "X-Content-Type-Options": "nosniff",
      "Date": "Fri, 16 Oct 2026 12:21:01 GMT"
    },
    "body": "screenshot.png"
  }
}
```

</details>

<details>
<summary><code>HEAD</code></summary>

<!-- fixture: 22-head-file -->
```json
{
  "name": "22-head-file",
  "request": {
    "method": "HEAD",
    "path": "/aB3xK9.png",
    "headers": {},
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "image/png",
      "Content-Length": "126",
      "Accept-Ranges": "bytes",
      "Cache-Control": "public, max-age=31536000, immutable",
      "Content-Disposition": "inline; filename*=UTF-8''Screenshot%202026-10-16%20at%2014.02.11.png",
      "X-Content-Type-Options": "nosniff",
      "Date": "Fri, 16 Oct 2026 12:21:02 GMT"
    },
    "body": null
  }
}
```

</details>

<details>
<summary>A byte range of a Recording</summary>

<!-- fixture: 23-get-file-range -->
```json
{
  "name": "23-get-file-range",
  "request": {
    "method": "GET",
    "path": "/Uq7Lm2.mp4",
    "headers": {
      "Range": "bytes=0-99"
    },
    "body": null
  },
  "response": {
    "status": 206,
    "headers": {
      "Content-Type": "video/mp4",
      "Content-Length": "100",
      "Accept-Ranges": "bytes",
      "Cache-Control": "public, max-age=31536000, immutable",
      "Content-Range": "bytes 0-99/2517",
      "Content-Disposition": "inline; filename*=UTF-8''Recording%202026-10-16%20at%2014.05.31.mp4",
      "X-Content-Type-Options": "nosniff",
      "Date": "Fri, 16 Oct 2026 12:21:03 GMT"
    },
    "body": "recording.bytes-0-99.bin"
  }
}
```

</details>

<details>
<summary>The thumbnail</summary>

<!-- fixture: 24-get-thumbnail -->
```json
{
  "name": "24-get-thumbnail",
  "request": {
    "method": "GET",
    "path": "/t/aB3xK9",
    "headers": {},
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "image/webp",
      "Content-Length": "122",
      "Accept-Ranges": "bytes",
      "Cache-Control": "public, max-age=31536000, immutable",
      "X-Content-Type-Options": "nosniff",
      "Date": "Fri, 16 Oct 2026 12:21:04 GMT"
    },
    "body": "thumbnail.webp"
  }
}
```

</details>

<details>
<summary>A deleted file</summary>

<!-- fixture: 28-get-file-not-found -->
```json
{
  "name": "28-get-file-not-found",
  "request": {
    "method": "GET",
    "path": "/aB3xK9.png",
    "headers": {},
    "body": null
  },
  "response": {
    "status": 404,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Fri, 16 Oct 2026 12:31:06 GMT"
    },
    "body": {
      "error": {
        "code": "not_found",
        "message": "No file aB3xK9."
      }
    }
  }
}
```

</details>

## Deletion link

Each upload's `deleteUrl` is `/d/{token}`, where the token is 32 random bytes in base64url.
It deletes that one file and nothing else.

`GET /d/{token}` shows a small page naming the file, with a Delete button.
The button sends `POST /d/{token}`, which deletes and purges like `DELETE /v1/files/{id}`.
Link previews and prefetchers only send `GET`, so they can't delete anything.
Once the file is gone, the link gets `404` with `not_found`.

<!-- fixture: 26-get-deletion-page -->
```json
{
  "name": "26-get-deletion-page",
  "request": {
    "method": "GET",
    "path": "/d/5mQeI1qnbywzZsvQ2MibRgZdGEmSSpZ_sh3HHTkl_FQ",
    "headers": {},
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Date": "Fri, 16 Oct 2026 12:31:00 GMT"
    },
    "body": "deletion-page.html"
  }
}
```

<details>
<summary>Pressing Delete</summary>

<!-- fixture: 27-delete-by-link -->
```json
{
  "name": "27-delete-by-link",
  "request": {
    "method": "POST",
    "path": "/d/5mQeI1qnbywzZsvQ2MibRgZdGEmSSpZ_sh3HHTkl_FQ",
    "headers": {
      "Content-Type": "application/x-www-form-urlencoded"
    },
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Date": "Fri, 16 Oct 2026 12:31:05 GMT"
    },
    "body": "deleted-page.html"
  }
}
```

</details>

## ShareX config

`GET /v1/sharex.sxcu` downloads a ready-made ShareX custom uploader.
It embeds the API key that fetched it, so it needs an API key; an OAuth token gets `400` with `invalid_request`.
ShareX can't upload in parts, so its files cap at `maxRequestBytes`.
It shows `url` as the link and `deleteUrl` as the deletion link.

<!-- fixture: 25-get-sharex-config -->
```json
{
  "name": "25-get-sharex-config",
  "request": {
    "method": "GET",
    "path": "/v1/sharex.sxcu",
    "headers": {
      "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g"
    },
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Content-Disposition": "attachment; filename=\"w.mia.cx.sxcu\"",
      "Date": "Fri, 16 Oct 2026 12:30:00 GMT"
    },
    "body": {
      "Version": "13.7.0",
      "Name": "Wadjet (w.mia.cx)",
      "DestinationType": "ImageUploader, FileUploader",
      "RequestMethod": "POST",
      "RequestURL": "https://w.mia.cx/v1/files",
      "Headers": {
        "Authorization": "Bearer wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g",
        "Wadjet-Filename": "{filename}",
        "Wadjet-Device": "ShareX"
      },
      "Body": "Binary",
      "URL": "{json:url}",
      "DeletionURL": "{json:deleteUrl}",
      "ErrorMessage": "{json:error.message}"
    }
  }
}
```

## Health

`GET /healthz` returns `200` once the server is ready, for Docker and Kubernetes.

<!-- fixture: 33-healthz -->
```json
{
  "name": "33-healthz",
  "request": {
    "method": "GET",
    "path": "/healthz",
    "headers": {},
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json",
      "Date": "Sat, 17 Oct 2026 12:34:00 GMT"
    },
    "body": {
      "status": "ok"
    }
  }
}
```

## Errors

Every error body is `{"error": {"code": "...", "message": "..."}}`.
Clients branch on `code` and show `message`, which is for people and can change.

| Code | Status | When |
| --- | --- | --- |
| `invalid_request` | 400 | The request is malformed. |
| `unauthorized` | 401 | The credential is missing, unknown, revoked, or expired. |
| `not_found` | 404 | No such file, upload, or deletion link for this caller. |
| `upload_incomplete` | 409 | Complete found a missing part. |
| `upload_expired` | 410 | The upload passed `expiresAt`. |
| `too_large` | 413 | The body or file is over a limit. |
| `unsupported_media_type` | 415 | The thumbnail isn't WebP, JPEG, or PNG. |
| `internal` | 500 | The server failed. |

Network errors and `5xx` are the only outcomes a client retries.
After `upload_incomplete`, the client asks which parts landed and sends the rest.

## Versioning

A breaking change gets a new path prefix, such as `/v2`, and a new entry in `versions`.
New fields aren't breaking.

## Limits

| Limit | Default | Fixtures |
| --- | --- | --- |
| `maxRequestBytes` | 100000000 (100 MB, Cloudflare Free's per-request cap) | 4096 |
| `partBytes` | 67108864 (64 MiB) | 1024 |
| `maxFileBytes` | `null` | `null` |
| `maxThumbnailBytes` | 262144 (256 KiB) | 1024 |

Docker and Helm can change all four.
At 64 MiB parts, R2's 10,000-part ceiling allows files up to 625 GiB.

## Fixtures

The fixtures live in [`packages/protocol/fixtures/`](fixtures/), relative to the repo root.
Each `NN-name.json` is one request and its response:

```json
{
  "name": "NN-name",
  "request": { "method": "...", "path": "...", "headers": {}, "body": null },
  "response": { "status": 200, "headers": {}, "body": null }
}
```

- `name` is the filename without `.json`.
- `path` includes the query string.
- Header names are case-insensitive. A fixture lists the headers the protocol defines; a client or server can send more.
- `body` is `null` for an empty body. When the side's `Content-Type` is `application/json`, `body` is the JSON value. Otherwise it's the name of a file beside the fixture that holds the raw bytes.
- Compare JSON bodies as values, not bytes. Compare raw bodies byte for byte.
- `Content-Length` appears only on raw bodies.

The fixtures tell one story, in filename order, against one server:

- The server runs with the config in `01-discovery` and base URL `https://w.mia.cx`.
- API key `wdj_jFAhjraITcvwgTG2w28qJ_fO36gbfqY4N8OCjtmCJ3g` maps to the owner. `wdj_NwcSbBAhf6wp8yAOsoxK71ayVhjXPUVDpQPv4ZLmSKE` is revoked.
- The clock reads each response's `Date` header while the server handles that request. The story jumps a day before `32-upload-part-expired`.
- The id generator returns `aB3xK9`, `Uq7Lm2`, `Pz2Wc5`, `Hn4Rt8`, in that order.
- The token generator returns `5mQeI1qnbywzZsvQ2MibRgZdGEmSSpZ_sh3HHTkl_FQ`, then `eIipUchuHMYCyF5sa-JRAMyV6a-jZ3htmkInxF4xd5A`.

The server's replay suite sends every request and checks the exact response.
The Swift contract test in `apps/macos` builds each request from the same inputs and decodes each response.
It reads the folder straight from the repo, so neither side mocks the other.
