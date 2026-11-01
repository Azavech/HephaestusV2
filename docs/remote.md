# Remote Devices

A window of HephaestusV2 can show the projects of another Mac on the network as if it were working on that Mac. Every engine runs a sync server advertised with Bonjour; a remote device connects to it over TCP and WebSocket, proves that it knows the main device's pairing code, derives ChaCha20-Poly1305 keys for the connection, receives a snapshot, and from then on calls the [Engine API](engine-api.md) and receives every engine event live, exactly like a local window. This document is the wire contract of sync protocol version 1 (discovery, pairing, handshake, key derivation, framing, messages, close codes, timeouts), the behaviour of both ends (state machines, reconnection, snapshot and event replay, localhost rewrite of web tabs, failure states) and the test vectors that every implementation reproduces.

## Terms

| Term           | Meaning                                                                                                      |
| -------------- | ------------------------------------------------------------------------------------------------------------ |
| Main device    | The Mac whose engine a window shows. In the sync protocol it is the server.                                  |
| Remote device  | A Mac whose window shows the engine of another Mac. In the sync protocol it is the client.                   |
| Paired device  | A device this Mac has added with its pairing code. Listed in `remotes.yml`.                                  |
| Pairing code   | The 16-character secret of a main device, entered once on each remote device.                                |
| Session        | One authenticated connection, from the `welcome` to the close.                                               |
| `c2s`, `s2c`   | The client-to-server and server-to-client directions.                                                        |
| `nc`, `ns`     | The 32-byte client nonce and server nonce of one handshake.                                                  |
| `K`            | The 32-byte pairing key derived from the pairing code.                                                       |
| `kC2S`, `kS2C` | The 32-byte ChaCha20-Poly1305 keys of one connection, one per direction.                                     |
| Device address | The host a remote device uses to reach the main device; used by the [localhost rewrite](#localhost-rewrite). |

Every Mac is the main device of its own windows and of the remote devices connected to it, and at the same time a remote device of every other Mac its windows show. The engine and client split itself is described in [Architecture](architecture.md#engine-and-client-split).

## Layers

| Layer      | Content                                                                       | Section                                 |
| ---------- | ----------------------------------------------------------------------------- | --------------------------------------- |
| Engine API | Requests, responses and events of the [Engine API](engine-api.md)             | [Session messages](#session-messages)   |
| JSON       | One UTF-8 JSON object per WebSocket message                                   | [JSON encoding](#json-encoding)         |
| Encryption | ChaCha20-Poly1305, one key and one counter per direction, after the handshake | [Frame sealing](#frame-sealing)         |
| Handshake  | `hello`, `challenge`, `auth` (text frames), `welcome` (first encrypted frame) | [Handshake](#handshake)                 |
| WebSocket  | RFC 6455 version 13 over TCP, without TLS, subprotocol or extension           | [Transport](#transport)                 |
| TCP        | Port 47821 by default (setting `syncPort`)                                    | [Sync server](#sync-server)             |
| Discovery  | Bonjour service `_hephaestus2._tcp` with TXT keys `id`, `name`, `proto`       | [Bonjour discovery](#bonjour-discovery) |

## Devices

### Device identity

Each engine has a device identity in `device.yml` ([Data model](data-model.md#device-file)): `id`, a UUID generated at first launch and never changed, and `name`, set in Settings > Devices or, when not set, the Mac's computer name. `device.info` returns DeviceInfo `{id, name, appVersion, build, protocolVersion}` with `protocolVersion` 1 for the protocol in this document ([Engine API](engine-api.md#deviceinfo)). The Device menu labels the local device "This Mac" and every other device with its name ([UI](ui.md#breadcrumb-selector)).

Changing the device name re-registers the Bonjour advertisement with the new instance name and TXT `name`, and the new name is used in every later `hello` and `welcome`, the next `hello` of a connection opened before the change included. Open sessions are not notified; their peers see the new name at their next `welcome`. Default chosen at design time.

### Paired devices

The remote device keeps one record per paired device in `remotes.yml` ([Data model](data-model.md#remotes-file)) and that device's pairing code, in display form, in `remoteSecrets` of `secrets.json` ([Data model](data-model.md#secrets-file)).

| Field         | Written when                                                                                                                                                                                    |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| id            | At pairing, from `welcome.device.id`.                                                                                                                                                           |
| name          | At every `welcome`, from `welcome.device.name`.                                                                                                                                                 |
| host, port    | At pairing. After every `welcome` of a connection made through Bonjour: the IPv4 address and port of the connection's remote endpoint. A typed address is kept as typed, IPv6 without brackets. |
| lastConnected | At every `welcome`: the current time.                                                                                                                                                           |
| pairing code  | Only after a `welcome` proved it correct ([Adding a device](#adding-a-device)).                                                                                                                 |

Paired devices are listed in the Device menu, in Settings > Devices and in `AppModel.devices` in the order of `remotes.yml`, the order in which they were first added; pairing a device again keeps its place. Default chosen at design time.

The main device stores nothing about the remote devices that connect to it: any device that knows its current pairing code can connect.

### Online status

A paired device is online when the Bonjour browser currently sees a service whose TXT `id` equals the device id, or when this app's connection to it is in phase `connected`. Otherwise it is offline. The Device menu and Settings > Devices show it as a dot ([UI](ui.md#breadcrumb-selector)). Default chosen at design time.

### One connection per device

An app keeps at most one `RemoteEngineConnection` per paired device id. It belongs to the device's `DeviceWorkspace` and is shared by every window that shows the device ([UI](ui.md#appmodel)). It opens when a window selects the device, or when an Add Device attempt succeeds (that attempt's connection becomes it). It closes with code 1000 as soon as no main window and no chat window shows the device, when the device is removed, and when the app quits.

Each window chooses its device, so several windows show different devices at once, each device through its own connection. The main device closes an older session when a newer one with the same device id authenticates (code 4008), so a client that opened one connection per window would disconnect itself.

## Sync server

| Aspect                | Rule                                                                                                                                                                                                                                               |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Owner                 | `SyncServer` in `Sources/HephaestusCore/Sync/`, started by the engine at launch ([Startup](architecture.md#startup)).                                                                                                                              |
| Runs when             | Setting `syncEnabled` is true (default true; "Allow remote devices" in Settings > Devices).                                                                                                                                                        |
| Port                  | `HEPHAESTUS_SYNC_PORT` when set, otherwise setting `syncPort` (default 47821); values and precedence in [Environment overrides](architecture.md#environment-overrides).                                                                            |
| Addresses             | Every interface, IPv4 and IPv6.                                                                                                                                                                                                                    |
| Listener              | `NWListener` with TCP and `NWProtocolWebSocket`, `allowLocalEndpointReuse` true, `autoReplyPing` true, `maximumMessageSize` 33,554,460.                                                                                                            |
| Advertising           | The Bonjour service is set on the listener, so it is advertised exactly while the listener is ready.                                                                                                                                               |
| State                 | `stopped`, `listening(port)` or `failed(message)`, published to the app as server status ([Local-only services](architecture.md#local-only-services)).                                                                                             |
| Bind failure          | The server retries once per second, 5 attempts in all, then stays `failed` until `syncEnabled` or `syncPort` changes or the app restarts, like the [MCP server](mcp.md#server-lifecycle). Default chosen at design time.                           |
| Later failure         | A listener that fails after it was ready is cancelled and reports `failed` with the system's error text, logged as a bind failure; it is not retried until `syncEnabled` or `syncPort` changes or the app restarts. Default chosen at design time. |
| `syncEnabled` → false | Stop advertising, close every connection with 1001, cancel the listener.                                                                                                                                                                           |
| `syncEnabled` → true  | Start the listener and the advertising.                                                                                                                                                                                                            |
| `syncPort` changed    | While `HEPHAESTUS_SYNC_PORT` is not set: close every connection with 1001, start a listener on the new port, advertise again. While it is set, the new value has no effect until the app runs without it.                                          |
| App quits             | Close every connection with 1001 ([Shutdown](architecture.md#shutdown)).                                                                                                                                                                           |
| Outgoing connections  | Never made by the server. `RemoteEngineConnection` makes them, whatever the value of `syncEnabled`.                                                                                                                                                |

The server status also carries the list of open sessions (device id, device name, remote address, connected since, appVersion). The status bar of windows that show This Mac displays the number of distinct device ids in it ([UI](ui.md#status-bar)). The status is a local-only service, not part of the Engine API, so remote devices and MCP clients cannot read it.

## Bonjour discovery

### Advertising

| Item          | Value                                                                    |
| ------------- | ------------------------------------------------------------------------ |
| Service type  | `_hephaestus2._tcp`                                                      |
| Domain        | `local.` (the system default)                                            |
| Instance name | The device name, truncated to 63 bytes of UTF-8 at a character boundary. |
| Port          | The listener's port.                                                     |
| TXT record    | The three keys below.                                                    |

The system renames the instance when another service on the network has the same name (for example "Studio (2)"). Clients never identify a device by its instance name; they use TXT `id`.

### TXT record

| Key   | Value                                                                   | Example                                |
| ----- | ----------------------------------------------------------------------- | -------------------------------------- |
| id    | The device id, uppercase canonical UUID.                                | `9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6` |
| name  | The device name, UTF-8, truncated to 250 bytes at a character boundary. | `Studio`                               |
| proto | The sync protocol version, decimal ASCII.                               | `1`                                    |

Keys are lowercase ASCII. No other key is published. The record is replaced when the device name changes. The truncation lengths are Default chosen at design time.

The record is written as raw DNS-SD TXT data, each `key=value` string preceded by its length byte, in the order of the table: `NWTXTRecord` refuses a `name=` entry of 255 bytes, the size reached by a 250-byte name.

### Browsing

`DeviceBrowser` browses `_hephaestus2._tcp` in `local.` with TXT records (`NWBrowser.Descriptor.bonjourWithTXTRecord`) from app launch until the app quits. Each result is interpreted as follows.

| Condition                                                      | Result                                                                             |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `id` missing or not a UUID                                     | Ignored.                                                                           |
| `id` equal to this device's id                                 | Ignored (it is This Mac).                                                          |
| `proto` missing or not `1`                                     | Listed in Add Device with "Incompatible version"; it cannot be selected.           |
| `name` missing or empty                                        | The instance name is used as the name.                                             |
| Several results with the same `id` (one per network interface) | Merged into one device. Connections use the endpoint of the first result received. |
| A result disappears                                            | The device leaves the Nearby list at once and its online status is recomputed.     |

When the browser fails with `kDNSServiceErr_PolicyDenied` (-65570), the local network permission is denied ([Local network permission](#local-network-permission)). A browser that fails, for this or any other reason, is cancelled and logged, its results are dropped so that the Nearby list empties and online statuses are recomputed, and browsing starts again 5 s later. The interpretation rules and the restart are Default chosen at design time.

TXT data is not authenticated. A device's identity is proven by the handshake and checked against the `welcome` ([Client checks](#client-checks)).

## Info.plist keys

The app's `Resources/Info.plist` declares the keys below; the bundle is assembled as described in [CI](ci.md). The Updater's Info.plist declares neither.

| Key                            | Type             | Value                                                                                                             |
| ------------------------------ | ---------------- | ----------------------------------------------------------------------------------------------------------------- |
| NSBonjourServices              | array of strings | `_hephaestus2._tcp`                                                                                               |
| NSLocalNetworkUsageDescription | string           | `HephaestusV2 uses the local network to find your other Macs running HephaestusV2 and to work on their projects.` |

The usage text is Default chosen at design time.

## Pairing

### Pairing code

| Property   | Rule                                                                                                                                                       |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Alphabet   | Crockford base32: `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (no I, L, O, U).                                                                                      |
| Length     | 16 characters, 80 bits.                                                                                                                                    |
| Generation | Each character drawn independently and uniformly from the alphabet with `SystemRandomNumberGenerator`. Default chosen at design time.                      |
| Created    | When `secrets.json` has no `pairingCode` at launch ([Data model](data-model.md#secrets-file)).                                                             |
| Stored     | In display form, `pairingCode` of the main device's `secrets.json`.                                                                                        |
| Display    | `XXXX-XXXX-XXXX-XXXX`: the 16 characters in four groups of four joined by `-`. Settings > Devices shows it with Copy and Regenerate ([UI](ui.md#devices)). |
| Access     | A local-only service ([Architecture](architecture.md#local-only-services)): no Engine API method or MCP tool reads or changes it.                          |

### Code normalization

Applied to every code a user types or pastes, and to a stored code before deriving `K`:

1. Remove every `-` and every whitespace character.
2. Uppercase ASCII letters.
3. Replace `O` with `0`, and `I` and `L` with `1` (the Crockford decoding aliases).
4. The result is valid when it has exactly 16 characters, all in the alphabet. Otherwise the code field shows `Pairing codes have 16 characters, shown as XXXX-XXXX-XXXX-XXXX.` and Connect stays disabled.

The normalized code is the input of [Key derivation](#key-derivation). A valid code is stored in display form, that is the normalized code with `-` after its 4th, 8th and 12th characters. Steps 3 and 4 are Default chosen at design time. Example: `7h0k 4xq2-m9ld tz5c` normalizes to `7H0K4XQ2M91DTZ5C` and is stored as `7H0K-4XQ2-M91D-TZ5C`.

### Regenerate

Regenerate in Settings > Devices, after its confirmation ([UI](ui.md#devices)), generates and saves a new code, closes every connection of the sync server (open sessions and handshakes in progress) with code 4003, and displays the new code. Every remote device then needs the new code ([Entering a new code](#entering-a-new-code)). When `secrets.json` cannot be written, the old code stays valid, no connection is closed, and Settings shows the alert `Regenerate failed` with the storage error's message. Default chosen at design time.

### Adding a device

"Add Device…" in the Device menu and in Settings > Devices opens the Add Device sheet: on the window whose Device menu was used, or on the Settings window.

| Element            | Behaviour                                                                                                                                                                      |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Nearby list        | Devices from `DeviceBrowser`, This Mac excluded, sorted by name. A row shows the name, plus "Paired" when the id is in `remotes.yml` or "Incompatible version" (row disabled). |
| Empty Nearby list  | `No Mac running HephaestusV2 was found on this network.`                                                                                                                       |
| Address field      | Label "Or enter an address", placeholder `studio.local:47821`. Typing in it deselects the list; selecting a row clears it. Syntax in [Address syntax](#address-syntax).        |
| Pairing code field | Placeholder `XXXX-XXXX-XXXX-XXXX`, SF Mono, [normalized](#code-normalization).                                                                                                 |
| Cancel             | Closes the sheet; an attempt in progress is closed with 1000.                                                                                                                  |
| Connect            | Default button. Enabled when a row is selected or the address parses, and the code is valid. Runs one attempt.                                                                 |

An attempt is one connection with the full handshake, without automatic retry. While it runs, the sheet shows a spinner and `Connecting…` and its fields are disabled.

| Outcome            | Result                                                                                                                                                                                                                                                                                                                                  |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `welcome` received | The record (id, name, host, port, lastConnected) and its code are saved, replacing a record with the same id. The attempt's connection becomes the device's connection; a connection the app already had to that device is closed with 1000. The sheet closes. A main window whose Device menu opened the sheet switches to the device. |
| Failure            | The sheet stays open with the [failure message](#messages) under the fields; Connect is enabled again; nothing is saved.                                                                                                                                                                                                                |
| Saving fails       | `welcome` received but the record or its code cannot be written: the attempt's connection is closed with 1000 and the sheet stays open with the storage error's message under the fields. Default chosen at design time.                                                                                                                |

Connecting through the sheet to a device that is already paired replaces its address and code; this is how a device is paired again after Regenerate. The sheet's layout and texts are Default chosen at design time.

### Address syntax

The address field is trimmed of whitespace and parsed as follows.

| Input form                       | Host                           | Port  |
| -------------------------------- | ------------------------------ | ----- |
| `[ipv6]`                         | The text between the brackets. | 47821 |
| `[ipv6]:port`                    | The text between the brackets. | port  |
| `host` (no colon)                | host                           | 47821 |
| `host:port` (one colon)          | host                           | port  |
| More than one colon, no brackets | The whole text (IPv6 literal). | 47821 |

The port is a decimal integer 1–65535. The host is not empty and contains no whitespace, `/`, `?` or `#`. Any other input shows `Enter a host name or address, optionally followed by :port.` and disables Connect. Default chosen at design time.

### Removing a device

Remove… in Settings > Devices asks for confirmation ([UI](ui.md#devices)). Removing closes the device's connection with 1000, deletes its `remotes.yml` record and its `remoteSecrets` entry ([Data model](data-model.md#secrets-file)), and switches every window that showed the device to This Mac. The device can be added again with its code.

### Entering a new code

When a connection reaches phase `needsPairing`, the user enters the device's current code through Add Device… (choosing the device in the Nearby list, or typing its address); the successful attempt replaces the stored code and becomes the device's connection. Reconnect Now in the reconnect view retries with the stored code. A paired device without a stored code (for example after `secrets.json` was deleted) starts in `needsPairing`. Default chosen at design time.

## Transport

### WebSocket

| Aspect             | Rule                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Endpoint           | `ws://<host>:<port>/` for a stored or typed address. Network.framework opens a client WebSocket only to a URL, not to a Bonjour service endpoint: for a discovered device the client first opens a TCP connection to the service endpoint, takes the IPv4 address and port of its remote endpoint, cancels it at once, then opens `ws://<IPv4 address>:<port>/`. The request path is `/`. |
| Version            | WebSocket version 13 (RFC 6455), `NWProtocolWebSocket` on both ends.                                                                                                                                                                                                                                                                                                                      |
| TLS                | None. Confidentiality and integrity come from [Frame sealing](#frame-sealing).                                                                                                                                                                                                                                                                                                            |
| Subprotocol        | None requested, none selected. Default chosen at design time.                                                                                                                                                                                                                                                                                                                             |
| Extensions         | None (no compression).                                                                                                                                                                                                                                                                                                                                                                    |
| Upgrade request    | The server accepts any request path and does not check upgrade headers.                                                                                                                                                                                                                                                                                                                   |
| IP version         | For a discovered device, both the resolving TCP connection and the WebSocket require IPv4 (`NWProtocolIP.Options.version = .v4`); the resolved address is the [device address](#device-address). Typed addresses use any IP version. Default chosen at design time.                                                                                                                       |
| Message boundaries | Each protocol message is exactly one complete WebSocket message.                                                                                                                                                                                                                                                                                                                          |
| Pings              | WebSocket ping and pong control frames with an empty payload. They are not encrypted and never counted as messages. Both ends answer pings automatically (`autoReplyPing`).                                                                                                                                                                                                               |

### Frame types per phase

| Phase                                             | Data frames allowed | A data frame of the other type |
| ------------------------------------------------- | ------------------- | ------------------------------ |
| Handshake: `hello`, `challenge`, `auth`           | text                | Close 1002.                    |
| After `auth`: `welcome` and every session message | binary              | Close 1002.                    |

### Message size limits

| Message                             | Maximum                   |
| ----------------------------------- | ------------------------- |
| Handshake text message              | 4,096 bytes               |
| Plaintext JSON of a session message | 33,554,432 bytes (32 MiB) |
| Binary frame (plaintext + 28 bytes) | 33,554,460 bytes          |

The 32 MB message limit is 32 MiB of plaintext JSON. A receiver closes with 1009 when a message exceeds the limit of its phase. Senders never send an oversized message ([Oversized messages](#oversized-messages)).

### JSON encoding

- Every message is one JSON object (RFC 8259) in UTF-8 without byte order mark, with a string field `type`.
- Senders encode messages with `EngineJSON.encoder()` ([Engine API](engine-api.md#enginejson)): compact, keys sorted, slashes not escaped. The plaintexts of the [worked example](#worked-example) are this encoder's output. Default chosen at design time.
- Receivers decode with `EngineJSON.decoder()`, accept any key order and any valid string escaping, and ignore unknown fields.
- `params`, `result` and the event envelope follow the [Engine API JSON encoding](engine-api.md#json-encoding). They travel as JSON values inside the message; a receiver that re-encodes one uses `EngineJSON.encoder()`, which writes integral numbers without fraction.
- Examples in this document are indented for reading.

## Cryptography

### Primitives

| Primitive         | Specification                                          | CryptoKit                                                                                                        |
| ----------------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| HKDF-SHA256       | RFC 5869, extract then expand                          | `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)`                                            |
| HMAC-SHA256       | RFC 2104                                               | `HMAC<SHA256>.authenticationCode(for:using:)`, `HMAC<SHA256>.isValidAuthenticationCode(_:authenticating:using:)` |
| ChaCha20-Poly1305 | RFC 8439 AEAD: 32-byte key, 12-byte nonce, 16-byte tag | `ChaChaPoly.seal(_:using:nonce:)`, `ChaChaPoly.open(_:using:)`                                                   |
| Random bytes      | Operating system CSPRNG                                | `SystemRandomNumberGenerator`                                                                                    |

### Byte strings

Labels are ASCII bytes without terminator, length prefix or separator. `‖` is byte concatenation.

| Name            | Bytes (hex)                                     | Length |
| --------------- | ----------------------------------------------- | ------ |
| code            | The normalized pairing code in ASCII.           | 16     |
| "hephaestus-v2" | 68 65 70 68 61 65 73 74 75 73 2d 76 32          | 13     |
| "pairing"       | 70 61 69 72 69 6e 67                            | 7      |
| "server"        | 73 65 72 76 65 72                               | 6      |
| "client"        | 63 6c 69 65 6e 74                               | 6      |
| "c2s"           | 63 32 73                                        | 3      |
| "s2c"           | 73 32 63                                        | 3      |
| nc              | Random, drawn by the client for this handshake. | 32     |
| ns              | Random, drawn by the server for this handshake. | 32     |

### Key derivation

All keys are HKDF-SHA256 outputs of 32 bytes.

| Key    | Input key material | Salt               | Info      |
| ------ | ------------------ | ------------------ | --------- |
| `K`    | code (16 bytes)    | "hephaestus-v2"    | "pairing" |
| `kC2S` | `K` (32 bytes)     | nc ‖ ns (64 bytes) | "c2s"     |
| `kS2C` | `K` (32 bytes)     | nc ‖ ns (64 bytes) | "s2c"     |

`K` depends only on the code. `kC2S` and `kS2C` are unique to one connection.

### Proofs

| Proof        | Sent in     | HMAC-SHA256 key | Message (70 bytes) |
| ------------ | ----------- | --------------- | ------------------ |
| Server proof | `challenge` | `K`             | "server" ‖ nc ‖ ns |
| Client proof | `auth`      | `K`             | "client" ‖ nc ‖ ns |

Proofs are 32 bytes. Receivers compare them in constant time (`isValidAuthenticationCode`).

### Base64

`nonce` and `proof` values are standard base64 (RFC 4648 section 4, alphabet `A–Z a–z 0–9 + /`) with `=` padding and no line breaks; 32 bytes are 44 characters. Receivers decode with `Data(base64Encoded:)` without options and require exactly 32 bytes. Any other form (URL-safe alphabet, missing padding, whitespace, another length) is a protocol error, close 1002.

### Frame sealing

Each direction has its own key and its own message counter, both specific to the connection.

| Direction        | Key    | First counter           |
| ---------------- | ------ | ----------------------- |
| Server to client | `kS2C` | 0 (the `welcome`)       |
| Client to server | `kC2S` | 0 (the first `request`) |

Counters start at 0. Default chosen at design time.

Binary frame layout:

| Offset | Length | Content                                |
| ------ | ------ | -------------------------------------- |
| 0      | 4      | `00 00 00 00`                          |
| 4      | 8      | Counter, unsigned 64-bit big-endian.   |
| 12     | n      | Ciphertext; n is the plaintext length. |
| 12 + n | 16     | Poly1305 tag.                          |

Bytes 0–11 are the ChaCha20-Poly1305 nonce. The plaintext is the JSON of the message. The frame equals CryptoKit's `ChaChaPoly.SealedBox.combined` of `ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: bytes0to11))`. There is no additional authenticated data. Default chosen at design time.

The sender adds 1 to its counter after every frame and seals frames in the order it writes them to the connection. A counter is never used twice with the same key: a side whose next counter would be 2^64 closes the connection with 1000 instead.

### Receiving a frame

The receiver keeps the next expected counter of the direction, starting at 0, and checks every binary frame in this order.

| Step | Check                                                                       | On failure                 |
| ---- | --------------------------------------------------------------------------- | -------------------------- |
| 1    | Length is at least 28 bytes.                                                | Close 4004.                |
| 2    | Bytes 0–3 are zero.                                                         | Close 4004.                |
| 3    | The counter in bytes 4–11 equals the expected counter.                      | Close 4005.                |
| 4    | `ChaChaPoly.open` succeeds.                                                 | Close 4004.                |
| 5    | The expected counter becomes counter + 1; the plaintext is a valid message. | Close 1002 when it is not. |

A replayed, reordered, dropped or modified frame therefore ends the connection.

### Security properties

| Property                      | Mechanism                                                                                                                                                           |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Mutual authentication         | Each side proves knowledge of `K` with an HMAC over both nonces. The client sends its proof only after the server's proof verified.                                 |
| Keys per connection           | `kC2S` and `kS2C` depend on nc and ns, drawn at random for every connection.                                                                                        |
| Confidentiality and integrity | ChaCha20-Poly1305 on every message after `auth`.                                                                                                                    |
| Replay and reordering         | Strict counters inside a connection; fresh nonces make a recorded handshake useless for a new connection.                                                           |
| Guessing                      | The code has 80 bits of entropy. The server does not limit authentication attempts. Default chosen at design time.                                                  |
| No forward secrecy            | Anyone who learns a pairing code and recorded a session made with it can decrypt that session. Regenerate protects later sessions only.                             |
| Rights                        | An authenticated remote device has the full rights of the user on the main device. Keeping the code secret is the only protection; Regenerate revokes every device. |
| Secrets at rest               | Pairing codes are stored only in `secrets.json` (mode 0600). `K`, session keys, nonces, proofs and decrypted messages are never written to disk or to logs.         |

## Handshake

### Sequence

```
Remote device (client)                                Main device (server)
  TCP connect, WebSocket upgrade (GET /)  ──────────▶   accept; hello deadline 10 s
  text    hello {protocol 1, deviceID, deviceName,
                 appVersion, nonce: nc}   ──────────▶   checks; ns = 32 random bytes
                                          ◀──────────   text    challenge {nonce: ns,
                                                                 proof: HMAC(K, "server" ‖ nc ‖ ns)}
  verify the server proof; derive kC2S, kS2C
  text    auth {proof: HMAC(K, "client" ‖ nc ‖ ns)}
                                          ──────────▶   verify the client proof; derive kC2S, kS2C;
                                                        close an older session of deviceID (4008);
                                                        subscribe to engine events; build the snapshot
                                          ◀──────────   binary  s2c #0  welcome {device, snapshot}
  phase connected; keepalive starts       ◀──────────   binary  s2c #1, #2 …  events and responses
  binary  c2s #0, #1 …  requests          ──────────▶
```

### hello

Client to server, text frame, sent as soon as the WebSocket is open.

| Field      | Type    | Value                                                           |
| ---------- | ------- | --------------------------------------------------------------- |
| type       | string  | `hello`                                                         |
| protocol   | integer | `1`                                                             |
| deviceID   | string  | The client's device id, uppercase canonical UUID.               |
| deviceName | string  | The client's device name, not empty.                            |
| appVersion | string  | The client's `CFBundleShortVersionString`, for example `0.4.0`. |
| nonce      | string  | Base64 of nc.                                                   |

```json
{
  "appVersion": "0.4.0",
  "deviceID": "6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C",
  "deviceName": "MacBook",
  "nonce": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
  "protocol": 1,
  "type": "hello"
}
```

### challenge

Server to client, text frame.

| Field | Type   | Value                       |
| ----- | ------ | --------------------------- |
| type  | string | `challenge`                 |
| nonce | string | Base64 of ns.               |
| proof | string | Base64 of the server proof. |

```json
{
  "nonce": "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=",
  "proof": "cQpkmCMXJWkVibDhSVYhOrADuuHpqr3ufQtH0J/qEiE=",
  "type": "challenge"
}
```

### auth

Client to server, text frame, sent only after the server proof verified.

| Field | Type   | Value                       |
| ----- | ------ | --------------------------- |
| type  | string | `auth`                      |
| proof | string | Base64 of the client proof. |

```json
{
  "proof": "2tpoAg64gfc2YJLkhuuS4oYl3GOVG6KB6xBrSeDDrCM=",
  "type": "auth"
}
```

### welcome

Server to client, the first binary frame (s2c counter 0).

| Field    | Type       | Value                                                                                        |
| -------- | ---------- | -------------------------------------------------------------------------------------------- |
| type     | string     | `welcome`                                                                                    |
| device   | DeviceInfo | The main device, as `device.info` returns it.                                                |
| snapshot | Snapshot   | Built after the session's event subscription started ([Engine API](engine-api.md#snapshot)). |

```json
{
  "device": {
    "appVersion": "0.4.0",
    "build": 57,
    "id": "9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6",
    "name": "Studio",
    "protocolVersion": 1
  },
  "snapshot": {
    "claude": {"available": true, "checking": false, "path": "/opt/homebrew/bin/claude", "version": "2.1.309"},
    "device": {
      "appVersion": "0.4.0",
      "build": 57,
      "id": "9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6",
      "name": "Studio",
      "protocolVersion": 1
    },
    "projects": [
      {
        "id": "HEPH",
        "name": "Hephaestus V2",
        "rootPath": "/Users/example/Developer/HephaestusV2",
        "subprojectIDs": [],
        "ticketCounts": {"done": 8, "inProgress": 1, "todo": 3}
      }
    ],
    "runs": [],
    "settings": {
      "autoUpdate": true,
      "claudePath": null,
      "defaultChatSettings": {"effort": "high", "model": "default", "permissionMode": "manual", "ultracode": false},
      "feedbackProjectID": null,
      "formatGoOnSave": true,
      "formatSwiftOnSave": false,
      "mcpPort": 47820,
      "schema": 1,
      "skillsLibraryPath": null,
      "syncEnabled": true,
      "syncPort": 47821,
      "updateCheckIntervalMinutes": 30
    },
    "skills": [
      {"description": "Write and run tests with Swift Testing.", "name": "swift-testing"}
    ]
  },
  "type": "welcome"
}
```

### Server checks

The first data frame is checked in this order; the first failure closes the connection without any reply message.

| Step | Check                                                                 | Close code                 |
| ---- | --------------------------------------------------------------------- | -------------------------- |
| 1    | Text frame of at most 4,096 bytes.                                    | 1002 (binary), 1009 (size) |
| 2    | JSON object with `type` `hello`.                                      | 1002                       |
| 3    | `protocol` is an integer.                                             | 1002                       |
| 4    | `protocol` equals 1.                                                  | 4001                       |
| 5    | `deviceID` is a UUID string in any letter case; it is kept uppercase. | 1002                       |
| 6    | `deviceName` is a non-empty string and `appVersion` is a string.      | 1002                       |
| 7    | `nonce` decodes to 32 bytes.                                          | 1002                       |
| 8    | `deviceID` differs from the server's own device id.                   | 4007                       |

`protocol` is checked before the other fields so that a client of another protocol version receives 4001 whatever the shape of its `hello`. The server then draws ns, derives `K` from its current pairing code and sends the `challenge`.

The second data frame is checked in this order.

| Step | Check                                                                  | Close code                 |
| ---- | ---------------------------------------------------------------------- | -------------------------- |
| 1    | Text frame of at most 4,096 bytes.                                     | 1002 (binary), 1009 (size) |
| 2    | JSON object with `type` `auth` and a `proof` that decodes to 32 bytes. | 1002                       |
| 3    | `proof` equals the client proof (constant time).                       | 4002                       |

The server then derives `kC2S` and `kS2C`, closes the older open session with the same device id (4008), subscribes the session to engine events and buffers them, builds the snapshot (a failure closes the connection with 1011), sends the `welcome` as s2c #0, then sends the buffered events in order, and the session is open ([Welcome snapshot](#welcome-snapshot)).

### Client checks

| Message            | Check                                                                                                           | On failure                                                  |
| ------------------ | --------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `challenge`        | Text frame of at most 4,096 bytes; JSON object with `type` `challenge`; `nonce` and `proof` decode to 32 bytes. | Close 1002.                                                 |
| `challenge`        | `proof` equals the server proof (constant time).                                                                | Close 4002 without sending `auth`; phase `needsPairing`.    |
| First binary frame | [Receiving a frame](#receiving-a-frame) with expected counter 0.                                                | Close 4004 or 4005.                                         |
| First binary frame | JSON object with `type` `welcome`; `device` and `snapshot` decode.                                              | Close 1002.                                                 |
| `welcome`          | When the expected device id is known (paired device, or Bonjour row in Add Device): `device.id` equals it.      | Close 1000; failure `Another device answered at <address>.` |

## Session messages

| type     | Direction       | Purpose                      |
| -------- | --------------- | ---------------------------- |
| request  | client → server | Calls one Engine API method. |
| response | server → client | Answers one request.         |
| event    | server → client | Delivers one engine event.   |

### request

| Field  | Type    | Value                                                                                                                   |
| ------ | ------- | ----------------------------------------------------------------------------------------------------------------------- |
| type   | string  | `request`                                                                                                               |
| id     | integer | 1 to 9,007,199,254,740,991, unique among the requests of the connection. The client starts at 1 and adds 1 per request. |
| method | string  | An Engine API method name, `<area>.<verb>`.                                                                             |
| params | object  | The method's params; `{}` for a method without params.                                                                  |

```json
{
  "id": 3,
  "method": "webTabs.close",
  "params": {"projectID": "HEPH", "tabID": "7C9E6679-7425-40DE-944B-E07FC1F90AE7"},
  "type": "request"
}
```

### response

| Field  | Type     | Value                                                                    |
| ------ | -------- | ------------------------------------------------------------------------ |
| type   | string   | `response`                                                               |
| id     | integer  | The id of the request answered.                                          |
| result | any JSON | On success: the method's result (`{}` for [Empty](engine-api.md#empty)). |
| error  | object   | On failure: [EngineError](engine-api.md#engineerror) `{code, message}`.  |

Exactly one of `result` and `error` is present; otherwise the client closes with 1002.

```json
{
  "error": {"code": "forbidden", "message": "This tab is locked."},
  "id": 3,
  "type": "response"
}
```

```json
{
  "id": 1,
  "result": {},
  "type": "response"
}
```

### event

| Field | Type   | Value                                                                            |
| ----- | ------ | -------------------------------------------------------------------------------- |
| type  | string | `event`                                                                          |
| event | object | [EngineEventEnvelope](engine-api.md#engineeventenvelope) `{name, origin, data}`. |

```json
{
  "event": {
    "data": {"projectID": "HEPH", "ticketID": "HEPH-12"},
    "name": "ticket.deleted",
    "origin": {"actor": "user", "deviceID": "6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C"}
  },
  "type": "event"
}
```

The engine encodes each envelope once ([Engine API](engine-api.md#dispatcher)); the server builds the message from those bytes as `{"event":` + envelope + `,"type":"event"}`, which equals the sorted-key encoding.

### Request handling

- The server closes with 1002 a request whose `id` is missing, not an integer or out of range, whose `method` is not a string, or whose `params` is present and is neither an object nor null; an absent or null `params` is dispatched as `{}` ([Engine API](engine-api.md#json-encoding)).
- Otherwise it calls `Engine.dispatch(method:params:actor:)` with `params` as JSON data and the actor `user` carrying the session's device id. Remote users have exactly the rights of local users. An unknown method or invalid params produce the [dispatcher's error](engine-api.md#dispatcher-errors) as the response.
- Requests start in the order they are received and run concurrently; each response is sent when its request completes, so responses can arrive in another order than their requests. A client that needs one request applied before another waits for the first response before sending the second.
- Requests have no timeout of their own: they end with their response or with the connection.
- The name the engine shows for a remote device (for example the `sender` of a chat `user` item) is the `deviceName` of its last `hello` since launch. A `user` actor of a device that has not connected since launch, which only tests and the system produce, is named by its device id. Default chosen at design time.
- The client sends no request before the `welcome`.

### Event delivery

- Every event the engine emits is sent to every open session, in emission order, without filtering. A client acts on a `ui.open` event as defined in [Engine API](engine-api.md#uiopen).
- Responses and events of a session share one FIFO send queue. The events the engine emitted while handling a request are queued before that request's response ([Engine API](engine-api.md#delivery-and-ordering)).
- When a session's send queue holds more than 67,108,864 bytes (64 MiB) of unsent frames, the server closes it with 4009; the client reconnects and reloads. Default chosen at design time.

### Errors produced by the connection

`RemoteEngineConnection` fails a call without an answer from the main device in these cases; `<name>` is the paired device's name.

| Case                                                    | code          | message                             |
| ------------------------------------------------------- | ------------- | ----------------------------------- |
| Call made while the phase is not `connected`.           | `unavailable` | `Not connected to <name>.`          |
| The connection ends before the response.                | `unavailable` | `Not connected to <name>.`          |
| The encoded request is larger than 33,554,432 bytes.    | `invalid`     | `The request is larger than 32 MB.` |
| The result does not decode as the method's result type. | `internal`    | `Unexpected result for <method>.`   |

Calls are never retried automatically. Whether a mutation in flight when the connection ended was applied shows in the data reloaded after the next `welcome`. The last two rows are Default chosen at design time.

### Oversized messages

| Message              | Sender's behaviour                                                                                                       |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Request over 32 MiB  | Not sent; the call fails with `invalid` ([Errors produced by the connection](#errors-produced-by-the-connection)).       |
| Response over 32 MiB | Replaced by the error `unavailable` `The result of <method> is larger than 32 MB and cannot be sent to a remote device.` |
| Event over 32 MiB    | Not sent to remote sessions and logged ([Logging](#logging)); local windows receive it.                                  |

The Engine API's own limits keep results and events under 32 MiB ([Limits](engine-api.md#limits)); these rules cover the cases those limits do not. Default chosen at design time.

### Unknown messages

After the `welcome`, a message with an unknown `type`, a known `type` in the wrong direction, or a `response` whose id matches no pending call is ignored and logged. The client ignores events with an unknown name, and events whose data does not decode as the event's type. During the handshake, any unexpected message closes the connection with 1002.

## Keepalive

| Rule                        | Value                                                                                                                                                   |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Who pings                   | The client, every 15 s from the `welcome`.                                                                                                              |
| Ping payload                | Empty.                                                                                                                                                  |
| Pong                        | Sent automatically by the server (`autoReplyPing`).                                                                                                     |
| Client dead-connection rule | At each ping tick, when nothing (message or pong) was received for 30 s, the client cancels the connection without a close frame and goes to `waiting`. |
| Server dead-connection rule | When nothing (message or ping) was received from an open session for 45 s, the server cancels it without a close frame.                                 |

Network.framework delivers incoming pings to receive requests even when it answers them automatically, so pings count as received frames on the server. Which side pings and both silence limits are Default chosen at design time.

## Timeouts and limits

| Name                      | Value                                                   | Side and effect             |
| ------------------------- | ------------------------------------------------------- | --------------------------- |
| Connect                   | 10 s from the start of the connection to WebSocket open | Client: failure, `waiting`. |
| Hello deadline            | 10 s from accepting the TCP connection                  | Server: close 4006.         |
| Challenge deadline        | 10 s after sending `hello`                              | Client: close 4006.         |
| Auth deadline             | 10 s after sending `challenge`                          | Server: close 4006.         |
| Welcome deadline          | 30 s after sending `auth`                               | Client: close 4006.         |
| Ping interval             | 15 s                                                    | Client.                     |
| Client silence limit      | 30 s                                                    | Client: cancel, `waiting`.  |
| Server silence limit      | 45 s                                                    | Server: cancel.             |
| Close wait                | 2 s                                                     | Both.                       |
| Backoff                   | 1, 2, 4, 8, 16, 30 s, then 30 s                         | Client.                     |
| Bind retries              | 5 attempts, 1 s apart                                   | Server.                     |
| Handshake message         | 4,096 bytes                                             | Both: close 1009.           |
| Session message plaintext | 33,554,432 bytes                                        | Both: close 1009.           |
| Send queue                | 67,108,864 bytes                                        | Server: close 4009.         |
| Request id                | 1 to 9,007,199,254,740,991                              | Client.                     |
| Counter                   | 0 to 2^64 − 1 per direction                             | Both.                       |

Every value in this table except the ping interval, the backoff and the 32 MiB message limit is Default chosen at design time. When the hello deadline expires before the WebSocket upgrade completed, the server cancels the TCP connection without a close frame.

## Close codes

| Code | Name                  | Sent by | When                                                                                                                                                                                                                                                                     | Client reaction                                                             |
| ---- | --------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| 1000 | Normal                | both    | Client: no window shows the device any more, the device is removed, the app quits, an Add Device attempt is cancelled, a successful Add Device attempt replaces this connection, or the `welcome` came from another device. Either side: its next counter would be 2^64. | `closed` when the app closed the connection; `waiting` in every other case. |
| 1001 | Going away            | server  | The server stops: the app quits, remote access is turned off, or the port changed.                                                                                                                                                                                       | `waiting`                                                                   |
| 1002 | Protocol error        | both    | Malformed or unexpected message, wrong frame type, invalid base64.                                                                                                                                                                                                       | `waiting`                                                                   |
| 1009 | Message too big       | both    | A message exceeds the limit of its phase.                                                                                                                                                                                                                                | `waiting`                                                                   |
| 1011 | Internal error        | server  | Building the snapshot failed.                                                                                                                                                                                                                                            | `waiting`                                                                   |
| 4001 | Unsupported protocol  | server  | `hello.protocol` is not 1.                                                                                                                                                                                                                                               | `waiting`                                                                   |
| 4002 | Authentication failed | both    | A proof did not verify.                                                                                                                                                                                                                                                  | `needsPairing`                                                              |
| 4003 | Pairing code changed  | server  | Regenerate on the main device.                                                                                                                                                                                                                                           | `needsPairing`                                                              |
| 4004 | Decryption failed     | both    | A frame shorter than 28 bytes, a non-zero nonce prefix, or a failed tag check.                                                                                                                                                                                           | `waiting`                                                                   |
| 4005 | Unexpected counter    | both    | The frame counter differs from the expected counter.                                                                                                                                                                                                                     | `waiting`                                                                   |
| 4006 | Handshake timeout     | both    | A handshake deadline expired.                                                                                                                                                                                                                                            | `waiting`                                                                   |
| 4007 | Same device           | server  | `hello.deviceID` is the server's own device id.                                                                                                                                                                                                                          | `sameDevice`                                                                |
| 4008 | Replaced              | server  | A newer session with the same device id authenticated.                                                                                                                                                                                                                   | `replaced`                                                                  |
| 4009 | Too slow              | server  | The session's send queue exceeds 64 MiB.                                                                                                                                                                                                                                 | `waiting`                                                                   |

Codes 1000–1011 are RFC 6455 codes; 4001–4009 are private codes of this protocol. Close frames carry the code and an empty reason, because Network.framework exposes no close reason text; receivers act on the code only. A connection that ends without a close frame (network failure, cancellation by the peer) counts as 1006 and leads to `waiting`. The private codes and every reaction in this table are Default chosen at design time.

### Closing a connection

The closing side sends a close frame with its code, then cancels the connection when the peer's close frame arrives or after 2 s. A side that receives a close frame cancels its connection. No frame is processed after a close frame was sent or received.

Network.framework answers a received close frame by itself, before the app has read it, so the closing side can end the TCP connection first. The receiving side's connection then fails, and its pending receive delivers the close frame together with that error. A connection that fails while a receive is pending ends when that receive completes, and a close frame delivered with an error counts as received: its code, not 1006, decides the phase.

## Client state machine

### Phases

`RemoteEngineConnection` exposes a detailed `phase` of type `RemoteConnectionPhase`, and `phaseUpdates`, a stream of the current phase and every change. The `waiting` case carries the message and the date of the next attempt; `needsPairing`, `sameDevice` and `replaced` carry their message. `nextAttempt` reads that date from the phase: nil unless the phase is `waiting`. `EngineConnection.state` ([Engine API](engine-api.md#engineconnection)) is derived from the phase; the message of a disconnected phase is the `reason` of `disconnected(reason:)`.

| Phase          | EngineConnection.state | Retry scheduled | Meaning                                                          |
| -------------- | ---------------------- | --------------- | ---------------------------------------------------------------- |
| `connecting`   | `connecting`           | —               | TCP and WebSocket are being opened.                              |
| `helloSent`    | `connecting`           | —               | `hello` sent, waiting for `challenge`.                           |
| `authSent`     | `connecting`           | —               | `auth` sent, waiting for `welcome`.                              |
| `connected`    | `connected`            | —               | The session is open.                                             |
| `waiting`      | `disconnected`         | yes             | Waiting for the next attempt; carries the last error message.    |
| `needsPairing` | `disconnected`         | no              | The stored code was refused or changed, or there is none.        |
| `sameDevice`   | `disconnected`         | no              | The address belongs to this Mac.                                 |
| `replaced`     | `disconnected`         | no              | The main device accepted a newer connection with this device id. |
| `closed`       | `disconnected`         | no              | Closed by the app, with the message `Closed.`; final.            |

The status bar and the reconnect view show `Connecting…`, `Reconnecting…` or `Offline` from the state, the retry column and whether the workspace has been connected before ([UI](ui.md#status-bar)). The phases are Default chosen at design time.

### Transitions

| From                                                | Event                                                                          | Action                                                                                                 | To             |
| --------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ | -------------- |
| new                                                 | open                                                                           | Choose the endpoint; start the connection; start the 10 s connect timer.                               | `connecting`   |
| `connecting`                                        | WebSocket open                                                                 | Draw nc; send `hello`; start the 10 s challenge timer.                                                 | `helloSent`    |
| `connecting`                                        | Failure or connect timeout                                                     | Record the failure message.                                                                            | `waiting`      |
| `helloSent`                                         | Valid `challenge` with a verified proof                                        | Send `auth`; derive `kC2S` and `kS2C`; start the 30 s welcome timer.                                   | `authSent`     |
| `helloSent`                                         | `challenge` proof does not verify                                              | Close 4002.                                                                                            | `needsPairing` |
| `helloSent`, `authSent`                             | Close 4002 or 4003 received                                                    | None.                                                                                                  | `needsPairing` |
| `helloSent`                                         | Close 4007 received                                                            | None.                                                                                                  | `sameDevice`   |
| `authSent`                                          | `welcome` from the expected device                                             | Keep the snapshot; set `deviceInfo`; reset the backoff; update the paired record; start the keepalive. | `connected`    |
| `authSent`                                          | `welcome` from another device                                                  | Close 1000; record the failure message.                                                                | `waiting`      |
| `connected`                                         | Close 4002 or 4003 received                                                    | Fail pending calls.                                                                                    | `needsPairing` |
| `connected`                                         | Close 4008 received                                                            | Fail pending calls.                                                                                    | `replaced`     |
| `connecting`, `helloSent`, `authSent`, `connected`  | Any other close, network failure, timeout or failed check                      | Fail pending calls; when the connection is still open, close with the code of the failed check.        | `waiting`      |
| `waiting`                                           | Backoff delay elapsed                                                          | Start the connection.                                                                                  | `connecting`   |
| `waiting`, `needsPairing`, `sameDevice`, `replaced` | Reconnect Now                                                                  | Reset the backoff; start the connection. Without a stored code the phase stays `needsPairing`.         | `connecting`   |
| any except `closed`                                 | close by the app, including the replacement by a successful Add Device attempt | Close 1000 when open; fail pending calls; finish every stream.                                         | `closed`       |

Reconnect Now does nothing in `connecting`, `helloSent` and `authSent`. The endpoint of each attempt is the current Bonjour result whose TXT `id` is the device id when one exists, otherwise the stored host and port.

### Backoff

The delays before successive attempts are 1, 2, 4, 8, 16 and 30 seconds, then 30 seconds for every later attempt, without jitter. The sequence restarts at 1 s after a `welcome` and after Reconnect Now.

### Pending calls

When the phase leaves `connected`, every call waiting for a response fails, and a call made in any other phase fails at once, with the errors of [Errors produced by the connection](#errors-produced-by-the-connection). The `events` and `stateUpdates` streams of a `RemoteEngineConnection` span reconnections and finish only in phase `closed`.

## Server connection states

| State          | Event                                   | Action                                                                                                                                 | Next           |
| -------------- | --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| `accepted`     | Valid `hello` within 10 s of the accept | Draw ns; send `challenge`; start the 10 s auth timer.                                                                                  | `awaitingAuth` |
| `accepted`     | Invalid `hello`                         | Close with the code of the failed check.                                                                                               | `closed`       |
| `accepted`     | 10 s elapsed                            | Close 4006, or cancel without a close frame when the upgrade is not complete.                                                          | `closed`       |
| `awaitingAuth` | Valid `auth`                            | Derive keys; close the older session (4008); subscribe to engine events; build the snapshot; send `welcome`; send the buffered events. | `open`         |
| `awaitingAuth` | Malformed `auth`, or proof not verified | Close 1002, or 4002.                                                                                                                   | `closed`       |
| `awaitingAuth` | 10 s elapsed                            | Close 4006.                                                                                                                            | `closed`       |
| `open`         | `request`                               | Dispatch it.                                                                                                                           | `open`         |
| `open`         | Failed frame or message check           | Close 4004, 4005, 1002 or 1009.                                                                                                        | `closed`       |
| `open`         | Nothing received for 45 s               | Cancel.                                                                                                                                | `closed`       |
| `open`         | Send queue over 64 MiB                  | Close 4009.                                                                                                                            | `closed`       |
| `open`         | A newer session with the same device id | Close 4008.                                                                                                                            | `closed`       |
| any            | Regenerate                              | Close 4003.                                                                                                                            | `closed`       |
| any            | The server stops                        | Close 1001.                                                                                                                            | `closed`       |
| any            | Close frame received or network failure | Cancel.                                                                                                                                | `closed`       |

In `closed`, the session's event subscription ends. Requests still running complete on the engine and their responses are discarded.

## Snapshot and event replay

The server keeps no event history. A session starts from the snapshot of its `welcome` and continues with every event emitted after its subscription started, in emission order ([Architecture](architecture.md#event-subscriptions)).

### Welcome snapshot

- **Server.** After a valid `auth`, the server subscribes the session to engine events (`Engine.subscribe()`, [Engine API](engine-api.md#dispatcher)) and buffers them, builds the snapshot as `snapshot.get` does, sends the `welcome`, then sends the buffered events in order. The engine emits each event after the change it describes is applied, so every change made before the subscription is in the snapshot and every change made after it arrives as an event. An event emitted between the subscription and the snapshot is in both; applying it again changes nothing ([Event kinds](#event-kinds)).
- **Client.** `RemoteEngineConnection` sets `deviceInfo` from `welcome.device` and keeps `welcome.snapshot`. The first `snapshot.get` after a `welcome` returns that snapshot without a round trip; later calls go to the main device ([Engine API](engine-api.md#engineconnection)). Events received after a `welcome` are held and yielded on `events` only once that first `snapshot.get` has returned, in their order of arrival, so a client that applies the snapshot when the call returns applies every later event after it. Held events are discarded when the connection is lost before that call. Default chosen at design time.
- **Workspace.** `DeviceWorkspace` stores the snapshot each time its state becomes `connected` ([UI](ui.md#deviceworkspace)). The local workspace, whose subscription starts when `LocalEngineConnection` is created, seeds the same state with a `snapshot.get` call under the [replay rule](#seeding-calls-and-the-replay-rule).

### Event kinds

| Kind   | Events                                                                                                                                                                                                                                                                                                   | Applying the same event twice                                                                                         |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| State  | `projects.changed`, `project.updated`, `project.removed`, `ticket.updated`, `ticket.deleted`, `bundle.updated`, `bundle.deleted`, `chat.updated`, `chat.deleted`, `chat.item`, `files.changed`, `webTabs.updated`, `skills.changed`, `run.started`, `run.finished`, `settings.updated`, `claude.updated` | Same result: each carries the complete new value of what it names, a deletion, or (`files.changed`) a reload request. |
| Stream | `chat.delta`, `run.output`                                                                                                                                                                                                                                                                               | Appends twice: applied once, on arrival.                                                                              |
| Action | `ui.open`                                                                                                                                                                                                                                                                                                | Acts twice: applied once, on arrival.                                                                                 |

### Seeding calls and the replay rule

A seeding call is a call whose result replaces a whole part of a client's cached data: `snapshot.get`, `projects.get`, `tickets.list`, `bundles.list`, `chats.list`, `webTabs.list`, `chats.get`, and the list and file reads that section documents name ([UI](ui.md#deviceworkspace)).

1. While a seeding call is in flight, the state events that change the data it returns are queued.
2. When the result arrives, it replaces that data, then the queued events are applied in arrival order.
3. When the call fails, the queued events are applied to the data as it is and the error is shown to the view that made the call.

Stream and action events are never queued. Mutation results are not written into caches: every mutation emits an event that updates every client, and the caller uses the result only for its own flow, for example selecting the ticket it created ([Architecture](architecture.md#events-and-ordering)). With these rules the relative order of responses and events does not matter, and they apply to both connection kinds. Default chosen at design time.

### After a reconnect

1. Events emitted while the remote device was disconnected are lost for it.
2. After the next `welcome`, device-level state is replaced by its snapshot, and the loaded projects and shown transcripts are loaded again with seeding calls ([UI](ui.md#deviceworkspace)).
3. Window state (selections, editor buffers) and the workspace's composer drafts are kept.
4. Stream content emitted while disconnected is not recovered: a chat shows its persisted items, then the deltas received after the reconnection; the console shows the run output received after it ([Console](projects.md#console)).

## Localhost rewrite

Web tabs are loaded by the WKWebView of the Mac whose window shows them ([Web tabs](web-tabs.md)). A window that shows a remote device rewrites URLs that point to the loopback interface so that they reach the main device.

### Device address

| Connection made through | Device address                                                                                        |
| ----------------------- | ----------------------------------------------------------------------------------------------------- |
| A stored or typed host  | The host as stored; an IPv6 literal is written in brackets in URLs.                                   |
| Bonjour                 | The IPv4 address of the connection's remote endpoint (connections to Bonjour endpoints require IPv4). |

The device address is the one of the current connection. While a device is not connected, its windows show the reconnect view and load no page.

### Forward rewrite

A window that shows a remote device applies the rewrite to the URL it loads when a tab is shown and to every navigation of the tab's web view (main frame and frames): when the scheme is `http` or `https` and the host, compared case-insensitively, is `localhost`, `127.0.0.1` or `::1` (written `[::1]` in URLs), the host is replaced by the device address. Scheme, user info, port, path, query and fragment are kept; no port is added to a URL without one. Other URLs are loaded unchanged. Subresource requests (images, scripts, `fetch`) are not rewritten. The navigation coverage is Default chosen at design time.

| Stored URL                            | Device address | Loaded URL                               |
| ------------------------------------- | -------------- | ---------------------------------------- |
| `http://localhost:3000/app?tab=2#top` | `192.168.1.20` | `http://192.168.1.20:3000/app?tab=2#top` |
| `https://127.0.0.1:8443/`             | `studio.local` | `https://studio.local:8443/`             |
| `http://[::1]:8080/`                  | `192.168.1.20` | `http://192.168.1.20:8080/`              |
| `http://LocalHost/`                   | `192.168.1.20` | `http://192.168.1.20/`                   |
| `http://[::1]:8080/`                  | `2001:db8::5`  | `http://[2001:db8::5]:8080/`             |
| `http://app.localhost:3000/`          | `192.168.1.20` | `http://app.localhost:3000/` (unchanged) |
| `https://github.com/`                 | `192.168.1.20` | `https://github.com/` (unchanged)        |

Windows that show This Mac never rewrite. The stored URL is unchanged, and the address bar of a remote window shows the stored URL. The address bar rule is Default chosen at design time.

### Reverse rewrite

When a remote window reports a tab's new URL after a navigation (`webTabs.update` with `url`), and the new URL's host equals the device address (case-insensitive; IPv6 compared without brackets) while the host of the tab's stored URL is `localhost`, `127.0.0.1` or `[::1]`, the URL sent is the new URL with its host replaced by the stored URL's host. Otherwise the new URL is sent unchanged. Example: stored `http://localhost:3000/`, the page navigates to `http://192.168.1.20:3000/login`, and `http://localhost:3000/login` is stored. A popup stored with `webTabs.open` ([Popups](web-tabs.md#popups)) has no stored URL yet: the stored URL of its opener's tab, the nearest stored tab in its chain of openers, is the reference. Default chosen at design time.

## Remote windows

| Feature                                                                                             | Window that shows a remote device                                                                                                                        |
| --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Projects, tickets, bundles, chats, files, docs, search, skills, runs                                | The same Engine API calls as a local window, executed by the main device. Claude processes, the MCP server and project files stay on the main device.    |
| Web pages                                                                                           | Loaded by this Mac's WKWebView with this Mac's website data store (its own logins), with the [localhost rewrite](#localhost-rewrite).                    |
| Feedback screenshot                                                                                 | Taken on this Mac and sent inside `chats.createFeedback` ([Feedback](feedback.md)).                                                                      |
| Files dropped, pasted or picked                                                                     | Read on this Mac and sent as AttachmentUpload (base64) inside the request ([Tickets and bundles](tickets.md)).                                           |
| Folder choice in New Project and Open Project                                                       | A folder browser over `fs.browse` of the main device instead of the system open panel ([Projects](projects.md)).                                         |
| Settings window                                                                                     | Always This Mac's settings ([UI](ui.md#settings-window)).                                                                                                |
| Commands that show a project file or folder in this Mac's Finder (Show in Finder, Reveal in Finder) | Hidden. Commands that open a temporary copy of a file or attachment on this Mac (Quick Look, Open With Default App) stay. Default chosen at design time. |
| Menus, keyboard shortcuts, windows                                                                  | Identical to local windows ([UI](ui.md)).                                                                                                                |

## Failure states

### Reconnect view

While the device of a window is not connected, the window shows the reconnect view with `Reconnect Now` and `Show This Mac` ([UI](ui.md#empty-states)). Its reason text is the message of the current phase, from the table below.

### Messages

The message of a failure is the `reason` of the connection's `disconnected` state and, for an Add Device attempt, the text shown in the sheet. `<name>` is the device name, or the address while the name is unknown; `<address>` is `host:port`. The messages are Default chosen at design time.

| Cause                           | Detection                                                                | Message                                                                                                                    | Phase          |
| ------------------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- | -------------- |
| Local network permission denied | Connection path unsatisfied with reason `localNetworkDenied`.            | `HephaestusV2 is not allowed to use the local network. Allow it in System Settings > Privacy & Security > Local Network.`  | `waiting`      |
| Host name not found             | DNS resolution error.                                                    | `Can't find <host>.`                                                                                                       | `waiting`      |
| Connection refused              | `ECONNREFUSED`.                                                          | `<name> is not accepting connections. Check that remote devices are allowed in Settings > Devices on <name>.`              | `waiting`      |
| No answer                       | Connect timeout, `ETIMEDOUT`, `EHOSTUNREACH`, `ENETUNREACH`, `ENETDOWN`. | `Can't reach <name>.`                                                                                                      | `waiting`      |
| Handshake timeout               | Close 4006, or a client handshake deadline.                              | `<name> did not answer.`                                                                                                   | `waiting`      |
| Incompatible version            | Close 4001.                                                              | `<name> uses another version of the sync protocol. Update HephaestusV2 on both Macs.`                                      | `waiting`      |
| Wrong pairing code              | Server proof not verified, or close 4002.                                | `The pairing code for <name> is not correct. Choose Add Device… and enter the code shown in Settings > Devices on <name>.` | `needsPairing` |
| Code regenerated                | Close 4003.                                                              | `<name> has a new pairing code. Choose Add Device… and enter the code shown in Settings > Devices on <name>.`              | `needsPairing` |
| No stored code                  | No `remoteSecrets` entry for the device.                                 | `There is no pairing code for <name>. Choose Add Device… and enter the code shown in Settings > Devices on <name>.`        | `needsPairing` |
| This Mac                        | Close 4007.                                                              | `This address belongs to this Mac.`                                                                                        | `sameDevice`   |
| Another device answered         | `welcome.device.id` differs from the expected id.                        | `Another device answered at <address>.`                                                                                    | `waiting`      |
| Server stopped                  | Close 1001.                                                              | `<name> stopped accepting remote devices.`                                                                                 | `waiting`      |
| Connection lost                 | Silence limit, network failure, 1006.                                    | `The connection to <name> was lost.`                                                                                       | `waiting`      |
| Protocol failure                | Close 1002, 1009, 1011, 4004, 4005, 4009 or any other code.              | `The connection to <name> failed (code <n>).`                                                                              | `waiting`      |
| Replaced                        | Close 4008.                                                              | `This Mac opened a newer connection to <name>.`                                                                            | `replaced`     |

In the Add Device sheet, the two wrong-code causes show `The pairing code is not correct.` instead, and the sheet stays open whatever the cause.

### Local network permission

macOS shows its local network prompt for HephaestusV2 with the `NSLocalNetworkUsageDescription` text. While the permission is denied, `DeviceBrowser` reports `kDNSServiceErr_PolicyDenied` and the Add Device sheet shows the local network message above its empty Nearby list; connections fail with the local network message and keep retrying with the backoff, so they recover once the user allows the app.

## Settings on the main device

The Settings window always shows This Mac; the Devices tab is laid out in [UI](ui.md#devices). The effects of its controls on remote devices:

| Control              | Effect                                                                                                                  |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Device name          | [Device identity](#device-identity): new Bonjour name and TXT `name`; new name in later `hello` and `welcome` messages. |
| Regenerate…          | [Regenerate](#regenerate): every connection closed with 4003; every paired remote device needs the new code.            |
| Allow remote devices | Setting `syncEnabled`: the listener and the advertising start or stop ([Sync server](#sync-server)).                    |
| Port                 | Setting `syncPort`: the listener moves to the new port ([Sync server](#sync-server)).                                   |
| Paired devices       | The devices this Mac connects to as a remote device; Remove… as in [Removing a device](#removing-a-device).             |
| Add Device…          | [Adding a device](#adding-a-device).                                                                                    |

## Logging

The sync server and `RemoteEngineConnection` write these lines to `Logs/engine.log` with the component `sync`, in the format of [engine.log](architecture.md#enginelog). Default chosen at design time.

| Event                   | Level | Message                                                                                                                                                                                                          |
| ----------------------- | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Listener ready          | INFO  | `listening on port <port>`                                                                                                                                                                                       |
| Bind failed             | ERROR | `listener failed on port <port>: <error>`                                                                                                                                                                        |
| Session open            | INFO  | `<deviceName> (<deviceID>) connected from <address>, app <appVersion>`                                                                                                                                           |
| Handshake rejected      | WARN  | `handshake from <address> closed with <code>`                                                                                                                                                                    |
| Session closed          | INFO  | `<deviceName> (<deviceID>) disconnected, code <code>`                                                                                                                                                            |
| Event not sent          | WARN  | `event <name> of <bytes> bytes not sent to <deviceID>`                                                                                                                                                           |
| Unknown message ignored | WARN  | `ignored message type <type> from <deviceID>`                                                                                                                                                                    |
| Client attempt          | INFO  | `connecting to <name> at <address>`                                                                                                                                                                              |
| Client connected        | INFO  | `connected to <name>`                                                                                                                                                                                            |
| Client connection ended | INFO  | `connection to <name> ended, code <code>; next attempt in <n> s`; without `; next attempt in <n> s` for a phase that schedules no retry (`needsPairing`, `sameDevice`, `replaced`) and for an Add Device attempt |
| Browsing failed         | WARN  | `browsing failed: <error>`                                                                                                                                                                                       |

Pairing codes, `K`, session keys, nonces, proofs and message contents are never logged.

## Swift shape

Types in `Sources/HephaestusCore/Sync/`, tested in `Tests/HephaestusCoreTests/Sync/`.

| Type                         | Responsibility                                                                                                                                                                                                                                                                             |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `PairingCode`                | Generation, normalization (`init?(userInput:)`), `normalized`, `display`.                                                                                                                                                                                                                  |
| `SyncCrypto`                 | `pairingKey(code:)`, `serverProof(key:clientNonce:serverNonce:)`, `clientProof(key:clientNonce:serverNonce:)`, `sessionKeys(key:clientNonce:serverNonce:)` as in [Cryptography](#cryptography).                                                                                            |
| `FrameSealer`, `FrameOpener` | One key and one counter per direction; `seal(_:)` and `open(_:)`, with the errors `tooShort`, `badNoncePrefix`, `unexpectedCounter`, `authenticationFailed`.                                                                                                                               |
| `SyncMessage`                | Codable `hello`, `challenge`, `auth`, `welcome`, `request`, `response` and `event`; `params`, `result`, `snapshot` and `event` as [JSONValue](engine-api.md#jsonvalue).                                                                                                                    |
| `SyncCloseCode`              | The close codes of [Close codes](#close-codes).                                                                                                                                                                                                                                            |
| `SyncServer`                 | Listener, Bonjour advertising, sessions, server status with the open-session list, Regenerate, device name changes.                                                                                                                                                                        |
| `RemoteEngineConnection`     | `EngineConnection` to a paired device: `phase` (`RemoteConnectionPhase`, whose `waiting` case carries the next attempt date), `nextAttempt`, `phaseUpdates`, backoff, keepalive, the kept `welcome` snapshot, `reconnectNow()`, `close()`, and the single attempt of the Add Device sheet. |
| `DeviceBrowser`              | Bonjour browsing; discovered devices `{id, name, proto, endpoint}`; permission state.                                                                                                                                                                                                      |
| `PairedDevicesStore`         | `remotes.yml` records and their codes in `secrets.json`.                                                                                                                                                                                                                                   |

`RemoteEngineConnection`, `DeviceBrowser`, `PairedDevicesStore` and `PairingCode` are used by the UI: Device menu, Add Device sheet, Settings > Devices and reconnect view.

## Worked example

The tests in `Tests/HephaestusCoreTests/Sync/` reproduce every value of this section. Real handshakes draw nc and ns at random; the example fixes them.

### Inputs

```
pairing code (display)   7H0K-4XQ2-M91D-TZ5C
typed by the user as     7h0k 4xq2-m9ld tz5c
normalized code          7H0K4XQ2M91DTZ5C
code bytes               3748304b345851324d393144545a3543
nc                       000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
nc base64                AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=
ns                       202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f
ns base64                ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=
client                   device 6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C, name MacBook, app 0.4.0
server                   device 9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6, name Studio
```

### Derived values

```
K                     dffc53ef75ca2d84369e02d4c4c0d44a486d1c50ee9379409867952663353607
server proof message  736572766572000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f
server proof          710a6498231725691589b0e14956213ab003bae1e9aabdee7d0b47d09fea1221
server proof base64   cQpkmCMXJWkVibDhSVYhOrADuuHpqr3ufQtH0J/qEiE=
client proof message  636c69656e74000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f
client proof          dada68020eb881f7366092e486eb92e28625dc63951ba281eb106b49e0c3ac23
client proof base64   2tpoAg64gfc2YJLkhuuS4oYl3GOVG6KB6xBrSeDDrCM=
kC2S                  1944025e521f6b9807f9cd06bfd89dadfab329cf9228b62d84fff4548c98ea5c
kS2C                  b3f9caf68c6ebaa06e18f2503f39395b41c3dfaa09316422107e8de2ee7d91a1
```

### Handshake frames

The text frames of this handshake, as `EngineJSON.encoder()` writes them:

```
hello      {"appVersion":"0.4.0","deviceID":"6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C","deviceName":"MacBook","nonce":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","protocol":1,"type":"hello"}
challenge  {"nonce":"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=","proof":"cQpkmCMXJWkVibDhSVYhOrADuuHpqr3ufQtH0J/qEiE=","type":"challenge"}
auth       {"proof":"2tpoAg64gfc2YJLkhuuS4oYl3GOVG6KB6xBrSeDDrCM=","type":"auth"}
```

The `welcome` is s2c #0; its plaintext depends on the snapshot and is not fixed here.

### Encrypted frames

The first request of the session (c2s #0, key `kC2S`) and its response (s2c #1, key `kS2C`):

```
c2s #0 plaintext (111 bytes)
  {"id":1,"method":"chats.interrupt","params":{"chatID":"3F2504E0-4F89-11D3-9A0C-0305E82C3301"},"type":"request"}
c2s #0 nonce
  000000000000000000000000
c2s #0 ciphertext
  4d3e91efdf8a47d32b1bbf5845937f4fe3c85ea0f01fb09cbcf5fd4d5870a30bcca59e0f837a93975be061fa28090853c9fe13b709197cd1b74a69a09b08b7c2bd198572a87b86f2fd3a3a74f13910cd68b1f6bb9f1c6e3e557f6194e2d05c008f1c53b863c8eb739d62a31cebef73
c2s #0 tag
  33c7ee2a06ea7478f357229db6ac35a1
c2s #0 frame (139 bytes) = nonce ‖ ciphertext ‖ tag
  0000000000000000000000004d3e91efdf8a47d32b1bbf5845937f4fe3c85ea0f01fb09cbcf5fd4d5870a30bcca59e0f837a93975be061fa28090853c9fe13b709197cd1b74a69a09b08b7c2bd198572a87b86f2fd3a3a74f13910cd68b1f6bb9f1c6e3e557f6194e2d05c008f1c53b863c8eb739d62a31cebef7333c7ee2a06ea7478f357229db6ac35a1

s2c #1 plaintext (38 bytes)
  {"id":1,"result":{},"type":"response"}
s2c #1 nonce
  000000000000000000000001
s2c #1 ciphertext
  56067e70412b54e510ad3f01681acc0a26b64ab9c6763a0b4b1b6950212b5d3de460919ec024
s2c #1 tag
  bbc80aa4ba8c396b322802fa303443c3
s2c #1 frame (66 bytes) = nonce ‖ ciphertext ‖ tag
  00000000000000000000000156067e70412b54e510ad3f01681acc0a26b64ab9c6763a0b4b1b6950212b5d3de460919ec024bbc80aa4ba8c396b322802fa303443c3
```

### Negative cases

| Case                                                                                              | Expected result                                                                                                         |
| ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| A client holding the code `7H0K-4XQ2-M91D-TZ5D` receives the `challenge` above.                   | Its expected server proof is `PoxHaveY2Kyz0eGe7vXsZ47Pn5+3omOpNsKn8FRwldI=`, which differs: close 4002, `needsPairing`. |
| The server receives the c2s #0 frame above a second time (expected counter 1).                    | Close 4005.                                                                                                             |
| The client receives the s2c #1 frame above with its last byte changed from `c3` to `c4`.          | Close 4004.                                                                                                             |
| A `challenge` carries the proof `cQpkmCMXJWkVibDhSVYhOrADuuHpqr3ufQtH0J_qEiE=` (URL-safe base64). | Close 1002.                                                                                                             |
| A `hello` carries `"protocol": 2`.                                                                | Close 4001.                                                                                                             |
| A `hello` carries the server's own device id `9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6`.              | Close 4007.                                                                                                             |

### Regenerating the vectors

```swift
import CryptoKit
import Foundation

let code = Data("7H0K4XQ2M91DTZ5C".utf8)
let nc = Data((0x00..<0x20).map { UInt8($0) })
let ns = Data((0x20..<0x40).map { UInt8($0) })
let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: code),
                               salt: Data("hephaestus-v2".utf8), info: Data("pairing".utf8),
                               outputByteCount: 32)
let serverProof = Data(HMAC<SHA256>.authenticationCode(for: Data("server".utf8) + nc + ns, using: k))
let clientProof = Data(HMAC<SHA256>.authenticationCode(for: Data("client".utf8) + nc + ns, using: k))
let kC2S = HKDF<SHA256>.deriveKey(inputKeyMaterial: k, salt: nc + ns, info: Data("c2s".utf8), outputByteCount: 32)
let kS2C = HKDF<SHA256>.deriveKey(inputKeyMaterial: k, salt: nc + ns, info: Data("s2c".utf8), outputByteCount: 32)

func frame(_ json: String, key: SymmetricKey, counter: UInt64) throws -> Data {
    var nonce = Data(count: 4)
    withUnsafeBytes(of: counter.bigEndian) { nonce.append(contentsOf: $0) }
    return try ChaChaPoly.seal(Data(json.utf8), using: key, nonce: ChaChaPoly.Nonce(data: nonce)).combined
}
```

`serverProof.base64EncodedString()`, `frame(<c2s #0 plaintext>, key: kC2S, counter: 0)` and `frame(<s2c #1 plaintext>, key: kS2C, counter: 1)` give the values above. Any other implementation of RFC 5869, RFC 2104 and RFC 8439 gives the same bytes.

## Requirements covered

- R6: Its first level chooses the Main Device: this Mac or another Mac, whose projects the window then shows.
- R43: Any remote sees in real time the changes made anywhere.
- R44: Working from a remote is as if the remote were the one working.
