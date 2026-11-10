# OpenAPI contracts

In the Code section ([Code editor](code-editor.md)), a YAML or JSON file that holds an OpenAPI 3.0 or 3.1 contract opens on the **Contract view**, with a switch to **Source**, the ordinary text editor. The Contract view is a native, read-only view of the buffer's current text, unsaved changes included: the API's info, its operations grouped by tag and its schemas, with `$ref` pointers resolved inside the document and across the project's files. Each operation has a request form that sends the request to the project environment chosen in the form ([Environments](projects.md#environments)), from the Mac that shows the window with the app's own HTTP client, and shows the response's status, duration, headers and body. The values typed in the forms are kept per project on that Mac. A Go service whose root holds the contract `openapi/contract.yaml` also shows its Contract view in the **API Explorer** section of the sidebar, and Claude lists and calls its operations with the API tools. This document specifies the detection of contracts, the switch, the Contract view, `$ref` resolution, the request form, prefilled bodies, sending, the response, the stored values, remote windows and the API Explorer.

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
- Only Code section tabs are detected, and the API Explorer's `openapi/contract.yaml` ([Availability](#availability)); the Docs section and the skill editor are unchanged.

## Contract and Source

```
┌──────────────────────────────────────────────────────────────────────┐
│ openapi.yaml  │ main.go  │                                           │ editor tabs, 36 pt
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

The form of an operation has, in this order: Environment, Parameters, Credentials, Body, Headers and the Send button. Parameters, Credentials and Body show only when the operation has some; Environment, Headers and Send always show.

### Environment

- A pop-up lists the environments of the contract's project in their order, for a sub project that inherits environments its parent's first, with its changes ([Environments](projects.md#environments), [Inherited environments](projects.md#inherited-environments)), each item showing the environment's name and its base URL as `<name> · <base URL>`, for example `local · http://127.0.0.1:8080`, or the name alone for an environment without a URL, which has no base URL. It has no other item: the contract's `servers` do not choose the URL of the requests.
- The pop-up is the project's [current working environment](projects.md#current-working-environment): it shows it, and the requests go to it. Choosing an environment makes it the project's current working environment with [projects.setCurrentEnvironment](engine-api.md#projectssetcurrentenvironment), so that the sidebar footer, every other Contract view of the project and the windows of every device follow ([Sidebar](ui.md#sidebar)). A failed call shows no message, and the pop-up keeps showing the current working environment.
- The pop-up follows the project's environments and its current working environment live: an environment added, edited or removed in Project Settings, on any device, shows at once, and so does a change of the environments a sub project inherits from its parent or a current working environment chosen elsewhere. When the current working environment is removed, the pop-up shows the first environment, which becomes current; a rename in Project Settings keeps it current under its new name.
- A project whose type is not `goService` has no environment here, even when its `project.yml` still lists environments from an earlier type ([Environments](projects.md#environments)).
- When the project has no environment, which is always the case for a project whose type is not `goService`, the pop-up is empty and disabled, and under it the form shows `Add an environment in Project Settings.` with a `Project Settings…` button that selects the window's [Project Settings](projects.md#project-settings) section.
- While an environment without a URL is selected, Send is disabled, and under the pop-up the form shows `Set the API Access of this environment in Project Settings.` with a `Project Settings…` button that selects the window's [Project Settings](projects.md#project-settings) section, where the [Environments section](projects.md#environments) sets the URL and the port.

An environment without a URL listed by its name, with Send disabled, its message and its `Project Settings…` button come from the user, as does the pop-up that shows and changes the current working environment. The item text `<name> · <base URL>` and the failed call without message are design-time choices. Default chosen at design time.

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

`Send` sends the request ([Sending a request](#sending-a-request)). It is disabled when the project has no environment, when the selected environment has no URL, and when the URL or the port of the selected environment breaks the rules of [Project environment](data-model.md#project-environment), which happens only for a value written by hand in `project.yml` ([Write rules](data-model.md#write-rules)). While the request runs, a small spinner shows next to the button and the button becomes `Cancel`, which stops the request; the response area then keeps what it showed before.

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

1. **Base URL.** The base URL of the selected environment: its URL with the port replaced by its port when it has one, without a trailing `/` ([Environments](projects.md#environments)).
2. **Path.** The operation's path with each `{name}` replaced by the value of the path parameter `name`, percent-encoded: every byte outside the RFC 3986 unreserved characters (`A`–`Z`, `a`–`z`, `0`–`9`, `-`, `.`, `_`, `~`) is encoded. The URL is the base URL followed by the path.
3. **Query.** The query parameters with a value that is not empty, in the form's order, then the API keys sent in the query, as `name=value` pairs percent-encoded the same way and joined with `&`, appended after `?` (after `&` when the base URL already has a query).
4. **Method.** The operation's method in uppercase.
5. **Headers**, in this order: the header parameters with a value that is not empty; `Cookie` with the cookie parameters and the API keys sent in a cookie that have a value, as `name=value` joined with `; `; the API keys sent in a header; `Authorization: Basic <base64 of username:password>` when the username or the password is not empty; `Authorization: Bearer <token>` when the token is not empty; `Content-Type: <media type>` when a body is sent; then the added headers whose name is not empty, each replacing a header of the same name (compared case-insensitively).
6. **Body.** When the operation has a request body and the selected media type's body is not empty, its UTF-8 bytes.
7. **Remote windows.** In a window that shows a remote device, the URL gets the [forward localhost rewrite](remote.md#forward-rewrite) of web tabs, and so does the URL of every redirect.
8. **Client.** The request runs on the Mac that shows the window, with `URLSession` and an ephemeral configuration without cookie storage, cache or credential storage: the browser's CORS rules do not apply, and nothing is kept between requests. Redirects are followed and the response shown is the last one. The system's request timeout applies (60 s without data). App Transport Security allows plain `http` ([CI › Info.plist keys](ci.md#infoplist-keys)). When the selected environment has `Allow invalid certificates` on ([Environments](projects.md#environments)), the request accepts any invalid server certificate, for example self-signed, issued by an unknown or private CA, expired, or issued for another host name such as a certificate that does not name the IP address of the URL; this applies to every server the request reaches, the servers of redirects to other hosts included. With the setting off, the system's default certificate check applies. The requests with the setting on and those with it off use separate sessions, so a connection or a TLS session that one of them opened is never reused by the other, and a server accepted with the setting on is checked again by a request with it off.
9. **Duration.** From the start of the request to the last byte of the response body, in milliseconds.

The certificates accepted with `Allow invalid certificates` on come from the user. The ephemeral session and redirect following are design-time choices. Default chosen at design time.

## Response

| Part     | Content                                                                                                                                                                                                                                                     |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Status   | `<code> <reason phrase>` in bold, the reason phrase from RFC 9110 and RFC 6585, the code alone for other codes.                                                                                                                                             |
| Duration | `<n> ms`.                                                                                                                                                                                                                                                   |
| Headers  | One line per header, `<name>: <value>`, sorted by name, monospaced and selectable.                                                                                                                                                                          |
| Body     | Absent for an empty body. A body that is UTF-8 text: pretty-printed JSON when the text is JSON, whatever its `Content-Type`, else the text as received, in a 300 pt high read-only code editor. Otherwise `Binary body (<size>)` and a `Quick Look` button. |

- Pretty-printed JSON has 2-space indentation and keeps the members in the received order; it is highlighted with the JSON rules of [Code editor](code-editor.md#json). A body larger than 2 MB is not highlighted.
- `<size>` is a file-style byte count, as in [Large and binary files](code-editor.md#large-and-binary-files). `Quick Look` writes the body to `<temporary folder>/HephaestusV2/Files/<UUID>/response.<extension>` on the Mac that shows the window, the extension coming from the media type (`response` alone when it has none), and opens it in Quick Look.
- When the request fails without a response (no network, refused connection, timeout, invalid URL, a server certificate that the system does not trust while the environment's `Allow invalid certificates` is off), the response area shows `The request failed.` and the error's localized description.
- The last response of each operation stays while the tab is open; responses are never stored.

The 300 pt height is Default chosen at design time.

## Stored values

The values typed in the request forms are kept per project on the Mac that shows the window, in `<data dir>/openapi-requests.json` of that Mac's own data directory ([Architecture](architecture.md#device-data-directory)). The file has mode 0600, like `secrets.json`, because it holds credentials. It is read when a Contract view first needs it, and written atomically ([Data model](data-model.md#atomic-writes)) 500 ms after the last change. A missing, unreadable or invalid file counts as empty; an invalid file is replaced at the next write.

| Kept per contract file                            | Kept per operation (`<METHOD> <path>`)                                                                |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| The credentials of each scheme, the added headers | The values of the parameters, the selected media type and the body of each media type that was edited |

```json
{
  "contracts": [
    {
      "deviceID": "6F1C2D3E-4A5B-4C6D-8E7F-901A2B3C4D5E",
      "projectID": "DEMO",
      "path": "api/openapi.yaml",
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
- Parameters are keyed `<in>:<name>`; credentials by the scheme's name in `components.securitySchemes`.
- No environment is kept per contract file: every Contract view of a project uses the project's current working environment, which the main device keeps ([Environment](#environment), [Current working environment](projects.md#current-working-environment)).
- The keys `environment`, `server`, `usesCustomURL`, `customURL` and `serverVariables` of a file written by an earlier version are ignored and left out at the next write.
- The mode of the tab, the selected row and the responses are not stored.
- The engine of the main device also reads the file, at each `api_call` of a chat, for the credentials and the added headers stored for `openapi/contract.yaml` of the chat's project under the main device's id ([Claude and the API](#claude-and-the-api)). It never writes the file, and the values it reads are those written: a change made less than 500 ms before is not written yet.
- The Code section tabs of a contract file, in every window of this Mac, and the [API Explorer](#api-explorer) for `openapi/contract.yaml` show and change the same values. A change applies to the latest stored values of the contract, so it keeps what another Contract view changed meanwhile; a Contract view takes the latest values, the stored bodies of its body editors included, when it appears and, while it is shown, after each change made in another one. Default chosen at design time.

The file name and its format are design-time choices. Default chosen at design time.

## Remote windows

In a window that shows a remote device ([Remote devices](remote.md#remote-windows)), the contract and the files its refs name are read through the engine of the main device, like every file of the Code section, and the environments and the current working environment are those of the project on the main device; the requests still run on the Mac that shows the window, with the [localhost rewrite](remote.md#localhost-rewrite), so a request to an environment whose host is `localhost`, `127.0.0.1` or `::1` reaches a server running on the main device; the values typed in the forms are stored on the Mac that shows the window.

## API Explorer

The Go Service category of the sidebar ([Sidebar](ui.md#sidebar)) has the row `API Explorer`, with the SF Symbol `point.3.connected.trianglepath.dotted`, for the section `apiExplorer`; View ▸ API Explorer (⇧⌘E) selects it too ([Menus and keyboard shortcuts](ui.md#menus-and-keyboard-shortcuts)). The section shows the Contract view of the Go service's contract, the file `openapi/contract.yaml` of the project root, so that the user views and queries the service without opening the file in the Code section.

### Availability

The row shows while both hold:

1. The active project's [type](projects.md#project-types) is `goService`.
2. The project root holds the file `openapi/contract.yaml`, and its text is an OpenAPI 3.x contract by the rules of [Detection](#detection) for a `yaml` file.

- The workspace of the window's device reads the file with `files.read` ([Engine API](engine-api.md#filesread)) when a main window first shows the Go service project, again after each `files.changed` event of the project whose paths name the file, the `openapi` folder or the whole project (`""`), and after each reconnection ([Event handling](ui.md#event-handling)). Every window that shows the device uses the same result (`DeviceWorkspace.apiContracts`, [DeviceWorkspace](ui.md#deviceworkspace)).
- A missing file, a file read without text (binary, or larger than 20 MiB), a text that is not a contract and a failed read count as no contract. A read that fails because the device is not connected (`unavailable`) keeps the previous result.
- Until the first read of a project ends, its row is hidden.
- The row appears and disappears at once, in every window that shows the project, when the file is added, changed or removed, and when the project's type changes (`project.updated`, `projects.changed`).
- When the row is not shown while a main window's section is `apiExplorer`, the window selects `dashboard`: after a read that finds no contract, after the type changes, when the window switches to a project where the row is not shown, and after a `section` target naming `apiExplorer` in such a project ([Resolving a target](ui.md#resolving-a-target)). While the first read of the project runs, the section stays selected and the centre column shows a small spinner.
- View ▸ API Explorer (⇧⌘E) is enabled while the row is shown.

Hiding the row until the first read ends, keeping `apiExplorer` selected meanwhile, and keeping the previous result while the device is not connected are Default chosen at design time.

### Explorer view

- The centre column shows the [Contract view](#contract-view) of `openapi/contract.yaml`: the list, the details, the request forms with Send and the responses. It has no file tree, no editor tabs, no mode bar and no banner; the contract's source is edited in the Code section.
- The list has a title row above it: the title `API Explorer` in a pane header 36 points high, as wide as the list, its bottom separator on one line with those of the inspector and of the other sections ([Pane headers](ui.md#pane-headers)). The list scrolls under it, and the detail of the selected row keeps the whole height of its column. The Contract view of the Code section has no title row.
- The Contract view shows the file as it is on disk. The section holds a buffer of the file for each window and project (`ProjectViewState.apiExplorerBuffer`, never encoded), created and read with `files.read` when the section first shows the project in the window. The user never edits it, so it follows the file as a clean Code section buffer does ([Changes on disk](code-editor.md#changes-on-disk)): after a change on disk it takes the new text and the Contract view is parsed again ([Contract and Source](#contract-and-source)), and when the file is deleted the buffer is dropped. Its `$ref` pointers resolve as in [$ref resolution](#ref-resolution).
- Until the buffer has text, the centre column shows the notice of the buffer's state, as an editor tab of the Code section does ([Opening files](code-editor.md#opening-files), [Large and binary files](code-editor.md#large-and-binary-files)): a small spinner while the file is read, and `The file could not be opened.` with the engine's message and `Try Again` after a failed read. These notices, and `The contract could not be read.` of a text that cannot be parsed ([Contract view](#contract-view)), take the place of the whole section and show no title row.
- The selected row, the body editors and the last responses stay with the buffer while the window is open, as they do with a Code section tab; they are not stored.
- The request forms are those of the Code section: they show and change the [stored values](#stored-values) of the contract `openapi/contract.yaml`, which are the values of the Code section's Contract view of the same file.
- No menu item acts on the section's content: Save, Close Tab, Go to Line, Toggle Comment, Show Previous Tab and Show Next Tab are disabled, and ⌘W closes the window ([Closing tabs and windows](ui.md#closing-tabs-and-windows)).
- The composer of the inspector links no item for the section ([Inspector](ui.md#inspector)), and a feedback started from it has no `item` ([Feedback context](feedback.md#feedback-context)).
- In a window that shows a remote device, the section works as the Contract view does there ([Remote windows](#remote-windows)): the contract and the files its refs name are read through the engine of the main device, the requests run on the Mac that shows the window with the localhost rewrite, and the values typed are stored on that Mac.

The notices and the absent feedback item are Default chosen at design time. The title row, above the list only, and the notices without title row come from the user ([R194](requirements.md#requirements)).

### Claude and the API

Claude uses the contract of the API Explorer through two MCP tools of the `hephaestus` server, available in every chat of a Go service project ([API tools](mcp.md#api-tools)):

- `api_operations` lists the operations of `openapi/contract.yaml`, read from disk on the main device with its `$ref` pointers resolved, with what their [Operation detail](#operation-detail) shows.
- `api_call` sends the request of an operation to an environment of the project, built as the [request form](#request-form) builds it, with the parameters, the body and the headers Claude gives, and the credentials and the added headers stored on the main device for `openapi/contract.yaml` of the project ([Stored values](#stored-values)): the values typed in the API Explorer and the Code section Contract views of the main device's windows, never those typed on another Mac. The request runs on the main device, in the engine, with the client of [Sending a request](#sending-a-request) and the environment's `Allow invalid certificates`, without the localhost rewrite. The calls whose method is `GET` or `HEAD` run without a permission prompt.

The requests of `api_call` do not show in the API Explorer and change none of its stored values. Claude never sees a stored credential or header value.

## Not included

OAuth2, OpenID Connect and mutual TLS credentials, multipart and file bodies, editing the contract in the Contract view, Swagger 2.0, `$ref` to URLs, a history of requests, response validation against the schemas and code generation. Default chosen at design time.

## Requirements covered

- R142: In the Code section, an OpenAPI 3.0 or 3.1 contract opens on a read-only Contract view, with a switch to its source, that shows its info, its operations by tag and its schemas with their `$ref` pointers resolved across the project's files, and sends each operation's request from a form whose values are kept per project on the Mac that shows the window, credentials included.
- R171: A Go service whose code holds `openapi/contract.yaml` shows it in an API Explorer section of the Go Service category, where the user views and queries it.
- R157: A Go service project declares its environments in Project Settings, and the Contract view sends requests to the environment chosen in its Environment pop-up.
- R174: A sub project that uses its parent's settings inherits its parent's environments and changes their URL, port, deployment and Argo CD application.
- R177: Each Go service project has a current working environment, chosen in the sidebar under the project identifier and shared by every device, which the Contract view, Project Settings and Claude use.
- R182: Each environment of a Go service has an `Allow invalid certificates` setting, off by default and changeable by a sub project that inherits the environment, with which the Contract view's requests to it accept any invalid server certificate.
- R190: Every chat of a Go service project whose API Explorer shows a contract lists the contract's operations and calls them on an environment through HephaestusV2's API tools, with the credentials and headers stored in the API Explorer; GET and HEAD calls run without a permission prompt.
- R194: Every section of the main window shows a title, and so do the Global Memories and Internal Skills views: Dashboard, Tickets, Bundles, Chats, Web, Builds, Skills, Memories and API Explorer show their sidebar title in a title row above their left column.
