# ShareX custom Destination format

Research for [#4](https://github.com/mia-cx/wadjet/issues/4), checked 2026-10-07.

## Short answer and recommended v1

`.sxcu` is a JSON object describing an HTTP request and response templates. It is not a Workflow definition. `Version` identifies the exporting ShareX application, not a separately versioned schema. ShareX exports its application version through `CustomUploaderItem.Init()`. The current schema includes `Data`, which the documentation's example omits. [Schema source][item]

Mia's saved iShare Destination uses a different JSON dialect. Convert its binary POST to `https://i.mia.cx/upload`, preserve its `x-auth-key` privately, and translate `{{image}}` to `{json:image}`. Preserve `{{deleteUrl}}` as `{json:deleteUrl}`. Also preserve iShare's implicit `x-file-name` header and MIME content type. This conclusion combines the local defaults observation with [iShare's model][imodel] and [request implementation][ihttp]. No upload or deletion request was sent.

Recommended product scope, rather than a claim of full ShareX compatibility:

1. Import ShareX 12.4+ objects and iShare objects into one Destination model. Keep format/version information for diagnostics. Handle omitted optional properties without requiring a complete exported object. [ShareX model][item], [iShare model][imodel]
2. Upload Capture files through `MultipartFormData` and `Binary`. Support POST and PUT first, literal Headers and Parameters, multipart Arguments, FileFormName, and `{filename}` substitution. Recognize GET/PATCH/DELETE at import, but reject execution modes v1 cannot implement. ShareX image/file paths themselves accept only multipart and binary. [File upload][file], [image upload][image]
3. Support URL, ThumbnailURL, DeletionURL and ErrorMessage templates. Include blank URL/raw response, `{response}`, `{responseurl}`, `{header:name}`, JSON object/array paths, and regex first match with numbered/named groups. Support literal URL prefixes/suffixes and escapes. [Response handling][item], [functions][functions]
4. Import the legacy `$…$` equivalents and `RegexList` references. Include `{random:…}` and `{base64:…}` if inexpensive; both appear in actual configs. Reject unsupported expressions explicitly. Defer XPath, interactive select/input/output boxes, arbitrary JSONPath filters, ShareX name patterns, and JSON/XML/form-encoded text requests. [Legacy parser][oldparser], [examples][examples]
5. Provide a separate iShare import adapter. Keep deletion method metadata separate from the ShareX schema. Secret storage, retries, cancellation and deletion execution remain decisions for #9. [iShare model][imodel], [deletion implementation][ihttp]

Evidence for this subset: the first-party [CustomUploaders collection][examples], at commit `efe3d263764ad4b86823f331239f3f3bdc864515`, contains 148 top-level `.sxcu` files. A local JSON inventory found 127 multipart, one binary, ten JSON, one form-encoded, and nine with Body omitted. All Version values are 12.4.x through 13.7.0. There are 140 POST and eight GET configurations. This measures example coverage, not whether those services remain online. [Collection][examples]

Useful import fixtures are [imgbb][imgbb] (query credentials and three JSON outputs), [catbox][catbox] (multipart arguments and blank URL), [binary example][binaryexample] (filename query parameter), and [0x0][zero] (legacy RegexList). These establish required syntax without contacting their services.

## Complete current schema

The source class is the authoritative property inventory. The file is one JSON object, with enum names normally serialized as strings. Optional fields can disappear during export. `ShouldSerialize…` methods omit fields irrelevant to the selected Body. [Model][item], [JSON serializer][serializer]

| Property | JSON type | Meaning and default/omission behavior |
| --- | --- | --- |
| Version | string | Exporting application version. Current ShareX rejects missing versions and versions <=12.3.1 during compatibility checking. |
| Name | string | Display name; absent/empty falls back to RequestURL's host. Export can omit a name equal to that host. |
| DestinationType | enum flags string | `None`, `ImageUploader`, `TextUploader`, `FileUploader`, `URLShortener`, `URLSharingService`; comma-separated combinations are valid. Missing is None. This describes ShareX selection categories. |
| RequestMethod | enum string | `GET`, `POST`, `PUT`, `PATCH`, `DELETE` in the documented contract. Model initializes POST and exports it explicitly. |
| RequestURL | string | Required when constructing a request. Supports expressions and appended query Parameters. |
| Parameters | object of string values | Query parameters, regardless of method. Values support templates. Empty/absent object is omitted. |
| Headers | object of string values | HTTP headers. Values support templates. Empty/absent object is omitted. May contain credentials. |
| Body | enum string | `None`, `MultipartFormData`, `FormURLEncoded`, `JSON`, `XML`, `Binary`. Missing enum value is None; new editor entries explicitly initialize MultipartFormData. |
| Arguments | object of string values | Body fields for multipart or form-encoded requests, not query parameters. Values support templates. Export only retains these for those two Body modes. |
| FileFormName | string | File part's field name for multipart; ShareX requires it for file/image uploads. Export only retains it for multipart. |
| Data | string | Raw JSON/XML body template. Export only retains it for JSON/XML. It is not an object and is not generated from Arguments. |
| URL | string | Main result template. Missing/empty means response body text on HTTP success. |
| ThumbnailURL | string | Optional result template. Missing/empty evaluates to an empty string. |
| DeletionURL | string | Optional result template. Describes an extracted URL, not a deletion request method or credential policy. |
| ErrorMessage | string | Evaluated for an unsuccessful HTTP response. A nonempty result becomes the first uploader error. |

All rows derive from [CustomUploaderItem][item]; enum values derive from [Enums.cs][enums] and [the official format documentation][docs]. The export convention derives from [JsonHelpers][serializer]. Missing and empty values do not imply that a request can execute successfully.

### Body semantics

| Body | Request construction |
| --- | --- |
| None | No request body; Parameters still form the query. |
| MultipartFormData | Multipart text Arguments plus a file part named FileFormName. The file part carries filename and MIME type. |
| FormURLEncoded | Encoded Arguments; `{input}` supplies text or a URL for text/shortener modes. |
| JSON | UTF-8 Data string with `application/json`; substitute and JSON-escape input/filename values. |
| XML | UTF-8 Data string with `application/xml`; substitute and XML-escape input/filename values. |
| Binary | Raw Capture/file bytes for image/file uploads, not base64 and not multipart. Actual file/image upload code chooses MIME type from filename. |

The general Body content-type helper returns `application/octet-stream` for Binary, but image/file execution supplies the file's MIME type. Do not copy the helper's binary default as the only runtime behavior. File/image execution rejects every Body except multipart and binary. Text execution supports all six modes. [Model and Data processing][item], [file execution][file], [image execution][image], [text execution][text]

## Modern expression grammar and evaluation

Current grammar is `{function:parameter|parameter}` or `{function}`. Function names are case-insensitive. Expressions may nest, for example `{base64:{filename}}`. Literal `{`, `}`, `|`, and `\` must be escaped with `\` in template strings. JSON adds another escape layer: a runtime `\{` is written `\\{` in a JSON string. This is a recursive parser, not a global search-and-replace. [Grammar][syntax], [dispatch][dispatch]

Request URL and response URL processing URL-encode `{filename}` and `{input}` substitutions, not the whole template. Query Parameters are subsequently encoded as query fields. Header/Argument/Parameter values also run ShareX's separate name-pattern parser. Imported configurations do not receive permission to read files through that parser in the inspected revision. [Evaluation contexts][item], [dispatch][dispatch]

`Data` is an exception. Current code runs name-pattern processing, then substitutes only `{input}` and `{filename}` with body-specific escaping. It does not run the general recursive response/function parser over JSON/XML Data. The 13.7 parser previously processed dollar syntax in Data using JSON/XML encoding flags. [Current Data][item], [legacy Data][olditem]

| Expression | Behavior |
| --- | --- |
| `{response}` | Entire response body text. |
| `{responseurl}` | Final response URL, including redirects; without redirect, the request URL. |
| `{header:name}` | Response header value, e.g. Location. Distinct from request Headers. |
| `{json:path}` | Parse response JSON; select one token using Newtonsoft JSONPath. Examples `data.link`, `files[0].url`. Source prefixes `$.` unless already present. |
| `{json:input|path}` | Parse explicit text input, which may itself come from a nested expression. |
| `{xml:xpath}` | Parse response XML, return first selected node's value using XPath. |
| `{xml:input|xpath}` | Same, with explicit text input. |
| `{regex:pattern}` | First .NET regex match from the response body, entire match. |
| `{regex:pattern|group}` | First match's numbered or named group. |
| `{regex:input|pattern|group}` | Same, with explicit input. Two arguments mean pattern/group, never input/pattern. |
| `{input}` | Input text for text upload, or input URL for shortener/sharing modes. Capture binary bytes are not substituted here. |
| `{filename}` | File's name, with context-dependent escaping described above. |
| `{random:a|b|c}` | Choose one supplied string; does not generate a random filename or length of characters. |
| `{select:a|b|c}` | Show a choice dialog; discard empty choices. |
| `{inputbox}` / `{inputbox:title}` / `{inputbox:title|default}` | Show an input dialog. `{prompt:…}` is an alias in current code. |
| `{outputbox:text}` / `{outputbox:title|text}` | Display an output dialog; function returns no URL value. |
| `{base64:text}` | Encode text as base64, e.g. a Basic authentication value. |

The table derives from the individual [function implementations][functions]. JSON uses [SelectToken][json], XML uses [SelectSingleNode][xml], and regex uses [Regex.Match][regex]. The official [documentation][docs] provides examples. Response functions need response context; evaluating them before a response is available is not meaningful. Current dispatch rejects unknown functions, whereas the legacy parser could return nothing. [Dispatch][dispatch], [legacy parser][oldparser]

`URL`, `ThumbnailURL`, and `DeletionURL` evaluate on HTTP success. `ErrorMessage` evaluates on HTTP failure. A server returning an error object with HTTP 200 will not automatically trigger ErrorMessage evaluation. Missing JSON tokens and unmatched regexes can produce empty results; malformed JSON can throw and become an uploader parsing error. These are material behaviors for #9. [Response handling][item], [JSON function][json], [regex function][regex]

## Versions and legacy syntax

Treat these as application-version compatibility eras. Some boundary values name development versions, so use semantic version comparisons, not only published release tags. [Compatibility check][item]

| Era | Schema and parser |
| --- | --- |
| Before 12.3 | Historical implicit regex expressions such as `$1,1$`; ShareX 12.3 removed those in favor of explicit regex syntax. |
| 12.3.1 and older | No Version or Body/Parameters/Data in the inspected class. `RequestType` selects the method. Includes `ResponseType`, `RegexList`, Arguments, Headers, FileFormName and the three result URL templates. |
| 12.4 through 13.7.1 | Version, RequestMethod, Parameters, Body, Data, ErrorMessage introduced in the newer schema. `$response$`, `$json:path$`, `$xml:xpath$`, `$filename$`, `$input$`, `$random:a|b$`, `$base64:text$`, `$select:…$`, `$prompt:…$`; regex indexes reference RegexList. |
| 14.0 era onward | Recursive `{…}` syntax; RegexList removed and regex pattern supplied inline. Current importer migrates dollar syntax for Version <=13.7.1. |
| 14.1 onward | Explicit-input overloads for JSON/XML/regex added. |
| Current inspected source | Missing Version or <=12.3.1 rejected; limited dollar migration retained. Older `RequestType`, `ResponseType`, and RegexList properties are absent. |

Sources: [12.3.1 model][ancientitem], [13.7 model][olditem], [13.7 parser][oldparser], [current compatibility method][item], and [release notes][changelog]. The release notes describe the public 12.4, 14.0 and 14.1 changes and removal of pre-12.4 import compatibility.

Legacy regex is the main migration trap. `$regex:1$` means RegexList's first pattern, not the literal pattern `1`. `$regex:1|1$` selects that pattern's group 1. `$regex:1|name$` selects a named group. The legacy implementation also accepts a comma, e.g. `$regex:1,1$`. List indexing starts at one; match group indexing follows .NET. [Legacy parser][oldparser]

Current ShareX's migration only changes expression delimiters, removes old escape markers, and escapes literal braces. It cannot correctly translate a RegexList reference into an inline regex. The source has no RegexList migration, so wadjet should resolve valid list references itself or reject those imports. A blind `$` to brace replacement silently changes meaning. [Migration implementation][item], [legacy regex implementation][oldparser]

The 13.7 compatibility adapter accepted old RequestType and transformed pre-12.4 configs: POST became multipart; other methods became None and moved Arguments into Parameters. It rewrote redirection ResponseType to `$responseurl$` and LocationHeader to `$header:Location$`. Generic Headers ResponseType could not migrate automatically. Supporting pre-12.4 is optional for v1, not necessary for the inspected official collection. [13.7 compatibility][olditem], [examples][examples]

## iShare dialect and Mia's migration

iShare decodes top-level property names case-insensitively. Its fields are `id`, `name`, `requesturl`, `headers`, `formdata`, `fileformname`, `requestbodytype`, `responseurl`, `deletionurl`, and `deleterequesttype`. `name`, `requesturl`, and `responseurl` are required strings. `id` defaults to a generated UUID. Body accepts the lowercase enum values `multipartformdata` and `binary`; absence defaults to multipart during execution. Deletion method accepts GET or DELETE case-insensitively. [Model][imodel]

This is not merely ShareX with lowercase keys. iShare uses FormData instead of Arguments, RequestBodyType instead of Body, ResponseURL instead of URL, and `{{path}}` instead of `{json:path}`. It does not decode ShareX's Version, RequestMethod, Parameters, Data, ThumbnailURL or ErrorMessage. Uploads always POST. Header and multipart field values are literal strings. [Model][imodel], [HTTP implementation][ihttp]

iShare parses response JSON with SwiftyJSON. Its double-brace placeholders support dot-separated object paths and numeric array indexes, including `{{files[0].url}}`. This is a custom traversal, not full JSONPath. It does not evaluate regex, XPath, header or raw-response selectors. A missing JSON path returns a diagnostic string, and unresolved replacements can remain in the output. Do not reproduce these failure semantics in wadjet. [Response traversal][ihttp]

Locally observed Destination shape, with credentials omitted:

```json
{
  "name": "imcx",
  "requesturl": "https://i.mia.cx/upload",
  "headers": { "x-auth-key": "<redacted>" },
  "requestbodytype": "binary",
  "responseurl": "{{image}}",
  "deletionurl": "{{deleteUrl}}",
  "deleterequesttype": "GET"
}
```

Evidence for this particular shape is the local `dev.adrian.ishare` / `savedCustomUploaders` defaults entry inspected on 2026-10-07. The UUID is intentionally omitted. The equivalent ShareX-format template is:

```json
{
  "Version": "17.0.0",
  "Name": "imcx",
  "DestinationType": "ImageUploader, FileUploader",
  "RequestMethod": "POST",
  "RequestURL": "https://i.mia.cx/upload",
  "Headers": {
    "x-auth-key": "<redacted>",
    "x-file-name": "{filename}"
  },
  "Body": "Binary",
  "URL": "{json:image}",
  "DeletionURL": "{json:deleteUrl}"
}
```

This is a redacted compatibility example, not a usable credential export. Version selects the modern ShareX grammar; it does not claim wadjet is ShareX 17. iShare adds `x-file-name` for every upload and file MIME Content-Type for binary. ShareX binary file/image paths also send MIME-derived content types, but do not add iShare's filename header. The template therefore adds it explicitly. [iShare HTTP][ihttp], [ShareX file path][file], [ShareX image path][image]

`deleterequesttype` has no ShareX counterpart. Keep GET as separate imported Destination metadata if server deletion ships. Do not infer HTTP DELETE from a DeletionURL field. iShare currently sends deletion with the active Destination's headers, which can differ from the Destination that created a history entry. wadjet should bind deletion context to the Capture's original Destination. [iShare deletion][ihttp], [ShareX properties][item]

## Open risks and effects on other tickets

These are research conclusions and proposed implementation constraints, not verified server behavior:

- **#9, Destination and upload behavior.** Decide Keychain storage/export behavior, unsupported-import handling, redirect credential policy, size limits, cancellation, retries and deletion. `.sxcu` stores Headers/Parameters/Arguments as ordinary strings, so credentials can occur outside headers. Never log imported secrets. [Schema][item], [query-key example][imgbb]
- **#9, result handling.** Preserve extracted thumbnail/deletion URLs. Define failed status, malformed response and empty result as separate outcomes. ShareX's ErrorMessage rule only covers HTTP failure. [Response handling][item]
- **Swift parser portability.** Newtonsoft SelectToken is richer than dot/index traversal, and .NET regex differs from Foundation's engine. Declare the supported JSONPath subset and test numbered/named regex groups, escapes and legacy RegexList conversion. XPath can wait. [JSON][json], [regex][regex], [legacy parser][oldparser]
- **Mia's server.** The observed config establishes `image` and `deleteUrl` expectations, not server MIME/filename requirements, size limits, or deletion behavior. Verify these later through server source or an explicitly authorized test. No production endpoint was exercised here.
- **Workflow integration.** Destination import should not manufacture hotkeys or Steps. The `.sxcu` class has no Workflow fields. This follows wadjet's CONTEXT.md vocabulary and the [ShareX model][item].

## Sources and reproduction

Primary code snapshots: ShareX `ca23f3f697838a0556d5c8caa005dc4760387f56`; iShare `deb7abcdfdef251647c532924bad38426a18b1b2`; CustomUploaders `efe3d263764ad4b86823f331239f3f3bdc864515`. Historical ShareX source uses published tags v12.3.1 and v13.7.0. Official documentation is an unversioned page checked on the research date.

The collection count came from parsing top-level `*.sxcu` files as JSON, grouping Body/RequestMethod/Version. It excludes HTTP verification and does not measure global usage. Source review establishes behavior; no implementation was built or tested in this research ticket.

[item]: https://github.com/ShareX/ShareX/blob/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.UploadersLib/CustomUploader/CustomUploaderItem.cs
[enums]: https://github.com/ShareX/ShareX/blob/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.UploadersLib/Enums.cs
[serializer]: https://github.com/ShareX/ShareX/blob/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.HelpersLib/Helpers/JsonHelpers.cs
[syntax]: https://github.com/ShareX/ShareX/blob/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.UploadersLib/CustomUploader/ShareXSyntaxParser.cs
[dispatch]: https://github.com/ShareX/ShareX/blob/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.UploadersLib/CustomUploader/ShareXCustomUploaderSyntaxParser.cs
[functions]: https://github.com/ShareX/ShareX/tree/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.UploadersLib/CustomUploader/Functions
[json]: https://github.com/ShareX/ShareX/blob/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.UploadersLib/CustomUploader/Functions/CustomUploaderFunctionJson.cs
[regex]: https://github.com/ShareX/ShareX/blob/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.UploadersLib/CustomUploader/Functions/CustomUploaderFunctionRegex.cs
[xml]: https://github.com/ShareX/ShareX/blob/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.UploadersLib/CustomUploader/Functions/CustomUploaderFunctionXml.cs
[file]: https://github.com/ShareX/ShareX/blob/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.UploadersLib/FileUploaders/CustomFileUploader.cs
[image]: https://github.com/ShareX/ShareX/blob/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.UploadersLib/ImageUploaders/CustomImageUploader.cs
[text]: https://github.com/ShareX/ShareX/blob/ca23f3f697838a0556d5c8caa005dc4760387f56/ShareX.UploadersLib/TextUploaders/CustomTextUploader.cs
[olditem]: https://github.com/ShareX/ShareX/blob/v13.7.0/ShareX.UploadersLib/CustomUploader/CustomUploaderItem.cs
[oldparser]: https://github.com/ShareX/ShareX/blob/v13.7.0/ShareX.UploadersLib/CustomUploader/CustomUploaderParser.cs
[ancientitem]: https://github.com/ShareX/ShareX/blob/v12.3.1/ShareX.UploadersLib/Helpers/CustomUploaderItem.cs
[docs]: https://getsharex.com/docs/custom-uploader
[changelog]: https://getsharex.com/changelog
[imodel]: https://github.com/castdrian/ishare/blob/deb7abcdfdef251647c532924bad38426a18b1b2/ishare/Util/CustomUploader.swift
[ihttp]: https://github.com/castdrian/ishare/blob/deb7abcdfdef251647c532924bad38426a18b1b2/ishare/Http/Custom.swift
[examples]: https://github.com/ShareX/CustomUploaders/tree/efe3d263764ad4b86823f331239f3f3bdc864515
[imgbb]: https://github.com/ShareX/CustomUploaders/blob/efe3d263764ad4b86823f331239f3f3bdc864515/imgbb.com.sxcu
[catbox]: https://github.com/ShareX/CustomUploaders/blob/efe3d263764ad4b86823f331239f3f3bdc864515/catbox.moe.sxcu
[binaryexample]: https://github.com/ShareX/CustomUploaders/blob/efe3d263764ad4b86823f331239f3f3bdc864515/support.discordapp.com.sxcu
[zero]: https://github.com/ShareX/CustomUploaders/blob/efe3d263764ad4b86823f331239f3f3bdc864515/0x0.st%20(Image%20uploader).sxcu
