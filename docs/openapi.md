# OpenAPI contracts

In the Code section ([Code editor](code-editor.md)), a YAML or JSON file that holds an OpenAPI 3.0 or 3.1 contract opens on the **Contract view**, with a switch to **Source**, the ordinary text editor. The Contract view is a native, read-only view of the buffer's current text, unsaved changes included: the API's info, its operations grouped by tag and its schemas, with `$ref` pointers resolved inside the document and across the project's files. Each operation has a request form that sends the request from the Mac that shows the window with the app's own HTTP client, and shows the response's status, duration, headers and body. The values typed in the forms are kept per project on that Mac. This document specifies the detection of contracts, the switch, the Contract view, `$ref` resolution, the request form, prefilled bodies, sending, the response, the stored values and remote windows.

## Detection

A file opens on the Contract view when both hold:

1. Its [language](code-editor.md#language-detection) is `yaml` or `json`.
2. Its text has a top-level `openapi` key whose value starts with `3`:

| Text                                                                                       | Rule                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `json` file, or `yaml` file whose first character that is not blank or in a comment is `{` | The text is scanned as JSON: strings (with their escapes), `{`, `}`, `[` and `]` are followed to know the depth; a member of the outermost object named `"openapi"` whose value is a string starting with `3` matches.                                                                                                                                            |
| other `yaml` file                                                                          | A line that starts at column 1 with the key `openapi`, written plain, in single quotes or in double quotes, followed by `:` and a blank; its value, without a trailing comment (a blank then `#`) and without the quotes around it, starts with `3`. Lines of a block scalar, of a flow collection or of a later document (after a second `---`) are not checked. |

- Swagger 2.0 files (`swagger: "2.0"`) and every other file open in the editor as before.
- Detection runs when the tab takes the text of a read: when it opens, on Try Again, when a clean buffer is replaced silently after a change on disk, and on Reload ([Changes on disk](code-editor.md#changes-on-disk)). Edits in Source never add or remove the switch. A tab whose file is no longer detected loses the switch and shows the editor; a tab whose file becomes detected gets the switch and shows the Contract view.
- A file larger than 2 MB, open read-only ([Large and binary files](code-editor.md#large-and-binary-files)), is detected and shows the Contract view too.
- Only Code section tabs are detected; the Docs section and the skill editor are unchanged.

## Contract and Source

```
┌──────────────────────────────────────────────────────────────────────┐
│ openapi.yaml  │ main.go  │                                           │ editor tabs, 30 pt
│──────────────────────────────────────────────────────────────────────│
│                                              [ Contract | Source ]   │ mode bar, 30 pt
│──────────────────────────────────────────────────────────────────────│
│ This file changed on disk.                       [Reload] [Keep Mine]│ banner, when needed
│──────────────────────────────────────────────────────────────────────│
│                Contract view, or the editor                          │
└──────────────────────────────────────────────────────────────────────┘
```

| Part     | Content                                                                                                                                                                |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Mode bar | Under the editor tabs, only for a detected file: the segmented control `Contract`, `Source` on the right.                                                              |
| Banner   | The changed-on-disk and deleted-on-disk banners of [Banners](code-editor.md#banners) in both modes; the large-file banner only in Source.                              |
| Content  | `Contract`: the [Contract view](#contract-view). `Source`: the editor of [Code editor](code-editor.md#editor), with the file's text and every behaviour of the editor. |

- A detected tab starts on `Contract`. Each tab keeps its mode while it is open (`EditorBuffer.showsContract`, [Editor buffers](code-editor.md#editor-buffers)); a tab opened again, or restored with its window, starts on `Contract`.
- The Contract view is read-only: the contract changes only through Source, Claude or another program. Saving (⌘S) and closing work in both modes; Go to Line, Toggle Comment and Find need the editor's focus and act only in Source.
- The Contract view shows the buffer's current text, saved or not. While it is shown, it is parsed again 300 ms after the last change of the buffer's text (a reload from disk included), when it appears (the tab is selected, or the mode switches to `Contract`), and after a `files.changed` event that names a file its `$ref` pointers read.

The bar's height, the 300 ms delay and the absence of a shortcut for the switch are design-time choices. Default chosen at design time.

## Contract view

```
┌──────────────────────────┬───────────────────────────────────────────────────┐
│ Pet Store 1.2.0          │ [GET] /pets/{petId}                               │
│ pets                     │ Info for a specific pet                           │
│  [GET]  /pets            │                                                   │
│  [POST] /pets            │ Parameters                                        │
│  [GET]  /pets/{petId}    │ Request Body                                      │
│ default                  │ Responses                                         │
│  [GET]  /health          │ Request                                           │
│ Schemas                  │ Response                                          │
│  Pet                     │                                                   │
│  Error                   │                                                   │
└──────────────────────────┴───────────────────────────────────────────────────┘
  list, 240 pt                        detail of the selected row
```

The divider between list and detail is draggable (180 to 400 pt); the detail keeps at least 300 pt. Default chosen at design time.

When the text cannot be parsed as an OpenAPI 3.x document, the Contract view shows instead, centered, the title `The contract could not be read.` and the parser's message in monospaced, selectable text; the mode bar stays, so `Source` shows the text. The text cannot be parsed when it is not valid YAML or JSON, when its root is not a mapping, or when the root has no `openapi` value starting with `3`.

### List

| Row        | Content                                                                                                                                                                                                                                                                                     |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Info       | The first row: `info.title` and `info.version` in secondary color.                                                                                                                                                                                                                          |
| Tag header | One per tag that has operations: the tags of the root `tags` array in their order, then the tags that operations name without declaring them, in the order of their first use, then `default` for the operations without tags. An operation with several tags is listed under each of them. |
| Operation  | The method badge and the path in monospaced text, then `summary` in secondary color on a second line when the operation has one.                                                                                                                                                            |
| `Schemas`  | A header, then one row per member of `components.schemas`, in the contract's order. Absent when the contract has no schema.                                                                                                                                                                 |

- Operations are listed in the order of `paths`, and inside a path in the order `get`, `put`, `post`, `delete`, `options`, `head`, `patch`, `trace`. A path item reached through `$ref` is resolved first.
- Clicking a row selects it; the Info row is selected when the view first shows. After the contract is parsed again, the selection is kept when the list still has the same row (an operation is identified by its method and path, a schema by its name), else the Info row is selected. The selection is kept per tab while it is open and is not stored.

Method badges are capsules 52 pt wide with the method in uppercase, white, bold monospaced 10 pt:

| Method                     | Color     |
| -------------------------- | --------- |
| `GET`                      | `#61AFFE` |
| `POST`                     | `#49CC90` |
| `PUT`                      | `#FCA130` |
| `DELETE`                   | `#F93E3E` |
| `PATCH`                    | `#50E3C2` |
| `HEAD`, `OPTIONS`, `TRACE` | `#9B9B9B` |

The colors are the ones of Swagger UI; sizes and fonts are design-time choices. Default chosen at design time.

### Info detail

The title (title font) and the version; `OpenAPI <openapi value>` in secondary color; `info.summary` and `info.description`; `Terms of Service` (`termsOfService`), `Contact` (`name`, `email` as a `mailto:` link, `url`) and `License` (`name`, then `url` as a link or `identifier`) when present; `Servers`, one line per root server with its URL in monospaced text and its description. Default chosen at design time.

### Operation detail

From top to bottom, each part only when it applies:

1. The method badge and the path in monospaced text; `summary` in the headline font; `description`.
2. `Parameters`: the path item's parameters merged with the operation's (an operation parameter replaces the path item's parameter with the same `name` and `in`), each as a row of its name in monospaced text, its location (`path`, `query`, `header` or `cookie`), the type summary of its schema, `required` when required, and its description; its schema expands as in [Schema trees](#schema-trees).
3. `Request Body`: `required` when required, its description, then for each media type its name in monospaced text and its schema tree.
4. `Responses`: for each member of `responses` in the contract's order, its code (`default` included) in monospaced bold, its description, then for each media type its name and its schema tree.
5. `Request`: the [request form](#request-form).
6. `Response`: the [response](#response) of the last request sent from this form, when there is one.

Descriptions are CommonMark: inline Markdown (emphasis, code and links) is rendered, block structure is shown as plain text. Default chosen at design time.

### Schema detail

The schema's name in the title font, its description, and its schema tree expanded one level.

### Schema trees

A schema is shown as a tree of rows. Each row has, in this order: its label in monospaced text (a property name, or one of the labels below), its type summary in secondary color, `required` for a required property, the schema's `format`, its `enum` values (`enum: a, b, c`) and its description. A row with children has a disclosure triangle; rows start collapsed, except the first level of a Schema detail.

| Schema has                         | Children                                                                                      |
| ---------------------------------- | --------------------------------------------------------------------------------------------- |
| `properties`                       | One row per property, in the contract's order; `required` from `required`.                    |
| `additionalProperties` as a schema | A row labelled `additionalProperties`.                                                        |
| `items`                            | A row labelled `items`.                                                                       |
| `allOf`, `oneOf`, `anyOf`          | A row labelled with the keyword, whose children are its schemas labelled `1`, `2`, and so on. |

| Type summary                                  | Rule                                                                                                                                                                      |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A schema reached through `$ref`               | The last token of the ref's pointer (for example `Pet` for `#/components/schemas/Pet`), or the file's name when the ref has no pointer, then ` · ` and the summary below. |
| `type` a string, or an array of strings (3.1) | The types joined with ` \| `, and ` \| null` when `nullable` is true (3.0).                                                                                               |
| No `type`, with `properties`                  | `object`.                                                                                                                                                                 |
| No `type`, with `allOf`, `oneOf` or `anyOf`   | The keyword.                                                                                                                                                              |
| None of these                                 | `any`.                                                                                                                                                                    |

- A ref that cannot be resolved ([$ref resolution](#ref-resolution)) shows `Unresolved` in the system orange, followed by the ref as written, and has no children.
- A ref whose target is already on the way from the top of the tree (a circular schema) shows its name and type summary and has no children.

Default chosen at design time.

## $ref resolution

Every object of the contract that has a `$ref` string member is replaced by the ref's target; its other members are ignored. A target that is itself a `$ref` is followed, at most 32 times.

1. A ref is split at its first `#` into a file part and a fragment. The fragment is a JSON pointer (RFC 6901): `/`-separated tokens, `~1` standing for `/` and `~0` for `~`, after percent-decoding. An empty or missing fragment is the whole file.
2. An empty file part names the file that holds the ref. Otherwise the file part, percent-decoded, is a path relative to the folder of the file that holds the ref; it is joined with that folder, and its `.` and `..` components are removed.
3. The ref cannot be resolved when the file part has a URL scheme (`http:`, `https:`, `file:` and any other), starts with `/`, or leaves the project's folder; when the file cannot be read or parsed; or when the pointer names no value.
4. Another file is parsed as JSON when its [language](code-editor.md#language-detection) is `json`, otherwise as YAML. Refs inside it resolve against its own folder.
5. When a Code section tab of the same window and project has the file open with text, the tab's text is used, unsaved changes included; otherwise the file is read with `files.read` ([Engine API](engine-api.md#filesread)) through the window's engine. Every parse reads the files again.

The 32-ref limit is Default chosen at design time.

## Request form

The form of an operation has, in this order: Server, Parameters, Credentials, Body, Headers and the Send button. Parameters, Credentials and Body show only when the operation has some; Server, Headers and Send always show.

### Server

- A pop-up lists the servers of the operation (its `servers`, else its path item's `servers`, else the root `servers`) whose URL, with every variable replaced by its default, is an absolute `http` or `https` URL; each item shows the server's URL as written in the contract (for example `https://{region}.example.com/v1`). The last item is `Custom URL`.
- The pop-up starts on the first server, or on `Custom URL` when no server qualifies.
- Under it, the selected server's description, then one row per variable of the selected server: its name, then a pop-up of its `enum` values when it has some, else a text field. A variable starts on its `default`.
- `Custom URL` shows a text field `URL` under the pop-up.

### Parameters

Every parameter of the [operation detail](#operation-detail), grouped by location in the order `path`, `query`, `header`, `cookie`, each group under a caption with the location's name: its name in monospaced text, `required` when required, and a text field whose placeholder is the type summary of its schema. Values are sent as typed.

### Credentials

The form shows the security schemes that the operation's security requirements name: the operation's `security`, else the root `security`; an empty `security` array names none. When neither the operation nor the root has `security`, every supported scheme of `components.securitySchemes` is shown. Supported schemes:

| Scheme                         | Fields                                                                                          |
| ------------------------------ | ----------------------------------------------------------------------------------------------- |
| `type: apiKey`                 | A text field labelled with the key's `name` and its location, for example `X-API-Key (header)`. |
| `type: http`, `scheme: basic`  | `Username`, and `Password` as a secure field.                                                   |
| `type: http`, `scheme: bearer` | `Token`, as a secure field.                                                                     |

Each scheme shows its name from `components.securitySchemes` and its description above its fields. `oauth2`, `openIdConnect`, `mutualTLS` and the other `http` schemes are not shown.

### Body

When the operation has a request body: a pop-up of its media types when it has more than one (the first one is selected at first), else the media type's name; `required` when it is required; and a 200 pt high code editor with the body for the selected media type. The editor is the [code editor](code-editor.md#editor) with JSON highlighting for JSON media types and no highlighting for the others. Each media type has its own body; a body that was never edited is [prefilled](#prefilled-bodies) and follows the contract when it is parsed again.

### Headers

Rows of a name field (placeholder `Name`) and a value field (placeholder `Value`), each with a remove button (SF Symbol `minus.circle`), then the `Add Header` button, which adds an empty row.

### Send

`Send` sends the request ([Sending a request](#sending-a-request)). It is disabled when the base URL is not an absolute `http` or `https` URL (for example an empty `Custom URL`). While the request runs, a small spinner shows next to the button and the button becomes `Cancel`, which stops the request; the response area then keeps what it showed before.

The layout of the form and the 200 pt height are design-time choices. Default chosen at design time.

## Prefilled bodies

A body that was never edited starts with, in this order of preference:

1. the media type's `example`;
2. the `value` of the first member of the media type's `examples` (an Example object reached through `$ref` is resolved);
3. a sample built from the media type's schema ([Samples from schemas](#samples-from-schemas));
4. an empty text when there is no schema.

The value is written by the media type's kind:

| Media type                                               | Text                                                                                                                                                                                   |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| JSON: `application/json`, or a subtype ending in `+json` | JSON with 2-space indentation, members in the contract's order.                                                                                                                        |
| `application/x-www-form-urlencoded`                      | For an object, its members as `name=value` joined with `&`, names and values percent-encoded; a string member as is, a number or boolean as written, any other member as compact JSON. |
| Any other                                                | A string as is; any other value as JSON with 2-space indentation.                                                                                                                      |

Media type names are compared case-insensitively and without their parameters (`application/json; charset=utf-8` is JSON).

### Samples from schemas

The first matching row gives the sample:

| Schema                                            | Sample                                                                                              |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Unresolved or circular ref                        | none: a property is left out; at the top, `null`.                                                   |
| `example`, or the first value of `examples` (3.1) | That value.                                                                                         |
| `default`                                         | That value.                                                                                         |
| `const`                                           | That value.                                                                                         |
| `enum`                                            | Its first value.                                                                                    |
| `allOf`                                           | The members of the samples of its schemas that are objects, merged in order; else the first sample. |
| `oneOf` or `anyOf`                                | The sample of its first schema.                                                                     |
| `type` `object`, or `properties` without `type`   | An object with the sample of every property that is not `readOnly`, in the contract's order.        |
| `type` `array`                                    | An array holding the sample of `items`, or an empty array without `items`.                          |
| `type` `string`                                   | By `format`: the table below; any other format, or none: `string`.                                  |
| `type` `integer` or `number`                      | `minimum` when it is set, else `0`.                                                                 |
| `type` `boolean`                                  | `true`.                                                                                             |
| `type` `null`                                     | `null`.                                                                                             |
| Anything else                                     | `null`.                                                                                             |

When `type` is an array (3.1), its first type other than `null` is used.

| `format`     | Sample                                 |
| ------------ | -------------------------------------- |
| `date`       | `2024-01-01`                           |
| `date-time`  | `2024-01-01T00:00:00Z`                 |
| `time`       | `00:00:00`                             |
| `email`      | `user@example.com`                     |
| `uuid`       | `3fa85f64-5717-4562-b3fc-2c963f66afa6` |
| `uri`, `url` | `https://example.com`                  |
| `hostname`   | `example.com`                          |
| `ipv4`       | `192.0.2.1`                            |
| `ipv6`       | `2001:db8::1`                          |

The sample values are design-time choices. Default chosen at design time.

## Sending a request

1. **Base URL.** The selected server's URL with each `{variable}` replaced by its value, or the `Custom URL` text, trimmed. A trailing `/` is removed.
2. **Path.** The operation's path with each `{name}` replaced by the value of the path parameter `name`, percent-encoded: every byte outside the RFC 3986 unreserved characters (`A`–`Z`, `a`–`z`, `0`–`9`, `-`, `.`, `_`, `~`) is encoded. The URL is the base URL followed by the path.
3. **Query.** The query parameters with a value that is not empty, in the form's order, then the API keys sent in the query, as `name=value` pairs percent-encoded the same way and joined with `&`, appended after `?` (after `&` when the base URL already has a query).
4. **Method.** The operation's method in uppercase.
5. **Headers**, in this order: the header parameters with a value that is not empty; `Cookie` with the cookie parameters and the API keys sent in a cookie that have a value, as `name=value` joined with `; `; the API keys sent in a header; `Authorization: Basic <base64 of username:password>` when the username or the password is not empty; `Authorization: Bearer <token>` when the token is not empty; `Content-Type: <media type>` when a body is sent; then the added headers whose name is not empty, each replacing a header of the same name (compared case-insensitively).
6. **Body.** When the operation has a request body and the selected media type's body is not empty, its UTF-8 bytes.
7. **Remote windows.** In a window that shows a remote device, the URL gets the [forward localhost rewrite](remote.md#forward-rewrite) of web tabs, and so does the URL of every redirect.
8. **Client.** The request runs on the Mac that shows the window, with `URLSession` and an ephemeral configuration without cookie storage, cache or credential storage: the browser's CORS rules do not apply, and nothing is kept between requests. Redirects are followed and the response shown is the last one. The system's request timeout applies (60 s without data). App Transport Security allows plain `http` ([CI › Info.plist keys](ci.md#infoplist-keys)).
9. **Duration.** From the start of the request to the last byte of the response body, in milliseconds.

The ephemeral session and redirect following are design-time choices. Default chosen at design time.

## Response

| Part     | Content                                                                                                                                                                                                                                                     |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Status   | `<code> <reason phrase>` in bold, the reason phrase from RFC 9110 and RFC 6585, the code alone for other codes.                                                                                                                                             |
| Duration | `<n> ms`.                                                                                                                                                                                                                                                   |
| Headers  | One line per header, `<name>: <value>`, sorted by name, monospaced and selectable.                                                                                                                                                                          |
| Body     | Absent for an empty body. A body that is UTF-8 text: pretty-printed JSON when the text is JSON, whatever its `Content-Type`, else the text as received, in a 300 pt high read-only code editor. Otherwise `Binary body (<size>)` and a `Quick Look` button. |

- Pretty-printed JSON has 2-space indentation and keeps the members in the received order; it is highlighted with the JSON rules of [Code editor](code-editor.md#json). A body larger than 2 MB is not highlighted.
- `<size>` is a file-style byte count, as in [Large and binary files](code-editor.md#large-and-binary-files). `Quick Look` writes the body to `<temporary folder>/HephaestusV2/Files/<UUID>/response.<extension>` on the Mac that shows the window, the extension coming from the media type (`response` alone when it has none), and opens it in Quick Look.
- When the request fails without a response (no network, refused connection, timeout, invalid URL), the response area shows `The request failed.` and the error's localized description.
- The last response of each operation stays while the tab is open; responses are never stored.

The 300 pt height is Default chosen at design time.

## Stored values

The values typed in the request forms are kept per project on the Mac that shows the window, in `<data dir>/openapi-requests.json` of that Mac's own data directory ([Architecture](architecture.md#device-data-directory)). The file has mode 0600, like `secrets.json`, because it holds credentials. It is read when a Contract view first needs it, and written atomically ([Data model](data-model.md#atomic-writes)) 500 ms after the last change. A missing, unreadable or invalid file counts as empty; an invalid file is replaced at the next write.

| Kept per contract file                                                                                                                             | Kept per operation (`<METHOD> <path>`)                                                                |
| -------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| The selected server or `Custom URL`, the custom URL, the values of the variables of each server, the credentials of each scheme, the added headers | The values of the parameters, the selected media type and the body of each media type that was edited |

```json
{
  "contracts": [
    {
      "deviceID": "6F1C2D3E-4A5B-4C6D-8E7F-901A2B3C4D5E",
      "projectID": "DEMO",
      "path": "api/openapi.yaml",
      "server": "https://{region}.example.com/v1",
      "usesCustomURL": false,
      "customURL": "",
      "serverVariables": { "https://{region}.example.com/v1": { "region": "eu" } },
      "credentials": {
        "bearerAuth": { "token": "example-token" },
        "basicAuth": { "username": "user", "password": "example-password" },
        "apiKeyAuth": { "value": "example-key" }
      },
      "headers": [ { "name": "X-Tenant", "value": "demo" } ],
      "operations": {
        "GET /pets/{petId}": {
          "parameters": { "path:petId": "42", "query:verbose": "true" },
          "bodies": {}
        }
      }
    }
  ]
}
```

- A contract is identified by the device id of the window, the project id and the file's project path, so a window that shows a remote device keeps its values on this Mac under the remote device's id. A renamed or moved contract starts with empty values.
- Parameters are keyed `<in>:<name>`; credentials by the scheme's name in `components.securitySchemes`; server variables by the server's URL as written.
- The mode of the tab, the selected row and the responses are not stored.

The file name and its format are design-time choices. Default chosen at design time.

## Remote windows

In a window that shows a remote device ([Remote devices](remote.md#remote-windows)), the contract and the files its refs name are read through the engine of the main device, like every file of the Code section; the requests run on the Mac that shows the window with the [localhost rewrite](remote.md#localhost-rewrite), so a request to `localhost` reaches a server running on the main device; the values typed in the forms are stored on the Mac that shows the window.

## Not included

OAuth2, OpenID Connect and mutual TLS credentials, multipart and file bodies, editing the contract in the Contract view, Swagger 2.0, `$ref` to URLs, a history of requests, response validation against the schemas and code generation. Default chosen at design time.

## Requirements covered

- R142: In the Code section, an OpenAPI 3.0 or 3.1 contract opens on a read-only Contract view, with a switch to its source, that shows its info, its operations by tag and its schemas with their `$ref` pointers resolved across the project's files, and sends each operation's request from a form whose values are kept per project on the Mac that shows the window, credentials included.
