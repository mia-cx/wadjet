# @wadjet/server

The Wadjet Server on Node: it receives Captures from wadjet over HTTP — upload, list, delete, serve — per `packages/protocol/PROTOCOL.md`.

## Run

From the repo root:

```sh
pnpm dev
```

`pnpm dev` loads `.env.development`, which sets `WADJET_BASE_URL=http://localhost:8787` and a single API key, `wdj_dev`. Shell environment variables override the file.

```sh
curl -X POST http://localhost:8787/v1/files \
  -H "Authorization: Bearer wdj_dev" \
  -H "Content-Type: image/png" \
  --data-binary @shot.png
```

Data lands under `apps/server/data/` (SQLite plus blobs). `pnpm start` runs the built `dist/node.js`.

## Configuration

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `WADJET_BASE_URL` | yes | — | Public base URL, no path, such as `https://w.mia.cx`. |
| `WADJET_API_KEYS` | yes | — | JSON object mapping each key's SHA-256 hex hash to its owner. |
| `WADJET_DATA_DIR` | no | `./data` | Where the SQLite index and blob files live. |
| `PORT` | no | `8787` | Listen port. |
| `WADJET_MAX_REQUEST_BYTES` | no | `100000000` | Per-request body cap. |
| `WADJET_PART_BYTES` | no | `67108864` | Multipart part size (multipart arrives in #51). |
| `WADJET_MAX_FILE_BYTES` | no | unset (no cap) | File size cap. |
| `WADJET_MAX_THUMBNAIL_BYTES` | no | `262144` | Thumbnail cap (thumbnails arrive in #51). |

Only key hashes are stored. Hash a key before putting it in `WADJET_API_KEYS`:

```sh
printf %s "$KEY" | shasum -a 256
```
