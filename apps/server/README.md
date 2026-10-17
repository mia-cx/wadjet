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
| `WADJET_BLOB_STORE` | no | `filesystem` | Blob backend: `filesystem` or `s3`. |
| `WADJET_S3_ENDPOINT` | with `s3` | — | S3 endpoint URL, such as `https://s3.eu-west-1.amazonaws.com`. |
| `WADJET_S3_BUCKET` | with `s3` | — | Bucket name. |
| `WADJET_S3_REGION` | no | `auto` | Signing region; use a real region for AWS. |
| `WADJET_S3_ACCESS_KEY_ID` | with `s3` | — | Access key. |
| `WADJET_S3_SECRET_ACCESS_KEY` | with `s3` | — | Secret key. |
| `WADJET_S3_FORCE_PATH_STYLE` | no | `false` | `true` for path-style URLs, needed by MinIO and most S3 clones. |
| `WADJET_DATABASE_URL` | no | unset | `postgres://…` file index; unset keeps SQLite under `WADJET_DATA_DIR`. |
| `WADJET_CLOUDFLARE_ZONE_ID` | no | unset | Cloudflare zone to purge. Node/Docker only; set both or neither. |
| `WADJET_CLOUDFLARE_API_TOKEN` | no | unset | API token with the zone's Cache Purge permission. Node/Docker only; set both or neither. |

The Cloudflare pair only applies to the Node/Docker server sitting behind a
proxied Cloudflare zone: deleting a file purges its URLs from the zone's
ordinary HTTP cache. The Worker serves from R2/D1 with no cache layer — a
Worker's Cache API entries use custom keys that zone purge-by-URL can't reach.

Only key hashes are stored. Hash a key before putting it in `WADJET_API_KEYS`:

```sh
printf %s "$KEY" | shasum -a 256
```

## Docker

Build from the repo root:

```sh
docker build -f apps/server/Dockerfile -t wadjet-server .
```

Run with the filesystem blob store and SQLite, keeping data on a volume:

```sh
docker run -d -p 8787:8787 -v wadjet:/data \
  -e WADJET_BASE_URL=http://localhost:8787 \
  -e 'WADJET_API_KEYS={"<sha256-of-your-key>": "you"}' \
  wadjet-server
```

Or with S3 for blobs and Postgres for the index (set `WADJET_S3_FORCE_PATH_STYLE=true` for MinIO):

```sh
docker run -d -p 8787:8787 \
  -e WADJET_BASE_URL=http://localhost:8787 \
  -e 'WADJET_API_KEYS={"<sha256-of-your-key>": "you"}' \
  -e WADJET_BLOB_STORE=s3 \
  -e WADJET_S3_ENDPOINT=https://s3.example.com \
  -e WADJET_S3_BUCKET=wadjet \
  -e WADJET_S3_ACCESS_KEY_ID=… \
  -e WADJET_S3_SECRET_ACCESS_KEY=… \
  -e 'WADJET_DATABASE_URL=postgres://wadjet:pw@db:5432/wadjet' \
  wadjet-server
```

`apps/server/docker-smoke.sh <image> <base-url> [docker-run args…]` runs a container, waits for the healthcheck, and round-trips an upload.

## Testing against real services

`pnpm test` covers memory, filesystem, and SQLite. The S3 and Postgres contract tests run with:

```sh
cd apps/server
WADJET_TEST_DATABASE_URL=postgres://wadjet:wadjet@127.0.0.1:5432/wadjet \
WADJET_TEST_S3_ENDPOINT=http://127.0.0.1:9000 \
WADJET_TEST_S3_ACCESS_KEY_ID=minioadmin \
WADJET_TEST_S3_SECRET_ACCESS_KEY=minioadmin \
pnpm test:docker
```

Local Postgres and MinIO for it:

```sh
docker run -d --name wadjet-pg -p 5432:5432 \
  -e POSTGRES_USER=wadjet -e POSTGRES_PASSWORD=wadjet -e POSTGRES_DB=wadjet postgres:18.6-bookworm
# MinIO's official images are gone, so CI builds it from the official source —
# the RELEASE.2025-10-15T17-29-55Z tag commit.
go install github.com/minio/minio@9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a
MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin \
  "$HOME/go/bin/minio" server /tmp/minio-data &
```

## Cloudflare

The server also runs as a Worker (`src/worker.ts`), with blobs in R2 and the file index in D1. From `apps/server`:

1. `pnpm exec wrangler r2 bucket create wadjet-blobs`
2. `pnpm exec wrangler d1 create wadjet`, then paste the `database_id` it prints into `wrangler.jsonc`.
3. Set `WADJET_BASE_URL` in `wrangler.jsonc` to the public URL.
4. `pnpm exec wrangler secret put` `WADJET_API_KEYS` (the zone pair doesn't apply to the Worker).
5. `pnpm exec wrangler d1 migrations apply wadjet --remote`
6. `pnpm exec wrangler deploy`
