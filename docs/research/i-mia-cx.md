# i.mia.cx upload API today

Resolves #6. Researched 2026-10-07 without uploads, deletion requests, or production changes.

## Short answer

i.mia.cx accepts a raw binary `POST /upload`, authenticated with `x-auth-key: <redacted>`. Send `Content-Type` and `Content-Length`. JSON returns `success`, `image` (the public URL), and `deleteUrl`. MP4 and GIF pass through unchanged; there is no file-type allowlist. Deletion already works, but its returned URL contains the shared auth key. Large Recordings need a new multi-request multipart upload protocol. The effective single-request ceiling depends on the Cloudflare zone plan and configuration, which this research did not verify. [S1, S2, S3, S9]

The server source is **[mia-riezebos/ShareX-R2-Cloudflare-Workers](https://github.com/mia-riezebos/ShareX-R2-Cloudflare-Workers)**, Mia's fork of Cherry's Worker. No server checkout was found under `~/Development` using filename and content searches, including hidden files but excluding Git internals and dependencies. Its `wrangler.jsonc` binds Worker `sharex-r2-upload` to domain `i.mia.cx` and R2 bucket `i-mia-cx`. The latest commit, `35cd029ea7977130a9f793fd5244e6325f83c375`, has a successful verification and production deployment run. This identifies the deployment source; it does not prove nobody subsequently changed dashboard settings. [S2, S4]

## Request and authentication

```http
POST /upload?filename=capture-unique.mp4 HTTP/1.1
Host: i.mia.cx
x-auth-key: <redacted>
Content-Type: video/mp4
Content-Length: <file byte count>

<raw file bytes>
```

- `filename` is an optional URL query parameter. The server stores `YYYY/MM/<filename>`, using the upload date. Without it, the server generates an extensionless UUID. Reusing a filename in the same month overwrites that object; wadjet should generate unique filenames. [S1]
- The body is the file itself. The endpoint does not parse `multipart/form-data`; sending a form would store its boundary and wrapper bytes too. [S1]
- The server requires both headers to be present. Missing either produces HTTP 400. It does not compare `Content-Length` against an application limit or inspect the MIME type. [S1]
- Authentication accepts either the header or `?authkey=<redacted>`, comparing it with `env.AUTH_KEY`. Use the header. Failed authentication returns HTTP 401 with `{"success":false,"error":"Missing auth"}`. [S1]
- The installed iShare Destination named `imcx` has binary body mode, endpoint `https://i.mia.cx/upload`, header authentication, `{{image}}`, `{{deleteUrl}}`, and deletion method `GET`. This matches the reference config. Preferences prove configuration, not actual header emission or successful uploads. [S5, S6]
- The local shell client sends `POST -T <file>`, derives MIME type with `file --mime-type`, and supplies `filename`. It has no file-size check. Its normal output selects `.image`; full JSON is opt-in. [S7]

For a GIF, send `Content-Type: image/gif`. For an MP4 Recording, send `video/mp4`. The server accepts either because it streams `request.body` directly into `R2_BUCKET.put` and stores the supplied MIME type. It does not transcode or validate media. Browser playback still depends on the Recording's codec. [S1]

## Response and deletion

Successful uploads return HTTP 200 and `Content-Type: application/json`:

```json
{
  "success": true,
  "image": "https://i.mia.cx/file/2026/10/capture-unique.mp4",
  "deleteUrl": "https://i.mia.cx/delete?filename=2026%2F10%2Fcapture-unique.mp4&authkey=<redacted>"
}
```

Query parameter order is immaterial. The URL field is `image` even for videos, GIFs, text, and other files. Optional `CUSTOM_PUBLIC_BUCKET_DOMAIN` changes the public host and removes `/file/`; the checked-in deployment config does not set it. [S1, S2]

`GET /delete?filename=<URL-encoded R2 key>` accepts header authentication, so wadjet can delete without using a credential-bearing URL. Success returns `{"success":true}`. A missing filename returns 404. Storage failures return 500 with `success:false`, `message`, and an `error` object containing `name` and `message`. Upload storage failures use the same shape. Missing upload headers use `message`, whereas auth failures use `error` as a string; error handling must accept both. [S1, S8]

Treat `deleteUrl` as a credential. It contains the global key, not an object-specific deletion token. Do not copy it with the public URL or put it in logs. Moreover, the upload response builds `image` from the request URL and removes only `filename`. Query-string authentication therefore leaks `authkey` into `image` too. Header authentication avoids that path. [S1, S6]

The Worker sets a seven-day public cache lifetime. Deletion removes the R2 object and calls `caches.default.delete`; this does not establish immediate eviction from every edge or browser cache. Public retrieval uses `render2`, with GET and HEAD routes; the README describes range handling. Large-video playback and global deletion visibility remain untested. [S1, S4]

## Limits at each layer

| Layer | Current evidence | Consequence |
| --- | --- | --- |
| wadjet | At the researched `origin/main` base `20cb424`, the repo contains domain and agent docs, with no application implementation. | No implemented app upload cap exists yet. |
| Existing clients | The local shell script has no cap. The iShare saved Destination contains no size policy; iShare implementation was outside this ticket. [S5, S7] | A client-side ceiling is not established. |
| Worker application | Requires length/type headers; no numeric size ceiling. It streams into R2 instead of buffering the whole file. [S1] | No additional coded upload cap. |
| Reverse proxy | `i.mia.cx` is a Workers custom domain. No nginx, Caddy, or separate origin proxy appears in the deployment source. [S2] | No separate configured proxy cap was found. Dashboard overrides remain unknown. |
| Cloudflare edge | Free: 100 MB; Pro: 100 MB; Business: 200 MB; Enterprise: up to 5 GB self-serve. Larger Enterprise limits require Cloudflare support. Limits depend on the Cloudflare plan, not the Workers subscription. [S9] | Oversized requests return 413. The actual zone plan and Maximum Upload Size are unverified. |
| Worker memory | 128 MB per isolate. [S9] | Streaming avoids a whole-file allocation; 128 MB is not a file-size cap. |
| R2 storage | Single-part upload: 5 GiB. Multipart: up to 10,000 parts and roughly 5 TiB total (limits table specifies 4.995 TiB). [S10] | The current Worker calls single-part `put`; edge limits normally bind first. |

Cloudflare's current Workers documentation supersedes the older generic “Enterprise 500 MB” figure. Do not hard-code a guessed i.mia.cx limit. Confirm the zone plan and configured maximum before choosing wadjet's Destination policy. [S9]

## Changes for large Recordings

These are proposed follow-up tickets, not implemented changes:

1. **Add resumable R2 multipart uploads.** Add authenticated create, upload-part, complete, and abort endpoints. Keep each part below the confirmed edge ceiling. Stream parts and preserve `uploadId`, part numbers, and ETags for retry/resume. Return the existing public URL response only after completion. Set MIME type and unique object key when creating the upload. Cloudflare documents this Worker protocol. A single HTTP request using chunked transfer or `multipart/form-data` cannot bypass the edge body ceiling; the current header requirement also rules out lengthless requests. [S1, S9, S11]
2. **Replace credential-bearing deletion links.** Use an authenticated DELETE endpoint or an opaque object-scoped deletion token. Strip authentication parameters from public response URLs. Keep the legacy contract during client migration. Define cache invalidation and abort/cleanup behavior for cancelled uploads. Existing R2 object deletion already handles completed files regardless of media type or size. [S1]
3. **Verify the deployment contract and add wadjet Destination policy.** Record the actual zone plan, Maximum Upload Size, active Worker version, and dashboard overrides. Add file-backed binary uploads, explicit MIME/length, progress, cancellation, and a useful 413 result. Validate MP4/GIF upload, range playback, resume, and deletion in an isolated test deployment. No live write verification was performed here.

## Sources

Server references below are pinned to commit `35cd029ea7977130a9f793fd5244e6325f83c375`.

- **S1:** [`src/routes.ts:12–25`](https://github.com/mia-riezebos/ShareX-R2-Cloudflare-Workers/blob/35cd029ea7977130a9f793fd5244e6325f83c375/src/routes.ts#L12-L25), authentication; [`49–120`](https://github.com/mia-riezebos/ShareX-R2-Cloudflare-Workers/blob/35cd029ea7977130a9f793fd5244e6325f83c375/src/routes.ts#L49-L120), upload, storage, response; [`123–180`](https://github.com/mia-riezebos/ShareX-R2-Cloudflare-Workers/blob/35cd029ea7977130a9f793fd5244e6325f83c375/src/routes.ts#L123-L180), public retrieval and deletion.
- **S2:** [`wrangler.jsonc:3–19`](https://github.com/mia-riezebos/ShareX-R2-Cloudflare-Workers/blob/35cd029ea7977130a9f793fd5244e6325f83c375/wrangler.jsonc#L3-L19), Worker name, custom domain, R2 binding.
- **S3:** [`test/upload.test.ts:21–69`](https://github.com/mia-riezebos/ShareX-R2-Cloudflare-Workers/blob/35cd029ea7977130a9f793fd5244e6325f83c375/test/upload.test.ts#L21-L69), missing-header and successful-response tests.
- **S4:** [`README.md:13–30`](https://github.com/mia-riezebos/ShareX-R2-Cloudflare-Workers/blob/35cd029ea7977130a9f793fd5244e6325f83c375/README.md#L13-L30), deployment ownership; [`README.md:73–75`](https://github.com/mia-riezebos/ShareX-R2-Cloudflare-Workers/blob/35cd029ea7977130a9f793fd5244e6325f83c375/README.md#L73-L75), range handling; [successful CI and deploy run](https://github.com/mia-riezebos/ShareX-R2-Cloudflare-Workers/actions/runs/31517536442). Workflow [`main.yml:36–59`](https://github.com/mia-riezebos/ShareX-R2-Cloudflare-Workers/blob/35cd029ea7977130a9f793fd5244e6325f83c375/.github/workflows/main.yml#L36-L59) owns deployment.
- **S5:** Local macOS preferences, `dev.adrian.ishare` → `savedCustomUploaders`, inspected with `defaults`. This is a preferences record, so there is no source line number. No credential value is retained here.
- **S6:** `~/Development/klik/.agents/skills/upload-file/references/clients.md:9–24` (ShareX), `30–44` (iShare); `SKILL.md:27–34` (keys, content type, deletion credential).
- **S7:** `~/Development/klik/.agents/skills/upload-file/scripts/upload.sh:38–51` (auth/errors), `56–61` (delete), `82–100` (filename, binary upload, URL extraction).
- **S8:** [`test/delete.test.ts:20–51`](https://github.com/mia-riezebos/ShareX-R2-Cloudflare-Workers/blob/35cd029ea7977130a9f793fd5244e6325f83c375/test/delete.test.ts#L20-L51), authenticated deletion and retrieval after deletion.
- **S9:** [Cloudflare Workers limits](https://developers.cloudflare.com/workers/platform/limits/#request-and-response-limits), “Request and response limits” and “Memory”, checked 2026-10-07.
- **S10:** [Cloudflare R2 limits](https://developers.cloudflare.com/r2/platform/limits/), limits table and footnotes, checked 2026-10-07. The page has inconsistent multipart footnote wording; its table reports 4.995 TiB total.
- **S11:** [Cloudflare R2 multipart API from Workers](https://developers.cloudflare.com/r2/api/workers/workers-multipart-usage/), create/part/complete/abort example, checked 2026-10-07.

Caelestis was a usage lead, not server source. `~/Development/mia-riezebos/Caelestis/docs/raid-backend-performance-2026-09-20.md:165` links a public gzip artifact; `docs/raid-performance-2026-09-19.md:194` links PNGs. Neither establishes video acceptance or upload size limits.
