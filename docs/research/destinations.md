# Built-in Destination types: APIs, auth, links, and limits

Researched 2026-10-14. Resolves mia-cx/wadjet#16. No API calls were made with credentials and no applications were registered; findings come from primary documentation, specs, and first-party SDK sources.

## Short answer

Every candidate Destination can accept a wadjet upload, but they split into three groups:

- **OAuth-managed clouds** (Google Drive, Dropbox, OneDrive): resumable upload APIs, share-link APIs, and OAuth registration. Google is the heaviest: a `drive.file` app that stays in "Testing" publishing status loses its refresh token after 7 days.
- **Key-or-password stores** (S3-compatible, WebDAV, FTP/SFTP, B2 native): no OAuth, simple credential setup. S3-compatible and B2 give presigned URLs (max 7 days) or public buckets; plain WebDAV, FTP, and SFTP have no public-link concept and need a user-supplied public URL prefix.
- **File hosts** (Imgur, Catbox, 0x0.st, Pixeldrain, and similar): trivial anonymous POST APIs. Imgur is effectively closed to new API applications as of late 2025 into 2026; the registration endpoint redirects to imgur.com.

Per-type comparison:

| Destination | Upload path | Auth and registration burden | Public link | Delete | Hard limits | Swift package |
| --- | --- | --- | --- | --- | --- | --- |
| Google Drive | Resumable `uploadType=resumable` above 5 MB; `files.create` accepts up to 5,120 GB | OAuth client in Google Cloud; `drive.file` scope; "Testing" status expires refresh tokens in 7 days | `permissions.create` `type=anyone`, then `webViewLink` / `webContentLink` | `files.delete` | 5 TB per file, 750 GB/day per user, 325,000 quota units/min/user | GoogleSignIn-iOS for auth; REST calls hand-rolled over URLSession |
| Dropbox | `files/upload` to 150 MB; `upload_session/start+append_v2+finish` above | App Console app, free; OAuth with PKCE; `token_access_type=offline` gives a refresh token | `sharing/create_shared_link_with_settings`; rewrite `dl=0` to `raw=1` for direct bytes | `files/delete_v2` | Upload-session file size bounded by account storage; rate limits returned as 429, not published | SwiftyDropbox 10.2.4, Dropbox, MIT, macOS 10.13+ |
| OneDrive | Simple PUT below 4 MB; `createUploadSession` above, slices a multiple of 320 KiB | Entra app registration, free; MSAL public client; `Files.ReadWrite` | `createLink` `type=view`, `scope=anonymous` (admin can disable in business tenants) | `DELETE /me/drive/items/{id}` | 250 GB per file | MSAL for auth; msgraph-sdk-swift exists but is Kiota-generated and immature; hand-rolling is reasonable |
| Imgur | `POST /3/image` or `/3/upload`, multipart | **New app registration appears closed**: `api.imgur.com/oauth2/addclient` redirects to imgur.com (verified by multiple third-party reports through early 2026; registration not retested directly) | Response `link` field is directly public | `DELETE /3/image/{deletehash}` | 50 MB stills, 200 MB video (max 180 s), ~1,250 uploads/day per client | None needed; plain multipart POST |
| Catbox | `POST /user/api.php`, multipart `reqtype=fileupload` | Anonymous or account `userhash`; no OAuth | Response body is the public URL | `reqtype=deletefiles` with userhash (account files only) | 200 MB per file | None needed |
| WebDAV | `PUT` raw body; Nextcloud chunking API for large files (5 MB to 5 GB chunks) | Basic auth or app password; no registration | None in the protocol. Nextcloud OCS Share API can create public links (shareType 3). Otherwise user supplies a public URL prefix | `DELETE` | Server-defined; no protocol cap | None mature; URLSession covers PUT/DELETE/PROPFIND |
| S3 and S3-compatible (R2, B2, MinIO) | Single `PUT` to 5 GiB; multipart to ~5 TiB (parts 5 MiB to 5 GiB, max 10,000) | Access key + secret; no registration beyond provider account | Presigned GET, max 7 days (SigV4); permanent link needs public bucket policy or CDN/custom domain | `DELETE Object` | S3: 5 GiB single PUT, 48.8 TiB object. R2: 5 GiB single PUT, ~5 TiB multipart. B2 native: 5 GB single file, 10 TB large file | aws-sdk-swift (awslabs, Apache-2.0, macOS); endpoint override works for S3-compatible |
| FTP / FTPS | `STOR` over TCP (TLS for FTPS) | Username/password | None; user supplies a public URL prefix | `DELE` | Server-defined | None. URLSession FTP is download-only and deprecated; implement over Network.framework or embed libcurl |
| SFTP | SFTP write packets over SSH | Password or key | None; user supplies a public URL prefix | SFTP remove | Server-defined | Citadel (orlandos-nl, MIT) on apple/swift-nio-ssh; requires SwiftNIO |

## Google Drive

### Upload

`files.create` supports three modes: simple (`uploadType=media`) and multipart for files of 5 MB or less, and resumable (`uploadType=resumable`) for larger files or unreliable networks. Resumable upload starts a session with metadata, then sends the body with `PUT` requests to the session URI; the protocol supports querying progress and resuming after interruption. `files.create` accepts media up to 5,120 GB. Sources: [manage-uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads), [files.create](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/create).

### Auth and registration

Requires a Google Cloud project, an OAuth client of type "Desktop app" (or the custom-scheme/loopback variants described in the native-app guide), and an OAuth consent screen. `drive.file` is the least-privileged scope that both uploads files and creates permissions on them; it is a per-file scope covering files the app created or the user picked. `permissions.create` accepts `drive` or `drive.file`. Sources: [api-specific-auth](https://developers.google.com/workspace/drive/api/guides/api-specific-auth), [permissions.create](https://developers.google.com/workspace/drive/api/reference/rest/v3/permissions/create), [native-app](https://developers.google.com/identity/protocols/oauth2/native-app).

Two product-relevant caveats:

- A project with an external consent screen left in "Testing" publishing status gets refresh tokens that expire in 7 days. Moving the consent screen to "In production" removes the expiry; an unverified production app still shows an "unverified app" warning and a 100-user cap, which is fine for a single-user tool. Source: [oauth2#expiration](https://developers.google.com/identity/protocols/oauth2#expiration).
- Full OAuth verification (with a security assessment) is only required for public apps requesting sensitive or restricted scopes at scale. Cost is zero for registration and testing; verification is process burden, not money.

### Public link

Drive has no expiring presigned URL. Create a permission of `type=anyone`, `role=reader`, then return `webViewLink` (a Drive preview page) or `webContentLink` (direct download for non-Google formats). The link is a constant URL derived from `fileId`, not per-recipient. Source: [manage-sharing](https://developers.google.com/workspace/drive/api/guides/manage-sharing).

### Deletion

`DELETE /drive/v3/files/{fileId}` via `files.delete`, or set `trashed=true`. Same scope as upload. Source: [files.delete](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/delete).

### Limits

5 TB max file size; 750 GB per user per day across My Drive and shared drives; quota at 325,000 units per minute per user per project (a `files.update` costs 50 units). Source: [limits](https://developers.google.com/workspace/drive/api/guides/limits).

### Swift

There is no first-party Swift client for the Drive REST API. Use `GoogleSignIn-iOS` (google, Apache-2.0; supports macOS, uses AppAuth under the hood) or `GTMAppAuth` (google, Apache-2.0, macOS 12+) for tokens, then hand-roll the resumable upload over URLSession. Sources: [GoogleSignIn-iOS](https://github.com/google/GoogleSignIn-iOS), [GTMAppAuth](https://github.com/google/GTMAppAuth).

## Dropbox

### Upload

`POST /2/files/upload` accepts one request up to 150 MB. Above that, use upload sessions: `upload_session/start`, `upload_session/append_v2`, `upload_session/finish`. Each request piece can be up to 150 MB; Dropbox staff recommend smaller chunks such as 8 MB. Pieces may be sent with start, appended in order, and finished with the total offset, which gives resumability. Sources: [HTTP documentation](https://www.dropbox.com/developers/documentation/http/documentation), [upload sessions discussion](https://community.dropbox.com/en/discussion/389687/api-v2-upload-file-size-above-300mb).

### Auth and registration

A free app in the Dropbox App Console yields an app key. The OAuth flow supports PKCE for public clients. Requesting `token_access_type=offline` returns a short-lived access token plus a refresh token; refresh tokens persist until the user or app revokes them (long-lived "legacy" access tokens were deprecated in 2021). Least-privilege scopes: `files.content.write` for upload and delete, `sharing.write` for shared links. Sources: [oauth guide discussion](https://community.dropbox.com/en/discussion/535064/help-understanding-token-access-type-offline), [PKCE discussion](https://community.dropbox.com/en/discussion/508280/java-sdk-issues-with-short-lived-token), [HTTP documentation](https://www.dropbox.com/developers/documentation/http/documentation).

### Public link

`POST /2/sharing/create_shared_link_with_settings` returns a `url` ending `dl=0` (a Dropbox preview page). Rewrite to `raw=1` for the raw file bytes suitable for direct embedding. Links can carry `expires` and `requested_visibility=public` settings. Source: [HTTP documentation, sharing](https://www.dropbox.com/developers/documentation/http/documentation).

### Deletion

`POST /2/files/delete_v2` with the file path. Source: [HTTP documentation](https://www.dropbox.com/developers/documentation/http/documentation).

### Limits

Dropbox does not publish a fixed per-file API ceiling above the 150 MB single-request limit; upload sessions accept files bounded by account storage. Rate limiting is adaptive and signalled with 429; no fixed numbers are published. Sources: [HTTP documentation](https://www.dropbox.com/developers/documentation/http/documentation), [upload session discussion](https://community.dropbox.com/en/discussion/389687/api-v2-upload-file-size-above-300mb). A ~1 GB recording is well within session-upload capability.

### Swift

`SwiftyDropbox` (dropbox, MIT): official SDK, current release 10.2.4 (December 2025), iOS 12+/macOS 10.13+, SPM supported, includes the OAuth flow and upload-session plumbing. Sources: [SwiftyDropbox releases](https://github.com/dropbox/SwiftyDropbox/releases), [LICENSE](https://github.com/dropbox/SwiftyDropbox/blob/master/LICENSE).

## OneDrive (personal and business)

### Upload

`PUT /me/drive/items/{parentId}:/{filename}:/content` for items under 4 MB. Above that, `POST ...:/createUploadSession` returns a preauthenticated `uploadUrl`; upload fragments sequentially with `Content-Range`, each a multiple of 320 KiB (about 4 MB is a reasonable fragment size). The session is resumable: `GET` the `uploadUrl` for `nextExpectedRanges`. Sources: [upload concepts](https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/upload?view=odsp-graph-online), [createUploadSession](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0), [large file upload](https://learn.microsoft.com/en-us/graph/sdks/large-file-upload).

Multipart upload and upload-from-URL exist for OneDrive Personal only; not relevant at ~1 GB.

### Auth and registration

Register a free app in Microsoft Entra (Azure portal) as a public client with a mobile/desktop redirect URI. On macOS, use MSAL (`MSALPublicClientApplication`) or hand-roll authorization-code + PKCE against `login.microsoftonline.com/common`, which covers both personal Microsoft accounts and work/school tenants. Least-privilege delegated scope for upload, link creation, and delete is `Files.ReadWrite`. Sources: [MSAL quickstart](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-v2-ios), [createLink permissions](https://learn.microsoft.com/en-us/graph/api/driveitem-createlink?view=graph-rest-1.0).

No verification program or cost for an unpublished single-tenant app.

### Public link

`POST /drive/items/{id}/createLink` with `type: "view"`, `scope: "anonymous"` returns a sharing URL that works without sign-in. Personal accounts can also set `password` and `expirationDateTime`. In OneDrive for Business, anonymous links can be disabled by tenant administrators, so wadjet should surface the resulting error rather than assume availability. Sources: [createLink](https://learn.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_createlink?view=odsp-graph-online), [sharing concepts](https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/sharing?view=odsp-graph-online).

### Deletion

`DELETE /me/drive/items/{id}` moves the item to the recycle bin. Source: [driveItem delete](https://learn.microsoft.com/en-us/graph/api/driveitem-delete?view=graph-rest-1.0).

### Limits

250 GB per file for upload and download on both personal and business. Throttling returns 429/503 with `Retry-After`. Sources: [restrictions and limitations](https://support.microsoft.com/en-us/onedrive/restrictions-and-limitations-in-onedrive-and-sharepoint), [throttling](https://learn.microsoft.com/en-us/graph/throttling).

### Swift

MSAL (`AzureAD/microsoft-authentication-library-for-objc`, MIT) supports iOS and macOS and is the maintained auth path. `msgraph-sdk-swift` exists but is a Kiota-generated SDK with limited maturity; for three endpoints (upload session, createLink, delete), hand-rolling over URLSession with an MSAL-issued token is simpler. Sources: [MSAL repo](https://github.com/AzureAD/microsoft-authentication-library-for-objc), [msgraph-sdk-swift](https://github.com/microsoftgraph/msgraph-sdk-swift).

## Imgur

### Upload

`POST https://api.imgur.com/3/image` (or `/3/upload`) with `image` or `video` as binary, base64, or URL. Anonymous uploads need only `Authorization: Client-ID {client_id}`; account-bound uploads use OAuth Bearer. The JSON response carries `link` and `deletehash`. Source: [apidocs.imgur.com](https://apidocs.imgur.com/).

### Auth and registration: important caveat

The docs still describe registering at `api.imgur.com/oauth2/addclient`, but that endpoint now redirects to imgur.com, and OAuth authorization URLs fail for many apps. Multiple independent projects (ShareX issue #8014, obsidian-imgur-plugin issue #106, Tautulli issue #2620, Stack Overflow) report registration and OAuth broken from mid-2025 through early 2026. I did not create an account to retest; treat Imgur as unavailable for new integrations until re-verified manually. If a working client_id already exists, anonymous upload with just the Client-ID header still appears to function. Sources: [obsidian-imgur-plugin#106](https://github.com/gavvvr/obsidian-imgur-plugin/issues/106), [Tautulli#2620](https://github.com/Tautulli/Tautulli/issues/2620), [Stack Overflow](https://stackoverflow.com/questions/79891087/unable-to-to-register-as-new-client-for-api-redirects-back-to-imgur-com), [apidocs](https://apidocs.imgur.com/).

### Public link

The `link` field is directly public; no share-step needed.

### Deletion

`DELETE /3/image/{deletehash}`. The deletehash is returned at upload time and is the deletion credential; anonymous images can only be deleted by deletehash. Source: [apidocs.imgur.com](https://apidocs.imgur.com/).

### Limits

Still images 50 MB (PNG over 5 MB is converted to JPEG; wadjet should warn or pick another destination for pixel-perfect PNGs). Animated/video 200 MB, max 180 seconds. API credit system: roughly 1,250 uploads and 12,500 requests per day per client; uploads cost 10 credits. Commercial use requires RapidAPI registration with paid tiers. Sources: [Imgur help, size limits](https://help.imgur.com/hc/en-us/articles/26511665959579-What-files-can-I-upload-Is-there-a-size-limit), [apidocs rate limits](https://apidocs.imgur.com/), [RapidAPI pricing](https://rapidapi.com/imgur/api/Imgur/pricing).

### Swift

None needed; the API is a single multipart POST over URLSession.

## Other screenshot hosts worth supporting natively

These all use a bare multipart POST and return a URL in the body. No OAuth, no registration for anonymous use. That makes them cheap Destination types to implement with the same code path.

- **Catbox** (`catbox.moe/user/api.php`): `reqtype=fileupload`, optional `userhash`, field `fileToUpload`. 200 MB per file; permanent storage; account uploads deletable via `reqtype=deletefiles`. Source: [catbox.moe/tools.php](https://catbox.moe/tools.php).
- **Litterbox** (Catbox temporary variant): `time=1h|12h|24h|72h`, all anonymous, up to 1 GB; files expire. Source: [litterbox.catbox.moe/tools.php](https://litterbox.catbox.moe/tools.php).
- **0x0.st**: multipart `file` field to `https://0x0.st`. 512 MiB max; retention scales with size from 30 days to 1 year. Source: [0x0.st](https://0x0.st/).
- **Pixeldrain**: `POST https://pixeldrain.com/api/file`, anonymous uploads up to a multi-GB range; returns an ID usable as `https://pixeldrain.com/u/{id}`. Source: [pixeldrain API docs](https://pixeldrain.com/api).
- **transfer.sh, file.io, GoFile, FileDitch**: similar single-POST hosts with varying retention and reliability; worth listing as generic "custom POST uploader" targets rather than bespoke integrations. Retention and limits per site docs; verify individually before listing in the UI.

A generic "custom uploader" Destination (endpoint + form field + regex on the response) already covers most of these, matching how ShareX handles long-tail hosts.

## WebDAV

### Upload

Plain `PUT` of the raw body to the resource URL; `DELETE` removes it. There is no resumable-upload standard in RFC 4918. Nextcloud defines a chunked upload extension: `MKCOL` an upload folder under `/remote.php/dav/uploads/{user}`, `PUT` numbered chunks of 5 MB to 5 GB (last may be smaller), then `MOVE` to assemble; `OC-Total-Length` enables quota checking. Sources: [Nextcloud WebDAV basic](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/WebDAV/basic.html), [Nextcloud chunking](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/WebDAV/chunking.html), [RFC 4918](https://www.rfc-editor.org/rfc/rfc4918).

### Auth

Basic auth or per-app passwords (Nextcloud app passwords, ownCloud tokens). No OAuth in the protocol; some servers front WebDAV with bearer auth. No registration burden.

### Public link

WebDAV itself has no share-link concept. Two options: let the user supply a public URL prefix that maps to the WebDAV path (the common ShareX model), or support the Nextcloud OCS Share API (`POST /ocs/v2.php/apps/files_sharing/api/v1/shares`, `shareType=3` creates a public link). OCS is Nextcloud-specific, not generic WebDAV. Source: [OCS share API](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/OCS/ocs-share-api.html).

### Limits

None in the protocol; server-defined. Nextcloud chunk bounds are 5 MB to 5 GB per chunk, chunk names 1 to 10000.

### Swift

No mature Swift WebDAV client worth depending on. `PUT`, `DELETE`, `MKCOL`, `MOVE`, and `PROPFIND` all work over URLSession with a custom `httpMethod`; implement just those.

## S3 and S3-compatible (AWS S3, Cloudflare R2, Backblaze B2, MinIO)

### Upload

Single `PUT Object` up to 5 GiB. Multipart upload (`CreateMultipartUpload`, `UploadPart`, `CompleteMultipartUpload`, `AbortMultipartUpload`) supports parts of 5 MiB to 5 GiB, up to 10,000 parts and a 48.8 TiB object on AWS; parts upload in parallel and failed parts retry independently, giving resumability. AWS recommends multipart at 100 MB and up. Sources: [multipart overview](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html), [multipart limits](https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html).

### Auth

Static access key ID + secret, SigV4 request signing. No OAuth or app registration; credentials come from the provider console (IAM user for AWS, API token for R2, application key for B2, user for MinIO). Cost is the provider's storage pricing.

### Public link

Two models:

- **Presigned GET URL**: anyone with the URL can download until it expires. SigV4 caps expiry at 7 days (604,800 seconds) on AWS, R2, and MinIO. B2's equivalent is `b2_get_download_authorization` or S3 presigning against its S3-compatible endpoint. Sources: [S3 presigned](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html), [SigV4 query auth](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sigv4-query-string-auth.html), [R2 presigned](https://developers.cloudflare.com/r2/api/s3/presigned-urls), [MinIO presigned](https://github.com/minio/minio-js/blob/master/docs/API.md).
- **Permanent public URL**: requires making the bucket public. R2 exposes `r2.dev` development subdomains (rate-limited, not for production) or custom domains on a Cloudflare-managed zone. B2 public buckets serve `https://fXXX.backblazeb2.com/file/{bucket}/{key}`; a CDN front is recommended. MinIO needs an anonymous-read bucket policy, then `https://{host}/{bucket}/{key}` works. Sources: [R2 public buckets](https://developers.cloudflare.com/r2/buckets/public-buckets/), [B2 download by name](https://www.backblaze.com/docs/cloud-storage-download-files-with-the-native-api), [MinIO issue on permanent share](https://github.com/minio/minio/issues/5180).

For wadjet the natural model is a public bucket or custom domain for permanent links, since presigned links die in a week.

### Deletion

`DELETE Object` (S3 API) or `b2_delete_file_version` on the B2 native API.

### Limits

| Provider | Single PUT | Multipart | Max object | Notes |
| --- | --- | --- | --- | --- |
| AWS S3 | 5 GiB | 5 MiB to 5 GiB x 10,000 | 48.8 TiB | [qfacts](https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html) |
| Cloudflare R2 | 5 GiB | same shape | ~5 TiB | [R2 limits](https://developers.cloudflare.com/r2/platform/limits/) |
| Backblaze B2 (native) | 5 GB (`b2_upload_file`) | 5 MB to 5 GB parts | 10 TB | [B2 large files](https://www.backblaze.com/docs/cloud-storage-large-files) |
| MinIO | 5 GiB | S3-compatible | deployment-defined | S3 API semantics |

B2 native upload requires `Content-Length` (no chunked transfer encoding) and a per-thread `b2_get_upload_url` / `b2_get_upload_part_url`. Source: [B2 upload](https://www.backblaze.com/docs/cloud-storage-upload-files-with-the-native-api).

### Swift

`aws-sdk-swift` (awslabs, Apache-2.0) is GA, supports macOS and all Apple platforms, and covers S3 including multipart and presigning; a custom `endpoint` on `S3ClientConfiguration` works for S3-compatible services (R2, B2's S3 endpoint, MinIO over HTTPS; plain-HTTP MinIO endpoints are not supported by the SDK). Hand-rolling SigV4 over URLSession is feasible but signing edge cases favour the SDK. Sources: [aws-sdk-swift](https://github.com/awslabs/aws-sdk-swift), [custom endpoint discussion](https://github.com/awslabs/aws-sdk-swift/discussions/1023), [SDK dev guide](https://docs.aws.amazon.com/sdk-for-swift/latest/developer-guide/home.html).

## FTP, FTPS, SFTP

### Upload

FTP/FTPS uses `STOR` on a data channel negotiated by `PASV`/`EPSV`; FTPS wraps control and data in TLS. SFTP writes with `SSH_FXP_WRITE` packets over an SSH channel. All are stream-sequential protocols; resumability is manual via `REST` (FTP) or offset writes (SFTP).

### Auth

Username/password; SFTP also takes SSH keys. No registration.

### Public link

None in any of these protocols. The Destination needs a user-supplied public URL prefix composed with the remote path, exactly as ShareX treats FTP.

### Deletion

`DELE` for FTP; `SSH_FXP_REMOVE` for SFTP.

### Limits

No protocol limits; server disk quota binds.

### Swift

Apple has removed viable FTP client support: `URLSession` FTP was download-only, deprecated in the 2022 SDKs, and dropped entirely from the new Network.framework HTTP stack; `CFFTPStream` has been deprecated since macOS 10.11. Realistic options: implement `STOR`/`PASV` over `NWConnection` (FTPS adds `NWParameters` TLS), or bridge libcurl, which supports FTP/S, FTPS, and SFTP in one API. Sources: [Apple dev forums, On FTP](https://origin-devforums.apple.com/forums/thread/97469), [URLSession FTP discussion](https://developer.apple.com/forums/thread/6152), [new HTTP loader pitch](https://forums.swift.org/t/pitch-new-http-loader-for-urlsession-on-darwin/77440).

For SFTP, `Citadel` (orlandos-nl, MIT) provides `SFTPClient` with openFile/write/pipelined writes, built on `apple/swift-nio-ssh` (Apache-2.0). It requires SwiftNIO, which is a heavy but standard dependency; there is no Apple-native SFTP API. Sources: [Citadel SFTPClient](https://github.com/orlandos-nl/Citadel/blob/main/Sources/Citadel/SFTP/Client/SFTPClient.swift), [swift-nio-ssh](https://github.com/apple/swift-nio-ssh/blob/main/README.md), [Apple forums SFTP answer](https://developer.apple.com/forums/thread/729346).

## OAuth 2.0 for a native macOS app against a self-hosted IdP

### Flow

Authorization Code + PKCE, per RFC 8252 (OAuth for Native Apps) and RFC 7636 (PKCE). The app must use the system browser, never an embedded web view. On macOS, `ASWebAuthenticationSession` opens the user's default browser (or Safari) and delivers the callback URL back to the calling session only, even if another app registers the same scheme. Sources: [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252.html), [ASWebAuthenticationSession](https://developer.apple.com/documentation/AuthenticationServices/ASWebAuthenticationSession), [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636).

### Redirect URI choice

RFC 8252 defines three options: private-use URI scheme (reverse-domain, e.g. `cx.mia.wadjet:/oauth`), loopback `http://127.0.0.1:{port}` with an ephemeral listener, and claimed `https` URLs (not applicable to a self-hosted IdP without a domain). Practical guidance:

- Custom scheme works with `ASWebAuthenticationSession`'s `callbackURLScheme` and needs no port management; the scheme must be based on a controlled domain in reverse order.
- Loopback is what many desktop apps (ownCloud, gcloud) use, but requires the IdP to accept dynamic ports. Some IdPs allow a `Regex` redirect entry (authentik does, e.g. `http://127.0.0.1(:[0-9]+)?(/.*)?`); others require strict matching, which forces a fixed port.
- Google is deprecating loopback for mobile OAuth client types but keeps it for desktop clients, and OAuth 2.1 draft discussion keeps loopback preferred over unclaimed schemes. For a self-hosted IdP both work; prefer custom scheme for simplicity unless the IdP restricts it. Sources: [RFC 8252 §7](https://www.rfc-editor.org/rfc/rfc8252.html), [authentik ownCloud integration](https://integrations.goauthentik.io/chat-communication-collaboration/owncloud/), [Google loopback migration](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration), [oauth-v2-1 issue 179](https://github.com/oauth-wg/oauth-v2-1/issues/179).

### Discovery

OIDC providers expose `/.well-known/openid-configuration` (issuer metadata endpoint), which gives authorization, token, and JWKS endpoints, so wadjet only needs the issuer URL. Authentik exposes discovery per application at `https://{host}/application/o/{slug}/.well-known/openid-configuration` and supports PKCE public clients. Register a public (no-secret) client with `offline_access` if refresh tokens are wanted. Sources: [authentik integrations](https://integrations.goauthentik.io/), [OpenID Connect Discovery](https://openid.net/specs/openid-connect-discovery-1_0.html).

### Token storage

Store refresh tokens in the Keychain as `kSecClassGenericPassword` items, not in UserDefaults or files. `ASWebAuthenticationSession.prefersEphemeralWebBrowserSession` exists for flows that should not reuse browser cookies.

### Libraries

`AppAuth-iOS` (openid, Apache-2.0) is the canonical native-app OAuth client, actively maintained (3.x supports macOS 12+, uses ASWebAuthenticationSession, performs the token exchange with PKCE automatically). `GTMAppAuth` (google, Apache-2.0) adds Google-flavoured session persistence. Given that wadjet targets macOS 26 and only needs code+PKCE against one configurable IdP, hand-rolling with `ASWebAuthenticationSession` plus a token endpoint is also small; AppAuth buys OIDC discovery and edge-case handling for free. Sources: [AppAuth-iOS releases](https://github.com/openid/AppAuth-iOS/releases), [GTMAppAuth](https://github.com/google/GTMAppAuth).

## Sources

- Google Drive: [manage-uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads) · [files.create](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/create) · [api-specific-auth](https://developers.google.com/workspace/drive/api/guides/api-specific-auth) · [permissions.create](https://developers.google.com/workspace/drive/api/reference/rest/v3/permissions/create) · [manage-sharing](https://developers.google.com/workspace/drive/api/guides/manage-sharing) · [files.delete](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/delete) · [limits](https://developers.google.com/workspace/drive/api/guides/limits) · [native-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app) · [refresh token expiration](https://developers.google.com/identity/protocols/oauth2#expiration)
- Dropbox: [HTTP API documentation](https://www.dropbox.com/developers/documentation/http/documentation) · [upload sessions](https://community.dropbox.com/en/discussion/389687/api-v2-upload-file-size-above-300mb) · [offline tokens](https://community.dropbox.com/en/discussion/535064/help-understanding-token-access-type-offline) · [PKCE](https://community.dropbox.com/en/discussion/508280/java-sdk-issues-with-short-lived-token) · [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox)
- OneDrive: [upload concepts](https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/upload?view=odsp-graph-online) · [createUploadSession](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0) · [createLink](https://learn.microsoft.com/en-us/graph/api/driveitem-createlink?view=graph-rest-1.0) · [sharing concepts](https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/sharing?view=odsp-graph-online) · [file limits](https://support.microsoft.com/en-us/onedrive/restrictions-and-limitations-in-onedrive-and-sharepoint) · [MSAL quickstart](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-v2-ios) · [MSAL repo](https://github.com/AzureAD/microsoft-authentication-library-for-objc)
- Imgur: [apidocs.imgur.com](https://apidocs.imgur.com/) · [size limits help](https://help.imgur.com/hc/en-us/articles/26511665959579-What-files-can-I-upload-Is-there-a-size-limit) · [RapidAPI pricing](https://rapidapi.com/imgur/api/Imgur/pricing) · [registration breakage: obsidian-imgur-plugin#106](https://github.com/gavvvr/obsidian-imgur-plugin/issues/106) · [Tautulli#2620](https://github.com/Tautulli/Tautulli/issues/2620)
- Other hosts: [Catbox API](https://catbox.moe/tools.php) · [Litterbox API](https://litterbox.catbox.moe/tools.php) · [0x0.st](https://0x0.st/) · [Pixeldrain API](https://pixeldrain.com/api)
- WebDAV: [RFC 4918](https://www.rfc-editor.org/rfc/rfc4918) · [Nextcloud WebDAV basic](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/WebDAV/basic.html) · [Nextcloud chunking](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/WebDAV/chunking.html) · [Nextcloud OCS share API](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/OCS/ocs-share-api.html)
- S3 family: [S3 presigned URLs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html) · [SigV4 query auth](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sigv4-query-string-auth.html) · [S3 multipart limits](https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html) · [S3 multipart overview](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html) · [R2 public buckets](https://developers.cloudflare.com/r2/buckets/public-buckets/) · [R2 presigned](https://developers.cloudflare.com/r2/api/s3/presigned-urls) · [R2 limits](https://developers.cloudflare.com/r2/platform/limits/) · [R2 uploads](https://developers.cloudflare.com/r2/objects/upload-objects/) · [B2 upload](https://www.backblaze.com/docs/cloud-storage-upload-files-with-the-native-api) · [B2 large files](https://www.backblaze.com/docs/cloud-storage-large-files) · [B2 download by name](https://www.backblaze.com/docs/cloud-storage-download-files-with-the-native-api) · [MinIO presigned](https://github.com/minio/minio-js/blob/master/docs/API.md) · [aws-sdk-swift](https://github.com/awslabs/aws-sdk-swift)
- FTP/SFTP: [Apple forums, On FTP](https://origin-devforums.apple.com/forums/thread/97469) · [URLSession FTP](https://developer.apple.com/forums/thread/6152) · [URLSession new HTTP loader](https://forums.swift.org/t/pitch-new-http-loader-for-urlsession-on-darwin/77440) · [Citadel](https://github.com/orlandos-nl/Citadel) · [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) · [Apple forums SFTP](https://developer.apple.com/forums/thread/729346)
- Native OAuth: [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252.html) · [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636) · [ASWebAuthenticationSession](https://developer.apple.com/documentation/AuthenticationServices/ASWebAuthenticationSession) · [OIDC Discovery](https://openid.net/specs/openid-connect-discovery-1_0.html) · [authentik integrations](https://integrations.goauthentik.io/) · [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) · [GTMAppAuth](https://github.com/google/GTMAppAuth) · [GoogleSignIn-iOS](https://github.com/google/GoogleSignIn-iOS)
