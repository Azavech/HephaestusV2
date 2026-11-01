# HephaestusV2

HephaestusV2 is a macOS app (macOS 26 or later) that coordinates the work on all of a user's projects: tickets and bundles, Claude chats, a code editor, documentation, web tabs and skills, on this Mac or live on another Mac running HephaestusV2. Claude runs through the Claude CLI and works on the app's data through the app's MCP server, and the app updates itself from the GitHub releases of this repository.

The specification is in [docs/README.md](docs/README.md). Every change starts there; the code is built and tested against it.

```sh
swift build
swift test
```
