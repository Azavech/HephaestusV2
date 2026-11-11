# Development

This document is for the people and the Claude sessions that change HephaestusV2. It explains how to build, run and test the app on one Mac, how to run a second isolated instance to test remote sync locally, how automated UI checks drive an offscreen instance through the debug MCP tools, and a virtual machine for what those tools cannot do, without using the user's displays, keyboard or pointer, how Claude CLI fixtures are recorded, and the contribution rules: docs first, public repository. The exact rules of the environment variables, the data directory and the processes are in [Architecture](architecture.md); the pipelines, the scripts and the make targets are in [CI and release](ci.md).

## Prerequisites

| Tool            | Version                                                    | Used for                                                                |
| --------------- | ---------------------------------------------------------- | ----------------------------------------------------------------------- |
| macOS           | 26.0 or later                                              | Running the app and the tests                                           |
| Xcode           | 27.1, with its Swift 6.4 toolchain                         | `swift build`, `swift test`, `scripts/build-app.sh`                     |
| Claude Code CLI | 2.1.309, the version [Chats](chats.md) is verified against | Chats and Haiku naming                                                  |
| git             | The one installed with Xcode                               | Commits, code search ([Search](search.md))                              |
| Go toolchain    | Optional                                                   | `gofmt` for formatting Go files on save ([Code editor](code-editor.md)) |
| swift-format    | Optional                                                   | Formatting Swift files on save ([Code editor](code-editor.md))          |
| python3         | The one installed with Xcode                               | `scripts/tables.py`                                                     |
| curl, plutil    | The ones in macOS                                          | Automated UI checks                                                     |

## Building and running

All commands run from the repository root. The targets are defined in [CI and release](ci.md).

| Command                          | Effect                                                                          |
| -------------------------------- | ------------------------------------------------------------------------------- |
| `make build`                     | Builds every target with `swift build`.                                         |
| `make test`                      | Runs every test target with `swift test`.                                       |
| `make app`                       | Assembles the development bundle `build/HephaestusV2.app`, with build number 0. |
| `make run`                       | Assembles the development bundle and starts it.                                 |
| `make check`                     | Runs `scripts/check-public.sh` and `scripts/check-docs.sh`.                     |
| `make install`                   | Copies the bundle from `build/` to `/Applications`.                             |
| `make release VERSION=… BUILD=…` | Builds a release bundle the way CI does.                                        |

1. The app runs only from a bundle assembled by `scripts/build-app.sh`. `swift run HephaestusV2` is not supported: the process needs the bundle's `Info.plist` (bundle id, `NSBonjourServices`, `NSLocalNetworkUsageDescription`, `HephaestusReleaseRepository`).
2. A development bundle has build number 0, so it never starts the Updater ([Updater](updater.md)).
3. `make run` uses the default data directory, the same as the installed app. Only one process can use a data directory at a time: a second one exits with status 75 ([Device data directory](architecture.md#device-data-directory)). Quit the installed app first, or run the development bundle as an isolated instance ([Second isolated instance](#second-isolated-instance)).
4. Xcode can open `Package.swift` to edit, build and run the tests; the app itself is started with `make run`.

## Environment variables

The app reads these variables once at launch. Their accepted values and exact effects are in [Environment overrides](architecture.md#environment-overrides).

| Variable                     | Use in development                                                                                           |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `HEPHAESTUS_DATA_DIR`        | Gives an extra instance its own data directory, outside the repository.                                      |
| `HEPHAESTUS_MCP_PORT`        | Gives an extra instance its own MCP port.                                                                    |
| `HEPHAESTUS_SYNC_PORT`       | Gives an extra instance its own sync port.                                                                   |
| `HEPHAESTUS_DISABLE_UPDATER` | `1` on every extra instance: no Updater, and the instance ignores the notifications of other Updaters.       |
| `HEPHAESTUS_DEBUG_TOOLS`     | `1` for automated UI checks and fixture recording: enables the debug MCP tools and the stdout capture files. |
| `HEPHAESTUS_WINDOW_SCREEN`   | `offscreen` for automated checks; `builtin` to watch an instance on the built-in display.                    |
| `HEPHAESTUS_CLAUDE_PATH`     | A Claude CLI other than the detected one, used when the `claudePath` setting is not set.                     |

- `open --env NAME=value` passes a variable to an app started with `open`; repeat it for each variable.
- An invalid value, or an unknown variable whose name starts with `HEPHAESTUS_`, stops the launch with exit status 64 and a message on standard error. Start extra instances with `open --stderr <file>` to keep that message.
- A process started with `HEPHAESTUS_DATA_DIR` or `HEPHAESTUS_WINDOW_SCREEN` restores no windows and saves no window state, so it never disturbs the windows of the instance that uses the default data directory.

## Second isolated instance

A second HephaestusV2 process with its own data directory is a separate device, with its own device id, pairing code, external MCP token and projects. Paired with the first one, it shows the first one's projects as a remote device, which tests remote sync on a single Mac.

### Instances and ports

| Instance | Role                                                                             | Data directory                   | MCP port | Sync port | Updater  |
| -------- | -------------------------------------------------------------------------------- | -------------------------------- | -------- | --------- | -------- |
| A        | Main device: the instance you normally run, installed or started with `make run` | Default                          | 47820    | 47821     | As usual |
| B        | Remote device for sync tests                                                     | `$TMPDIR/HephaestusV2-B/data`    | 47830    | 47831     | Disabled |
| C        | [Automated UI checks](#automated-ui-checks)                                      | A new folder made by `mktemp -d` | 47840    | 47841     | Disabled |

Every instance needs its own data directory, its own MCP port and its own sync port. Two processes cannot share a data directory. An instance whose MCP port is taken has no MCP server, so its chats run without the HephaestusV2 tools and show the warning `Hephaestus MCP server unavailable` ([MCP server](mcp.md#server-lifecycle)); an instance whose sync port is taken accepts no remote device ([Remote devices](remote.md#sync-server)).

### Start instance B

```sh
# from the repository root
make app
B_ROOT="${TMPDIR%/}/HephaestusV2-B"
mkdir -p "$B_ROOT"
rm -rf "$B_ROOT/HephaestusV2.app"
ditto build/HephaestusV2.app "$B_ROOT/HephaestusV2.app"
open -n \
  --env HEPHAESTUS_DATA_DIR="$B_ROOT/data" \
  --env HEPHAESTUS_MCP_PORT=47830 \
  --env HEPHAESTUS_SYNC_PORT=47831 \
  --env HEPHAESTUS_DISABLE_UPDATER=1 \
  --stderr "$B_ROOT/stderr.log" \
  "$B_ROOT/HephaestusV2.app"
```

1. B runs from its own copy of the bundle, so `make app` can rebuild `build/` while B runs.
2. `-n` starts a new process even when another HephaestusV2 is running.
3. Add `--env HEPHAESTUS_WINDOW_SCREEN=builtin` to keep B's windows on the built-in display.
4. Do not pass `-F` to `open`: it discards the saved window state of the bundle id, which instance A restores at its next launch.
5. At its first launch B creates its data directory with a new device id, its own pairing code and external MCP token, and no projects.
6. B's device name is the Mac's computer name, like A's. Rename B in B's Settings > Devices, for example to `MacBook`, to tell the two devices apart.

### Pair B with A

1. In A, open Settings (⌘,) > Devices, check that Allow remote devices is on, and copy the pairing code.
2. In B, open the device segment of the toolbar selector and choose Add Device…. Select A in the Nearby list, or enter `127.0.0.1:47821` in the address field; enter A's pairing code; click Connect ([Adding a device](remote.md#adding-a-device)).
3. The sheet closes and B's window shows A's projects. B keeps A's code in its own `secrets.json`; A stores nothing about B ([Paired devices](remote.md#paired-devices)). A's status bar counts B in its connected remotes.

### Sync checks

Every action in B acts on A's projects. Create a scratch project in A first (New Project… in a temporary folder, identifier `DEMO`) and run the checks on it.

| Step | Do                                                                                                                                                  | Expected                                                                                                  |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| 1    | In A, create a ticket without a title.                                                                                                              | B's ticket list shows it at once; the title chosen by Haiku replaces the provisional one in both windows. |
| 2    | In B, set the ticket to In Progress.                                                                                                                | A shows the new status.                                                                                   |
| 3    | In B, add a comment with an image attachment.                                                                                                       | A shows the comment and the thumbnail.                                                                    |
| 4    | In B, start a project chat and send a message.                                                                                                      | The Claude process runs on A; both windows stream the reply.                                              |
| 5    | In B, with the permission mode Ask Every Time, ask Claude to write a file outside the project folder, then click Allow Once on B's permission card. | Claude continues; A shows the decision in the transcript.                                                 |
| 6    | In A, open a web tab on `http://localhost:<port>` of a server running on the Mac.                                                                   | B loads the page through A's device address ([Remote devices](remote.md#localhost-rewrite)).              |
| 7    | Change a ticket file of the scratch project with a text editor.                                                                                     | Both windows show the change ([Data model](data-model.md#external-changes)).                              |
| 8    | Quit A.                                                                                                                                             | B shows its reconnect view and retries with the backoff of [Remote devices](remote.md#backoff).           |
| 9    | Start A again.                                                                                                                                      | B reconnects and shows A's current state.                                                                 |

To check Regenerate of the pairing code, use an isolated instance as A: on the instance you normally run, Regenerate also invalidates every other Mac paired with it.

### What the instances share

Both processes run the same bundle id under the same user, so these are shared:

| Shared                                        | Consequence                                                                                                                                                                                             |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WebKit website data of the app                | Cookies, storage and logins of web tabs: every web view uses the app's default website data store ([Website data](web-tabs.md#website-data)).                                                           |
| Saved application state and defaults domain   | Only the instance with the default data directory restores and saves window state ([Environment overrides](architecture.md#environment-overrides)).                                                     |
| `~/.claude/` and the Claude CLI configuration | Both instances run the same Claude CLI with the same account and settings.                                                                                                                              |
| Project folders registered in both            | Each instance sees the other's writes as external changes ([Data model](data-model.md#external-changes)); two tickets created at the same moment can get the same number. Use separate project folders. |

### Stop instance B

```sh
pkill -TERM -f "$B_ROOT/HephaestusV2.app/Contents/MacOS/HephaestusV2"
```

The app handles `SIGTERM` like Quit, without the confirmation alerts ([Shutdown](architecture.md#shutdown)); ⌘Q in one of B's windows also quits B. Delete `$B_ROOT` to forget B: its device id, its copy of A's pairing code and its logs.

## Automated UI checks

Automated checks, run by a script or by a Claude session, start instance C and see it only through the debug MCP tools. They never use the user's displays, keyboard or pointer. A check that the debug tools cannot do runs in a virtual machine instead ([VM checks](#vm-checks)). Claude follows this procedure whenever it checks the UI of HephaestusV2 itself ([Workflow](workflow.md#build-and-test)).

### Rules

1. Start check instances with `HEPHAESTUS_WINDOW_SCREEN=offscreen` and `open -g`. Every window of the instance opens outside all displays, the instance shows no Dock icon and no menu bar, and it never takes the keyboard focus ([Window placement](architecture.md#window-placement)).
2. Observe and drive the UI only with `debug_ui_state`, `debug_navigate`, `debug_screenshot` and `debug_click`, click only with `debug_click`, and create data with the regular MCP tools (`create_project`, `create_ticket` and the others of [MCP server](mcp.md#tools)).
3. On this Mac, never use `screencapture`, the Screen Recording or Accessibility permissions, AppleScript UI scripting, or mouse and keyboard events posted to the system, such as `CGEvent` posts or `cliclick`. `debug_click` is the only way to click on this Mac: it builds the click inside the app ([debug_click](mcp.md#debug_click)). This rule does not apply inside the guest of a virtual machine ([VM checks](#vm-checks)).
4. Use a new temporary data directory with scratch projects inside it; never the default data directory, never the user's projects.
5. Give each check instance its own ports and `HEPHAESTUS_DISABLE_UPDATER=1`.
6. `builtin` is for a person who wants to watch an instance on the built-in display; checks use `offscreen`.
7. Stop the instance and delete its folder when the check ends.

### Start a check instance

```sh
# from the repository root
make app
C_ROOT="$(mktemp -d)"
ditto build/HephaestusV2.app "$C_ROOT/HephaestusV2.app"
mkdir -p "$C_ROOT/projects"
open -g -n \
  --env HEPHAESTUS_DATA_DIR="$C_ROOT/data" \
  --env HEPHAESTUS_MCP_PORT=47840 \
  --env HEPHAESTUS_SYNC_PORT=47841 \
  --env HEPHAESTUS_DISABLE_UPDATER=1 \
  --env HEPHAESTUS_DEBUG_TOOLS=1 \
  --env HEPHAESTUS_WINDOW_SCREEN=offscreen \
  --stderr "$C_ROOT/stderr.log" \
  "$C_ROOT/HephaestusV2.app"
for attempt in $(seq 60); do
  curl -s -o /dev/null http://127.0.0.1:47840/mcp && break
  sleep 0.5
done
TOKEN="$(plutil -extract mcpExternalToken raw -o - "$C_ROOT/data/secrets.json")"
```

- `curl` succeeds as soon as the MCP server answers (a GET is answered 405). When the loop ends without an answer, `$C_ROOT/stderr.log` holds the launch error.
- `mcpExternalToken` is the external token of the check instance ([Data model](data-model.md#secrets-file)).

### Call the tools

```sh
mcp() {
  curl -s http://127.0.0.1:47840/mcp \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$1"
}
mcp '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_project","arguments":{"path":"'"$C_ROOT"'/projects/demo","name":"Demo","identifier":"DEMO"}}}'
mcp '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"debug_navigate","arguments":{"target":{"kind":"section","projectID":"DEMO","section":"tickets"}}}}'
mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"debug_ui_state","arguments":{}}}'
mcp '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"debug_screenshot","arguments":{}}}'
mcp '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"debug_click","arguments":{"window":4211,"x":120,"y":64}}}'
```

- The server is stateless, so `initialize` is not needed before `tools/call` ([MCP server](mcp.md#statelessness)).
- Each answer is a JSON-RPC response whose `result.content[0].text` holds the tool's JSON result. `debug_screenshot` returns `path`, `width` and `height` of a PNG in `$C_ROOT/data/Runtime/screenshots/`; open that file to see the window.
- To click something, take the window's `id` from `debug_ui_state` and a point of its `debug_screenshot` image: `x` and `y` are that point's pixel coordinates from the top-left corner divided by the image's scale, its `width` divided by the window's `frame.width` (2 on a Retina capture). `debug_click` returns the windows as `debug_ui_state` does, 500 ms after the click.

### Use the tools from Claude Code

```sh
claude mcp add --transport http hephaestus-check http://127.0.0.1:47840/mcp --header "Authorization: Bearer $TOKEN"
```

Start a new Claude Code session afterwards: the tools appear as `mcp__hephaestus-check__<tool>`, and the session reads the PNG files at the paths `debug_screenshot` returns. Remove the server with `claude mcp remove hephaestus-check` when the check ends.

### Stop the check instance

```sh
pkill -TERM -f "$C_ROOT/HephaestusV2.app/Contents/MacOS/HephaestusV2"
while pgrep -f "$C_ROOT/HephaestusV2.app/Contents/MacOS/HephaestusV2" > /dev/null; do sleep 0.5; done
rm -rf "$C_ROOT"
```

### VM checks

A check that the debug tools of the check instance cannot do runs in one of Claude's virtual machines ([Claude's virtual machines](virtual-machines.md#claudes-virtual-machines)): a menu, typed text, a list row, scrolling, a drag, a keyboard shortcut, a system dialog or a permission prompt. Claude starts the virtual machine with the VM tools whenever such a check needs one, without asking. The other checks stay on the offscreen check instance.

1. **Build.** Run `make app` on this Mac, as for a check instance.
2. **Virtual machine.** The guest needs macOS 26 or later, the app's minimum ([Prerequisites](#prerequisites)): `vm_list_images` lists the Ready images. Call `vm_start` with a `name`, for example `HEPH-147 checks`, and with `image` set to the version or the id of such an image, or without `image` when the default image is one. It returns a new virtual machine, or the one that Claude already runs from that image, which the chat joins.
3. **Copy.** Call `vm_copy_in` with `source` set to the absolute path of `build/HephaestusV2.app` in the worktree and `destination` set to `~/Checks/<ticket id>/HephaestusV2.app`. The content of the bundle goes into that folder, which becomes the bundle in the guest.
4. **Start.** Start the instance with `vm_shell`, then wait for its MCP server and read its token as in [Start a check instance](#start-a-check-instance). Each `vm_shell` call is a new shell, so each one sets `C_ROOT` again:

```sh
C_ROOT="$HOME/Checks/HEPH-147"
mkdir -p "$C_ROOT/projects"
open -n \
  --env HEPHAESTUS_DATA_DIR="$C_ROOT/data" \
  --env HEPHAESTUS_MCP_PORT=47840 \
  --env HEPHAESTUS_SYNC_PORT=47841 \
  --env HEPHAESTUS_DISABLE_UPDATER=1 \
  --stderr "$C_ROOT/stderr.log" \
  "$C_ROOT/HephaestusV2.app"
```

5. **Drive.** `vm_screenshot` returns a PNG of the guest's screen; `vm_click`, `vm_drag` and `vm_scroll` take points of it in pixels. A menu item is picked with a click on its menu in the menu bar, then on the item. `vm_type` types into the focused field, `vm_key` presses a key in the menu notation, for example `⇧⌘K`, and `vm_ui_tree` with `app` `HephaestusV2` reads the app's Accessibility tree, with the frames of its elements in screenshot pixels. System dialogs and permission prompts show on the guest's screen, where Claude answers them with `vm_click`. Data is created with the regular MCP tools of the instance, called with `curl` through `vm_shell` as in [Call the tools](#call-the-tools). `vm_copy_out` copies a file of the guest to this Mac.
6. **End.** Quit the instance and delete its folder with `vm_shell`, as in [Stop the check instance](#stop-the-check-instance). Leave the virtual machine running: it stops and is deleted with its disk after the idle time of Settings ([Idle stop](virtual-machines.md#idle-stop)), and other chats may have joined it, for which `vm_stop` would stop it too.

- Without `HEPHAESTUS_WINDOW_SCREEN` and `-g`, the instance shows its windows, its Dock icon and its menu bar on the guest's screen and takes the guest's keyboard focus, as the app does for a user.
- Rule 3 of [Rules](#rules) applies to this Mac only. Inside the guest, the agent takes screenshots with the guest's Screen Recording permission, and posts mouse and keyboard events and reads the Accessibility tree with its Accessibility permission ([Guest agent](virtual-machines.md#guest-agent)); none of it reaches the user's displays, keyboard or pointer. The VM tools take the place of the debug tools of rule 2, and rules 4, 5 and 7 apply to the instance in the guest as they do on this Mac.
- Several chats can share one virtual machine, whose actions run one at a time ([Actions and their queue](virtual-machines.md#actions-and-their-queue)): each chat gives its instance its own folder under `~/Checks/` and its own ports.
- The guest's Claude CLI runs with the Claude token of Settings, when the user set one, so the chats of an instance in the guest run with the user's Claude account ([Claude token](virtual-machines.md#claude-token)).
- When no virtual machine can start, for example because no Ready image of macOS 26 or later exists, the check cannot run, and its Testing line gets the result `failed` with the reason ([Build and test](workflow.md#build-and-test)).

The procedure, the folder `~/Checks/` and leaving the virtual machine to its idle stop are Default chosen at design time.

## Debug MCP tools

| Tool               | Input                                                                                                       | Result                                                                                                  |
| ------------------ | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `debug_ui_state`   | None                                                                                                        | `{"windows": [WindowInfo]}`, front to back: id (AppKit window number), kind, title, isKey, frame, state |
| `debug_navigate`   | `target`, a navigation target as for `open_in_app`                                                          | The `WindowInfo` of the window that navigated, once its state is updated                                |
| `debug_screenshot` | `window`, a window id from `debug_ui_state` (optional)                                                      | `path`, `width` and `height` of a PNG in `<data dir>/Runtime/screenshots/`                              |
| `debug_click`      | `window`, a window id from `debug_ui_state`; `x` and `y`, points from the top-left corner of its screenshot | `{"windows": [WindowInfo]}`, 500 ms after a left click at that point                                    |

- They are listed and callable only when the instance runs with `HEPHAESTUS_DEBUG_TOOLS=1`; otherwise `tools/call` answers `Unknown tool`.
- They act only on the windows of the instance that serves the request.
- Every token of that instance can call them, chat tokens included, so enable them only on check instances and fixture recording instances.
- The screenshot is rendered inside the app, as the feedback screenshot ([Feedback](feedback.md#screenshot-capture)); it needs no permission and works for offscreen windows.
- The click is built inside the app as AppKit mouse events and delivered as the key window delivers a click, although the check instance never activates; it needs no permission, works for offscreen windows and leaves the user's pointer and keyboard focus alone.

Input schemas, errors and examples: [Debug tools](mcp.md#debug-tools).

## Tests

### Running tests

- `make test`, or `swift test`, runs every test target. CI runs `swift test` for every pull request and before every release ([CI and release](ci.md)).
- `swift test --filter HephaestusTextTests` runs one target; `--filter` also accepts a suite or test name.
- `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4 swift test` runs at most 4 tests at a time, as CI does ([Test parallelism](ci.md#test-parallelism)).
- `PREVIEW_BUILD_TESTS=1 swift test --filter "PreviewMethodsTests|DevicePreviewTests|PreviewSelectionTests|ViewElementTests"` also runs the tests that build previews or compile marked files (rule 12); those of the device previews need an iOS Simulator runtime and boot a simulator device of the test's own data directory.

### Test targets

| Target              | Covers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| HephaestusCoreTests | Models and YAML coding; atomic writes, loading and external changes; id allocation; every engine method through `LocalEngineConnection`, with its actor rules, errors and events; the MCP server over HTTP on 127.0.0.1; the sync handshake, encryption, test vectors and reconnection between two engines; Claude CLI argument lists and the stream-json mapping of the fixtures; search; skills plugin generation; memory folder resolution, memory files and `MEMORY.md` updates; `LaunchEnvironment` parsing; docs conformance. |
| HephaestusTextTests | Highlighter token rules for every language ([Code editor](code-editor.md)); Markdown to HTML and to block model, sanitization ([Documentation viewer](documentation-viewer.md)).                                                                                                                                                                                                                                                                                                                                                    |
| HephaestusUITests   | The HephaestusUI code that runs without a window: the chat settings menus and their menu items ([Chat settings](chats.md#chat-settings)), the inspector's linked items, the linked items Send passes and their chips in the user bubbles ([Linked items](chats.md#linked-items)).                                                                                                                                                                                                                                                   |
| UpdaterCoreTests    | Version comparison and display, `release.json` decoding, the feed client with stubbed HTTP responses, the verification steps ([Updater](updater.md)).                                                                                                                                                                                                                                                                                                                                                                               |

### Test rules

1. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). Default chosen at design time.
2. A test that touches files creates its own temporary directory and removes it at the end. Tests never read or write the default data directory, `~/.claude` or the user's projects. A test engine resolves the memory folders of its projects and its global memories folder under a config folder next to its temporary data directory, and a test of the resolution builds its resolver with temporary folders in place of the home folder, `~/.claude` and the managed settings ([Engine configuration](architecture.md#engine-configuration), [Resolution](memories.md#resolution)). A test engine that moves items to the Trash has its Trash replaced, through the engine's test hook `useFileTrash(_:)`, by a folder of the test's temporary directory, or by a Trash that fails for the `unavailable` errors, so tests never fill the user's Trash. Default chosen at design time.
3. A test engine is built from an `EngineConfiguration` ([Engine configuration](architecture.md#engine-configuration)): a temporary data directory, ports 0, the sync server on the loopback interface, no Bonjour advertising and therefore no Bonjour browsing ([Startup](architecture.md#startup)).
4. Engine method tests call through `LocalEngineConnection`, so they exercise the JSON path every client uses. Default chosen at design time.
5. Tests never start the real Claude CLI. Chat behaviour is tested with the in-memory `ClaudeProcessLauncher` fed with fixture lines, and the CLI arguments are compared as argument lists with [Chats](chats.md).
6. Tests use no network beyond 127.0.0.1 and no user interaction; the GitHub answers of the release feed are stubbed, and a test engine runs no `gh`: its `githubCLI` is a fake that answers as a missing gh unless the test gives its own ([Engine configuration](architecture.md#engine-configuration), [gh calls](builds.md#gh-calls)). A test that saves a release asset turns its quarantine attributes off with the engine's test hook `useReleaseQuarantine(_:)`, so that it adds nothing to the quarantine events of the user running it.
7. Test data contains no personal data ([Public repository](#public-repository)).
8. At most 32 test engines run at the same time, and the tests that wait for FSEvents run one at a time, across suites (the `.fsEvents` trait). Swift Testing starts every test of a run at once, and a process gets at most 512 FSEvents streams: past that `FSEventStreamStart` fails and an engine watches nothing. Default chosen at design time.
9. A test that binds a port it chose earlier, or checks that a stopped server's port refuses connections, uses a free port below the ephemeral range (49152 to 65535). A released ephemeral port can go to another test's listener that asks for port 0 at any time, and a later bind of 127.0.0.1 on it succeeds and takes that listener's loopback connections. Default chosen at design time.
10. The speed of the machine changes how long a test takes, never its result. A test that checks that something happens (a state, an event, an output, a process) waits for it, not for a fixed time; the bound of such a wait, `waitLimit` (60 s), only ends a test that fails. The timeouts of the code under test that a test does not check are long bounds that a busy machine never reaches, and the timers a test checks keep a wide margin to the delays of a loaded run. No test blocks a thread of the Swift concurrency pool while a child process runs, and a test that loads the machine on purpose bounds its work and yields between its steps. Default chosen at design time.
11. Tests start no virtual machine and reach neither ipsw.me nor Apple's servers: the `imageProvisioner` of a test engine is a stand-in whose every operation fails unless the test gives its own, and its `guestTools` is nil unless the test gives files of its temporary directory ([Engine configuration](architecture.md#engine-configuration)). The protocol of the guest agent is tested in one process, the host's connection against the agent's own session over a socket pair, with the methods that need neither the Accessibility nor the Screen Recording permission. No test runs `sudo`: the commands of `exec` run as the user who runs the tests, and a stand-in takes the place of the kill as root of a timeout. Default chosen at design time.
12. The tests that build the previews of a Swift package and of an Xcode project with the toolchain of Xcode ([Builds](views.md#builds)) run only when the environment variable `PREVIEW_BUILD_TESTS` is `1`, and CI does not set it: each of their builds uses every core of the Mac for seconds, and the timing-sensitive suites that run beside them, the guest agent's among them, then fail. They build fixtures of their temporary directory, without dependencies and without network. The tests of the device previews ([Device previews](views.md#device-previews)) also need an iOS Simulator runtime: they boot a simulator device in the device set of their own data directory, which the engine shuts down when it stops. Default chosen at design time.

### Docs conformance tests

HephaestusCoreTests compares the docs with the code ([CI and release](ci.md)): the MCP tool names and required inputs of [MCP server](mcp.md), the engine method names of [Engine API](engine-api.md), the prompt placeholders of [Chats](chats.md), the default internal skills of [Skills](skills.md) and the YAML examples of [Data model](data-model.md). A behaviour change therefore changes the docs and the code in the same commit, or `swift test` fails.

## Fixtures

### Claude CLI captures

`Tests/HephaestusCoreTests/Fixtures/` holds sanitized captures of the standard output of the Claude CLI in stream-json. The captures, the chat settings they were recorded with and the items each line must produce are listed in [Fixture replays](chats.md#fixture-replays); the tests replay them through the output mapping. A new capture is added there first (docs first), then recorded.

### gh captures

`Tests/HephaestusCoreTests/Fixtures/gh/` holds sanitized outputs of the gh commands of [gh calls](builds.md#gh-calls), recorded with the same `--json` fields as the engine: `run-list.json` (`gh run list`), `run-view.json` (`gh run view` of a completed run), `run-view-running.json` (`gh run view` of a run not completed, with a running job whose end gh writes as `0001-01-01T00:00:00Z`), `release-list.json` (`gh release list`) and `release-view.json` (`gh release view`). The tests read them into the [API types](engine-api.md#workflowrun) and serve them from a fake gh. A capture is recorded by running the command against a public repository, then sanitized ([Sanitizing a capture](#sanitizing-a-capture)): the repository in the URLs is written `example/HephaestusV2`. `run-view-running.json` comes from another public repository, so both its owner and its name are rewritten; in the other captures only the owner changes.

### ipsw.me capture

`Tests/HephaestusCoreTests/Fixtures/ipsw/virtualmac.json` holds the answer of ipsw.me to the request of [macOS versions](virtual-machines.md#macos-versions), reduced to six of its firmwares. It names Apple's files only and needed no sanitizing. The tests read the list of versions from it and serve it from the stand-in provisioner.

### Recording a capture

1. Start an isolated instance with `HEPHAESTUS_DEBUG_TOOLS=1`, as for instance B, and create a scratch project in it. While debug tools are on, the engine appends every standard output line of a chat's Claude processes to `<data dir>/Logs/claude-<chatID>.stdout.jsonl` ([Device data directory](architecture.md#device-data-directory)).
2. Open a chat in the scratch project with the settings listed for the capture, and produce the scenario. A permission request needs the permission mode Ask Every Time and a tool call that the CLI's own rules do not allow.
3. Copy the lines of the scenario from the newest `claude-*.stdout.jsonl` file into the fixture file: the `system/init` line and every line of the turn, up to and including its `result`.
4. Sanitize the file ([Sanitizing a capture](#sanitizing-a-capture)), run `scripts/check-public.sh` and read the whole file.
5. Update the line table of the capture in [Chats](chats.md#fixture-replays) when the lines changed, then the test that replays it.

The engine writes these capture files only so that fixtures can be recorded. Default chosen at design time.

### Sanitizing a capture

| Data                                               | Replacement           |
| -------------------------------------------------- | --------------------- |
| Home folder paths, `cwd` of `system/init` included | `/Users/example/…`    |
| The user name anywhere else                        | `example`             |
| E-mail addresses                                   | `user@example.com`    |
| Computer, host and device names                    | `Studio` or `MacBook` |
| Tokens, keys, account and organization identifiers | `REDACTED`            |

Session ids, message ids and tool use ids stay as recorded.

## Logs

| File                                           | Content                                                                               |
| ---------------------------------------------- | ------------------------------------------------------------------------------------- |
| `<data dir>/Logs/engine.log`                   | Engine log: servers, sync sessions, MCP tool calls, warnings and errors.              |
| `<data dir>/Logs/claude-<chatID>.log`          | Standard error of the chat's Claude processes.                                        |
| `<data dir>/Logs/claude-<chatID>.stdout.jsonl` | Standard output of the chat's Claude processes, only with `HEPHAESTUS_DEBUG_TOOLS=1`. |
| The file given to `open --stderr`              | Launch errors: invalid environment (status 64), data directory in use (status 75).    |

`tail -f "<data dir>/Logs/engine.log"` follows the engine log. Line format and rotation: [engine.log](architecture.md#enginelog).

## Contribution rules

### Docs first

- `docs/` is the specification: the code is generated from it and tested against it ([Docs index](README.md)). A change of behaviour starts in the docs; then the code changes to match, and both go into the same commit. Claude applies the same rule to every ticket ([Workflow](workflow.md#docs-first)).
- Every docs file is linked from `docs/README.md` and follows its conventions: `# Title`, a one-paragraph summary, `##` sections, relative links, and a final `## Requirements covered` section that lists requirement ids ([Conventions](README.md#conventions)).
- A choice the user did not make is followed by the sentence `Default chosen at design time.` so that it can be reviewed.
- Tables are aligned: `python3 -I scripts/tables.py --fix docs/*.md` aligns them and `python3 -I scripts/tables.py --check docs/*.md` reports the unaligned ones.
- A new user requirement is added to [Requirements](requirements.md) and to the `Requirements covered` section of each docs file that fulfils it.
- HephaestusV2 is written from these docs only: the code, docs and data of its first version (v1) are not read and nothing is taken from them.

### Public repository

- The repository is public. Never commit personal data: real names, e-mail addresses, home paths such as `/Users/<name>`, device names, Apple team ids. Write `user@example.com`, `~/…` or `/Users/example`, and `Studio` or `MacBook` instead.
- `make check` runs `scripts/check-public.sh` and `scripts/check-docs.sh`; CI runs the same checks and fails on personal data ([CI and release](ci.md)).
- Ticket attachments of the HephaestusV2 project, feedback screenshots included, stay out of git: the root `.gitignore` lists `.hephaestus/attachments/` ([Repository layout](architecture.md#repository-layout)).
- Fixtures are sanitized before they are committed ([Sanitizing a capture](#sanitizing-a-capture)).
- Data directories, `secrets.json` files and logs never go inside the repository.

### Commits and pushes

- Commit messages are conventional commits: `<type>: <summary> (<TICKET-ID>)` for a ticket, `<type>: <summary>` for work outside a ticket. Types and rules: [Commits](workflow.md#commits).
- Every push to `main` starts the release pipeline; when it passes, the release it publishes is installed by every copy of the app with automatic updates on ([Self-update loop](workflow.md#self-update-loop)). `main` therefore always passes `make check` and `make test`.
- Pull requests run `.github/workflows/ci.yml`: the checks, the build and the tests ([CI and release](ci.md)).

### Before pushing

1. The docs describe the change, and their tables are aligned.
2. `make check` passes.
3. `make test` passes.
4. A UI change was checked on an offscreen check instance, and in a virtual machine for what its debug tools cannot do ([Automated UI checks](#automated-ui-checks), [VM checks](#vm-checks)).

## Requirements covered

- R3: The app is created without reading or taking inspiration from its first version, v1.
- R52: The app is on GitHub.
- R55: The app is built against the docs.
- R205: A ticket Claude writes has a User Testing bullet only for a check that needs the user's own accounts, data or hardware; Claude runs every other check itself, in a virtual machine that it starts without asking when the check needs what the offscreen check instance cannot do.
