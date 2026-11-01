# Updater

HephaestusV2 updates itself from the GitHub releases of its own repository. A second executable, the Updater, runs beside the app: it checks the release feed 10 seconds after it starts, then every `updateCheckIntervalMinutes` and on demand; it downloads and verifies a newer build, and when the app quits it replaces the app bundle and, for a restart, relaunches the app. The app and the Updater talk through distributed notifications. The app shows the Updater's state in the About window, in Settings > Updates and in the update-ready banner, and decides when to restart. How releases are built and published is in [CI and releases](ci.md); the path from a ticket to an installed update is the [self-update loop](workflow.md#self-update-loop).

## Overview

| Part        | Location                                                                   | Role                                                                                                                                                                                          |
| ----------- | -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Updater     | `HephaestusV2.app/Contents/Helpers/Updater`, built from `Sources/Updater/` | Separate process: feed checks, download, verification, bundle replacement, relaunch. Bundle id `ca.azavech.hephaestusv2.updater`, embedded in the executable ([CI](ci.md#updater-infoplist)). |
| UpdaterCore | `Sources/UpdaterCore/`                                                     | Library used by the Updater and by the app: versions, release manifest, feed client, verification, install steps, IPC names and payloads ([Swift shape](#swift-shape)).                       |
| App side    | `UpdateController` in `Sources/HephaestusUI/About/`, owned by `AppModel`   | Starts the Updater, sends its requests, keeps `AppModel.updaterStatus`, shows the About window, the banner and the Settings status line, restarts the app.                                    |

The name `UpdateController` is Default chosen at design time.

## Versions and display

| Item               | Source                                    | Format                        | Example              |
| ------------------ | ----------------------------------------- | ----------------------------- | -------------------- |
| version            | `CFBundleShortVersionString`              | `X.Y.Z`                       | `0.4.0`              |
| build              | `CFBundleVersion`                         | decimal integer               | `57`                 |
| Update display     | version and build of a release or the app | `v<version>(<build>)`         | `v0.4.0(57)`         |
| About version line | version and build of the running app      | `Version <version> (<build>)` | `Version 0.4.0 (57)` |

- Only builds are compared: a release is newer when its build is greater than the running app's build. Version strings are shown and checked for equality, never compared. Release builds grow with every commit on `main` ([Versioning](ci.md#versioning)).
- Every Mac updates its own app with its own Updater, using the `autoUpdate` and `updateCheckIntervalMinutes` values of its own `settings.yml` ([Data model](data-model.md#settings-file)), whatever device a window shows. The About window, the banner and Settings > Updates always describe this Mac's app.

## Starting the Updater

At launch, after the engine has started, `AppModel` starts the Updater ([Startup](architecture.md#startup)) unless one of the conditions below holds. The conditions are evaluated once per launch, in order; the first one that holds is the reason shown by the About window and by Settings > Updates.

| #   | Condition                                                                                                                                                                                           | Reason shown                                                                                                     |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| 1   | `CFBundleVersion` of the running app is missing, not a decimal integer, or `0` (a development build, [Local make targets](ci.md#local-make-targets))                                                | `Updates are disabled in development builds.`                                                                    |
| 2   | `HEPHAESTUS_DISABLE_UPDATER` is `1` ([Environment overrides](architecture.md#environment-overrides))                                                                                                | `Updates are disabled by HEPHAESTUS_DISABLE_UPDATER.`                                                            |
| 3   | The folder that contains `HephaestusV2.app`, or the bundle folder itself, is not writable by the user (`FileManager.isWritableFile(atPath:)`), for example a translocated app or a read-only volume | `Updates are unavailable: move HephaestusV2 to a folder you can write to, such as /Applications, and reopen it.` |
| 4   | The Info.plist key `HephaestusReleaseRepository` is missing or does not match `^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$`                                                                                     | `Updates are unavailable: this build has no release repository.`                                                 |
| 5   | `Contents/Helpers/Updater` is missing or not executable                                                                                                                                             | `Updates are unavailable: the Updater is missing from the app bundle.`                                           |

Rows 4 and 5 and every reason text are Default chosen at design time.

### Command line

```
Updater --app <bundle path> --pid <app pid> --interval <minutes> --auto-update <true|false>
```

| Argument        | Required | Value                                                                                                                 |
| --------------- | -------- | --------------------------------------------------------------------------------------------------------------------- |
| `--app`         | yes      | Absolute path of the running app bundle (`Bundle.main.bundleURL.path`).                                               |
| `--pid`         | yes      | Process id of the running app.                                                                                        |
| `--interval`    | no       | `updateCheckIntervalMinutes`; default `30`. A value below 5 is raised to 5 and a value above 1440 is lowered to 1440. |
| `--auto-update` | no       | `autoUpdate`; `true` or `false`, default `true`.                                                                      |

`--interval` and `--auto-update` are Default chosen at design time. A missing or invalid required argument, an unknown argument or an invalid value makes the Updater write `Updater: <reason>` to standard error and exit with status 64.

### Launch and supervision

- The app starts the Updater with `Process`: executable `Contents/Helpers/Updater` of the running bundle, the arguments above, the app's own environment, and standard input, output and error set to `/dev/null`. Default chosen at design time.
- The Updater logs with `os.Logger`, subsystem `ca.azavech.hephaestusv2.updater`, category `updater`; it writes nothing else to standard output or error. Default chosen at design time.
- When the Updater exits while the app keeps running and the app has not posted [`app.quitting`](#ipc), the app starts it again 5 seconds later with the current settings. After the third such restart in one launch the app stops restarting it, and the reason shown becomes `The updater stopped unexpectedly.` Default chosen at design time.
- An app process that did not start an Updater ignores every updater notification, so it never reacts to the Updater of another HephaestusV2 process on the same Mac ([Environment overrides](architecture.md#environment-overrides)).

## Lifetime

- The Updater runs the main run loop and watches the app's pid with a process exit source (`DispatchSource.makeProcessSource(identifier:eventMask: .exit)`).
- When the pid does not exist at start, the Updater exits with status 0.
- When the app's pid exits, the Updater finishes the install in state `installing` ([Installing](#installing)); in every other state it exits with status 0 at once, abandoning a running check or download. A download is moved to its final name only once complete, so an abandoned download leaves no file that a later check reuses.
- Exit statuses: 0 normal end, 1 install failed ([Install failure](#install-failure)), 64 usage error.

## Release feed

The repository is the value `<owner>/<name>` of the Info.plist key `HephaestusReleaseRepository` of `<app>/Contents/Info.plist`, read once at start; CI sets it from `github.repository` ([Info.plist keys](ci.md#infoplist-keys)).

### Latest release request

`GET https://api.github.com/repos/<owner>/<name>/releases/latest`, without authentication, timeout 30 seconds, with these headers:

| Header                 | Value                                    |
| ---------------------- | ---------------------------------------- |
| `Accept`               | `application/vnd.github+json`            |
| `X-GitHub-Api-Version` | `2022-11-28`                             |
| `User-Agent`           | `HephaestusV2-Updater/<running version>` |

The headers and the timeout are Default chosen at design time.

| Response                                               | Outcome                                                                                                                    |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| 200                                                    | The release JSON. Fields used: `tag_name`, `assets[].name`, `assets[].browser_download_url`; every other field is ignored. |
| 404                                                    | The repository has no release yet: state `upToDate`. Default chosen at design time.                                        |
| 429, or 403 with the header `x-ratelimit-remaining: 0` | State `error`, message `GitHub's rate limit was reached; the next check tries again.`                                      |
| Any other status                                       | State `error`, message `GitHub answered HTTP <status>.`                                                                    |
| No response (network error, timeout)                   | State `error`, message `The update check failed: <localized description>.`                                                 |

The release must have one asset named exactly `release.json` and one named exactly `HephaestusV2.zip`; otherwise the state is `error` with the message `The latest release has no <asset name> asset.`

### Release manifest

The Updater downloads the `browser_download_url` of `release.json` (redirects followed, timeout 30 seconds, at most 1 MiB) and decodes it as `ReleaseManifest`, whose fields and rules are in [release.json](ci.md#releasejson). A body that does not decode, or a field that breaks its rule, gives state `error` with the message `The release.json of the latest release is invalid.` The size limit is Default chosen at design time.

### Decision

The first row that holds gives the outcome of the check; "running build" is `CFBundleVersion` of `<app>/Contents/Info.plist`, read once at start.

| #   | Condition                                                                                                                             | State       | version and build | message                                     |
| --- | ------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------- | ------------------------------------------- |
| 1   | `build` of the manifest ≤ running build                                                                                               | `upToDate`  | —                 | —                                           |
| 2   | `minimumSystemVersion` of the manifest is above the running macOS version (compared component by component, missing components are 0) | `upToDate`  | the manifest's    | `v0.5.0(61) requires macOS 27.0.`           |
| 3   | The cache folder of that build holds an `install-failed` file ([Install failure](#install-failure))                                   | `error`     | the manifest's    | `Installing v0.5.0(61) failed: <file text>` |
| 4   | Otherwise                                                                                                                             | `available` | the manifest's    | —                                           |

Rows 2 and 3 are Default chosen at design time. In row 4, when `autoUpdate` is true the Updater starts the [download](#download-and-verification) at once; when it is false the Updater waits for an `install` request.

## Check schedule

- The first check runs 10 seconds after the Updater starts.
- Then a check runs every `--interval` minutes, counted from the end of the previous check, whether that one was scheduled or requested. Default chosen at design time.
- A [`check`](#ipc) notification first adopts the `intervalMinutes` (raised to 5, lowered to 1440) and `autoUpdate` values it carries, then asks for a check now.
- A check that is due or requested runs only in some states:

| State when a check is due or requested   | Effect                                                  |
| ---------------------------------------- | ------------------------------------------------------- |
| `idle`, `upToDate`, `available`, `error` | The check runs.                                         |
| `checking`                               | No second check; the current status is posted again.    |
| `downloading`, `ready`, `installing`     | No network request; the current status is posted again. |

- A check in state `available` that finds the same build keeps it; one that finds a newer build replaces it.
- When a `check` changes `autoUpdate` from false to true while the state is `available`, the download starts after the check. Turning `autoUpdate` off does not cancel a running download nor discard a `ready` update; the app then waits for the user to restart ([Restart rules](#restart-rules)). Default chosen at design time.

## Download and verification

The state is `downloading` from the first step until the update is `ready` or a step fails; `version` and `build` are the manifest's. A download starts when `autoUpdate` is true and a check finds a newer build, or on an `install` request ([IPC](#ipc)).

| #   | Step                                                                                                                                                                                                                                                                                                                                                                                       | Failure message                                              |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------ |
| 1   | Use the cache folder `~/Library/Caches/HephaestusV2/Updates/<build>/`, creating it, and delete every other entry of `~/Library/Caches/HephaestusV2/Updates/`.                                                                                                                                                                                                                              | `The update could not be saved: <localized description>.`    |
| 2   | When `<build>/HephaestusV2.zip` exists and its size and SHA-256 match the manifest, reuse it. Otherwise download the `browser_download_url` of `HephaestusV2.zip` (redirects followed, request timeout 60 seconds, resource timeout 30 minutes) to a temporary file and move it to `<build>/HephaestusV2.zip`. Write the manifest's bytes to `<build>/release.json`.                       | `Downloading v0.5.0(61) failed: <localized description>.`    |
| 3   | The size of `HephaestusV2.zip` equals `size`.                                                                                                                                                                                                                                                                                                                                              | `The downloaded update has the wrong size.`                  |
| 4   | The SHA-256 of `HephaestusV2.zip`, in lowercase hexadecimal, equals `sha256`.                                                                                                                                                                                                                                                                                                              | `The downloaded update does not match its SHA-256 checksum.` |
| 5   | Delete `<build>/expanded/` when it exists, then run `/usr/bin/ditto -x -k <build>/HephaestusV2.zip <build>/expanded`; the exit status is 0.                                                                                                                                                                                                                                                | `The downloaded update could not be unpacked.`               |
| 6   | `<build>/expanded/HephaestusV2.app` exists and is a folder.                                                                                                                                                                                                                                                                                                                                | `The downloaded update does not contain HephaestusV2.app.`   |
| 7   | In `<build>/expanded/HephaestusV2.app/Contents/Info.plist`: `CFBundleIdentifier` is `ca.azavech.hephaestusv2`, `CFBundleShortVersionString` equals `version` and `CFBundleVersion` equals `build` written in decimal.                                                                                                                                                                      | `The downloaded update is not HephaestusV2 v0.5.0(61).`      |
| 8   | `/usr/bin/codesign --verify --deep --strict <build>/expanded/HephaestusV2.app` exits with status 0.                                                                                                                                                                                                                                                                                        | `The downloaded update has an invalid code signature.`       |
| 9   | Team ID: when the running app (`--app`) is signed with a Team ID, the new app is signed with the same Team ID. Both are read with the Security framework: `SecStaticCodeCreateWithPath`, then `SecCodeCopySigningInformation` with `kSecCSSigningInformation`, key `kSecCodeInfoTeamIdentifier`. A running app without a Team ID (ad-hoc signed) accepts any signature that passed step 8. | `The downloaded update is signed by another team.`           |

- After step 9 the state becomes `ready`; the Updater posts `status` and then `ready`.
- When a step fails, the Updater deletes `<build>/` and the state becomes `error` with the step's message and the manifest's version and build. The next check, scheduled or requested, starts again from the feed.
- `<localized description>` is the `localizedDescription` of the underlying error. The failure messages and the timeouts are Default chosen at design time.
- With `HEPHAESTUS_DATA_DIR` set, the cache folder stays `~/Library/Caches/HephaestusV2/Updates/` ([Files outside the data directory](architecture.md#files-outside-the-data-directory)).

## Installing

The app tells the Updater that it quits with [`app.quitting`](#ipc). The payload's `restart` is true when the app quits to install an update and relaunch, false on an ordinary quit.

### Restart for an update

1. The app saves its windows ([Persistence](ui.md#persistence)), then posts `app.quitting` with `restart` true ([Restart rules](#restart-rules)).
2. In state `ready`, the Updater switches to `installing` and posts its status. In any other state it ignores the notification and posts its current status again.
3. The app waits at most 5 seconds for the status `installing`. When it arrives, the app terminates as on Quit, without the quit confirmations ([Shutdown](architecture.md#shutdown)). When it does not arrive, the app keeps running and shows the error `The updater did not respond; the update was not installed.` in the About window and the banner. Default chosen at design time.
4. The Updater waits for the app's pid to exit, at most 60 seconds. When the app is still running after 60 seconds, the state goes back to `ready` with the message `HephaestusV2 did not quit; the update waits for the next restart.` Default chosen at design time.
5. The Updater replaces the bundle: `FileManager.default.replaceItemAt(<--app URL>, withItemAt: <build>/expanded/HephaestusV2.app URL)`.
6. It removes the extended attribute `com.apple.quarantine` from the installed bundle folder and from every file and folder inside it (`removexattr` with `XATTR_NOFOLLOW`; a missing attribute is not an error).
7. It relaunches the app: `/usr/bin/open`, then `-g` when `activate` was false, then one `--env <NAME>=<value>` argument for each `HEPHAESTUS_*` variable of its own environment, then the bundle path. The app therefore restarts with the same overrides ([Environment overrides](architecture.md#environment-overrides)).
8. It deletes `~/Library/Caches/HephaestusV2/Updates/<build>/` and exits with status 0.

A failure of step 6, 7 or 8 is logged and does not change the exit status.

### Install on quit

On an ordinary quit (⌘Q, `SIGTERM`, `SIGINT`), the app posts `app.quitting` with `restart` false after the quit confirmations ([Unsaved changes and quitting](ui.md#unsaved-changes-and-quitting)) and terminates without waiting for an answer. In state `ready`, the Updater switches to `installing`, waits for the pid to exit (step 4) and runs steps 5, 6 and 8, without relaunching. In state `installing` it ignores the notification. In any other state it exits with status 0 when the pid exits. The app posts `app.quitting` once per termination: the restart sequence does not post it a second time. The next launch then runs the new build. Default chosen at design time.

### Install failure

When step 5 fails, the Updater writes the error's `localizedDescription` to `~/Library/Caches/HephaestusV2/Updates/<build>/install-failed`, relaunches the unchanged app as in step 7 when `restart` was true, and exits with status 1. From then on every check reports that build as `error` (row 3 of [Decision](#decision)) and the Updater never downloads it automatically. The About window's Try Again sends `install`, which deletes `install-failed` and starts the download again. Default chosen at design time.

## Restart rules

The app is **idle** when both hold:

- no chat of This Mac's engine is running: no chat in state `starting`, `running` or `waitingPermission` ([Chat states](chats.md#chat-states));
- nothing unsaved in any window of this app: no code, doc or skill editor with unsaved changes, no ticket description being edited with changes and no non-empty comment draft ([Tickets](tickets.md#live-updates)), no chat composer holding unsent text, no open sheet.

The composer and sheet conditions are Default chosen at design time. Project runs are not part of the definition: a run still going is stopped by the restart like on Quit ([Shutdown](architecture.md#shutdown)).

| Situation                                                                              | Behaviour                                                                                                                                                                                                         |
| -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| State `ready`, `autoUpdate` true, the user did not choose Install, the app is idle     | The restart sequence starts at once ([Restart for an update](#restart-for-an-update)).                                                                                                                            |
| State `ready`, `autoUpdate` true, the user did not choose Install, the app is not idle | The banner `Update v0.5.0(61) ready — restarts when idle` appears; the restart sequence starts as soon as the app is idle, re-evaluated whenever a chat state, an editor, a draft, a composer or a sheet changes. |
| State `ready` and `autoUpdate` false, the user did not choose Install                  | The banner `Update v0.5.0(61) ready` appears; the app does not restart by itself. Default chosen at design time.                                                                                                  |
| The user chose Install in the About window and the state is or becomes `ready`         | The restart checks run, then the restart sequence.                                                                                                                                                                |
| The user clicks Restart Now in the banner                                              | The restart checks run, then the restart sequence.                                                                                                                                                                |

**Restart checks.** They are the checks of quitting ([Unsaved changes and quitting](ui.md#unsaved-changes-and-quitting)): unsaved changes first, then running work, with this alert instead of the quit alert when This Mac's engine has chats in state `starting`, `running` or `waitingPermission`, or running runs:

| Title                            | Message                                                                                          | Buttons                       |
| -------------------------------- | ------------------------------------------------------------------------------------------------ | ----------------------------- |
| `Restart to install v0.5.0(61)?` | `<chats> and <runs> on This Mac will be stopped.`, with the same wording rules as the quit alert | `Restart` (default), `Cancel` |

After a restart sequence that failed at step 3 of [Restart for an update](#restart-for-an-update), the app does not start the sequence again by itself for that build; Install and Restart Now start it again. Default chosen at design time.

Cancel at either step cancels the restart; the update stays `ready` and the About window shows `v0.5.0(61) available` with Install and Not Now again. An automatic restart never shows these alerts, because it happens only when the app is idle. The alert texts and the counting of runs are Default chosen at design time.

## IPC

The app and the Updater exchange distributed notifications:

- Center `DistributedNotificationCenter.default()`; object `ca.azavech.hephaestusv2` on every notification; every post uses `deliverImmediately: true`.
- `userInfo` holds property-list values only. A value that does not apply is left out of the dictionary.
- Every notification carries `pid`: from the app, the app's own process id; from the Updater, the `--pid` it was started with. The app ignores Updater notifications whose `pid` is not its own process id, and the Updater ignores app notifications whose `pid` is not its `--pid`, so several HephaestusV2 processes on one Mac never act on each other's notifications. Default chosen at design time.
- The Updater registers its observers before it posts its first status (`idle`).

| Name                                      | Direction     | `userInfo`                                                                           | Meaning                                                                                                                                                                                                                                           |
| ----------------------------------------- | ------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ca.azavech.hephaestusv2.updater.check`   | app → Updater | `pid` (Int), `intervalMinutes` (Int), `autoUpdate` (Bool)                            | Adopt the two settings, then check now ([Check schedule](#check-schedule)).                                                                                                                                                                       |
| `ca.azavech.hephaestusv2.updater.install` | app → Updater | `pid` (Int)                                                                          | Download and verify the newer build the Updater knows: in state `available`, or in state `error` when the error carries a build (an `install-failed` file of that build is deleted first). In any other state the current status is posted again. |
| `ca.azavech.hephaestusv2.updater.status`  | Updater → app | `pid` (Int), `state` (String), `version` (String), `build` (Int), `message` (String) | The Updater's state ([Updater states](#updater-states)); `version`, `build` and `message` only when the state carries them. Posted at every state change and whenever a request leaves the state unchanged.                                       |
| `ca.azavech.hephaestusv2.updater.ready`   | Updater → app | `pid` (Int), `version` (String), `build` (Int)                                       | The update is downloaded and verified. Posted once per update, right after the status `ready`.                                                                                                                                                    |
| `ca.azavech.hephaestusv2.app.quitting`    | app → Updater | `pid` (Int), `restart` (Bool), `activate` (Bool)                                     | The app terminates now; `restart` is true when it quits to install the update and relaunch ([Installing](#installing)); `activate` is true when HephaestusV2 is the active app when it posts the notification.                                    |

The `intervalMinutes`, `autoUpdate`, `restart` and `activate` keys are Default chosen at design time.

The app posts `check`:

- when the About window appears ([About window](#about-window));
- when the user clicks Check Now in Settings > Updates ([Settings](#settings));
- when This Mac's engine emits `settings.updated` with a changed `autoUpdate` or `updateCheckIntervalMinutes` ([Engine API](engine-api.md)), whichever client changed it. Default chosen at design time.

The app posts `install` when the user chooses Install in the About window or Try Again after an error that carries a build, and `app.quitting` as described in [Installing](#installing).

## Updater states

`AppModel.updaterStatus` ([UI](ui.md)) holds the last `status` received; before the first one it is `idle` without version, build or message. While the Updater is not running, `UpdateController.unavailableReason` holds the reason of [Starting the Updater](#starting-the-updater), and is `nil` otherwise. Default chosen at design time.

| State         | Meaning                                                                 | `version`, `build`                          | `message`                                                         |
| ------------- | ----------------------------------------------------------------------- | ------------------------------------------- | ----------------------------------------------------------------- |
| `idle`        | Started; no check has finished yet.                                     | —                                           | —                                                                 |
| `checking`    | A check is running.                                                     | —                                           | —                                                                 |
| `upToDate`    | The last check found no build to install.                               | only when a newer build needs a newer macOS | only then: `v0.5.0(61) requires macOS 27.0.`                      |
| `available`   | A newer build was found and is not downloaded.                          | the newer build                             | —                                                                 |
| `downloading` | The newer build is being downloaded and verified.                       | the newer build                             | —                                                                 |
| `ready`       | The newer build is verified in the cache and waits for the app to quit. | the newer build                             | only after a failed restart (step 4 of [Installing](#installing)) |
| `installing`  | The app is quitting; the bundle is about to be replaced.                | the newer build                             | —                                                                 |
| `error`       | The last check, download or install failed.                             | the build concerned, when there is one      | the reason                                                        |

| From                                     | Event                                                                    | To            |
| ---------------------------------------- | ------------------------------------------------------------------------ | ------------- |
| start                                    | observers registered                                                     | `idle`        |
| `idle`, `upToDate`, `available`, `error` | check due, or `check` received                                           | `checking`    |
| `checking`                               | no release (404), or rows 1 and 2 of [Decision](#decision)               | `upToDate`    |
| `checking`                               | row 3 of [Decision](#decision), or a feed failure                        | `error`       |
| `checking`                               | row 4 of [Decision](#decision)                                           | `available`   |
| `available`                              | `autoUpdate` true, or `install` received                                 | `downloading` |
| `error` with a build                     | `install` received                                                       | `downloading` |
| `downloading`                            | step 9 of [Download and verification](#download-and-verification) passed | `ready`       |
| `downloading`                            | a step failed                                                            | `error`       |
| `ready`                                  | `app.quitting` received                                                  | `installing`  |
| `installing`                             | the app still runs 60 seconds later                                      | `ready`       |
| `installing`                             | the bundle is replaced, or replacing it failed                           | process exits |

Every notification not listed for the current state leaves the state unchanged and makes the Updater post its current status again.

## About window

HephaestusV2 ▸ About HephaestusV2 opens the About window, a `Window` scene with id `about` ([Windows](ui.md#windows)): title `About HephaestusV2`, fixed width 360 points, height fitting its content, not resizable, not restored at launch. Choosing the menu item while the window is open brings it to front. The size is Default chosen at design time.

Content, centred, top to bottom:

| Element     | Content                                                                                               |
| ----------- | ----------------------------------------------------------------------------------------------------- |
| Icon        | The app icon, 96 × 96 points.                                                                         |
| Name        | `HephaestusV2`, title font.                                                                           |
| Version     | `Version 0.4.0 (57)` from `CFBundleShortVersionString` and `CFBundleVersion`; the text is selectable. |
| Update area | One line of text and its controls, from the table below.                                              |

Each time the window appears (opened while it was closed), the app posts `check` when the Updater runs, and the update area shows `Checking for updates…` until a status that answers it arrives. The rows are evaluated in order; the first that holds applies.

| #   | Situation                                                                                      | Text                                                       | Controls                              |
| --- | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------- |
| 1   | The Updater was not started or stopped for good                                                | The reason ([Starting the Updater](#starting-the-updater)) | none                                  |
| 2   | Install was chosen in this window and the app has not quit                                     | `Installing…` with a small progress indicator              | none                                  |
| 3   | No status arrived within 15 seconds after the app posted its last `check`                      | `The updater is not responding.`                           | `Try Again` (posts `check`)           |
| 4   | Waiting for the answer to the last `check`, or state `idle` or `checking`                      | `Checking for updates…` with a small progress indicator    | none                                  |
| 5   | State `upToDate` without a message                                                             | `No update available`                                      | none                                  |
| 6   | State `upToDate` with a message                                                                | The message                                                | none                                  |
| 7   | State `available`, `downloading` or `ready`, and Not Now was clicked since the window appeared | `v0.5.0(61) available`                                     | none                                  |
| 8   | State `available`, `downloading` or `ready`                                                    | `v0.5.0(61) available`                                     | `Install` (default button), `Not Now` |
| 9   | State `error`                                                                                  | The message                                                | `Try Again`                           |

- **Install** marks the install as chosen by the user (row 2). In state `ready` the [restart checks](#restart-rules) run at once; otherwise the app posts `install` (when the state is `available`) and runs the restart checks when `ready` arrives. Cancelling a restart check clears the mark, so the window shows row 8 again. An `error` status after Install clears the mark and shows row 9. When the restart sequence fails at step 3 of [Restart for an update](#restart-for-an-update), the mark is cleared and the window shows `The updater did not respond; the update was not installed.` with Install and Not Now. Closing the window does not cancel a chosen install.
- **Not Now** hides the two buttons until the window closes. It changes neither automatic updates nor a `ready` update.
- **Try Again** posts `install` when the error carries a build, and `check` otherwise.
- Rows 1, 3 and 9, the timeout and the Try Again button are Default chosen at design time.

## Update-ready banner

When the state is `ready` and the user did not choose Install, every main window of this app shows the banner ([Main window layout](ui.md#main-window-layout)) over the top of its columns, full width, 36 points high, whatever device the window shows:

| `autoUpdate` | Text                                           | Controls      |
| ------------ | ---------------------------------------------- | ------------- |
| true         | `Update v0.5.0(61) ready — restarts when idle` | `Restart Now` |
| false        | `Update v0.5.0(61) ready`                      | `Restart Now` |

- Restart Now runs the [restart checks](#restart-rules), then the restart sequence.
- The banner has no close button. It disappears when the restart sequence starts or the state leaves `ready`.
- When the restart sequence fails at step 3 of [Installing](#installing), the banner shows `The updater did not respond; the update was not installed.` with Restart Now.
- The position and height are Default chosen at design time.

## Settings

Settings > Updates ([Updates](ui.md#updates)) edits `autoUpdate` and `updateCheckIntervalMinutes`, shows `HephaestusReleaseRepository` read-only and has Check Now:

- Check Now posts `check`. Its status line shows the text of the About window's update area (rows 1 and 3 to 9), without its controls.
- When the Updater is not running, Check Now is disabled and the status line shows the reason of [Starting the Updater](#starting-the-updater).
- A change of either setting reaches the Updater through `check` ([IPC](#ipc)).

## Security

- The feed and the downloads use HTTPS only (`api.github.com` and the asset URLs GitHub returns).
- The SHA-256 and the size of the zip come from `release.json` of the same release. The bundle id, version and build of the unpacked app must match the manifest, and its signature must pass `codesign --verify --deep --strict`.
- When the running app is signed with a Team ID, only an app signed by the same team is installed. Once releases are signed with a Developer ID, an ad-hoc signed release is therefore refused by every installed copy ([Signing](ci.md#signing)). An ad-hoc signed running app accepts any valid signature; its updates rest on HTTPS and on the repository.
- Distributed notifications carry no sender identity. A process of the same user that posts them can at most start a check, start the download and verification of the latest release, or have a verified update installed when the app quits. A forged `ready` cannot make the app quit, because the app terminates only after the Updater has answered `installing`.
- The Updater runs as the user and never asks for administrator rights; the app does not start it when the bundle's folder is not writable.

## Swift shape

| Type (UpdaterCore) | Kind   | Content                                                                                                                                                                                             |
| ------------------ | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AppVersion`       | struct | `version: String`, `build: Int`; `display` (`v0.4.0(57)`), `aboutLine` (`Version 0.4.0 (57)`); `init?(infoPlist: [String: Any])` (nil when `CFBundleVersion` is not a decimal integer).             |
| `ReleaseManifest`  | struct | `Codable`: `version`, `build`, `sha256`, `size`, `minimumSystemVersion`, `published` (`Date`, ISO-8601), `notes`; `validate() throws` checks the rules of [release.json](ci.md#releasejson).        |
| `GitHubRelease`    | struct | `Decodable`: `tagName` (`tag_name`), `assets: [Asset]`, `Asset { name, browserDownloadURL (browser_download_url) }`.                                                                                |
| `ReleaseFeed`      | struct | `init(repository: String, session: URLSession)`; `latest() async throws -> FeedResult`, `FeedResult` = `.noRelease` or `.release(ReleaseManifest, manifestData: Data, zipURL: URL)`.                |
| `UpdateDecision`   | enum   | `.upToDate`, `.requiresNewerSystem(ReleaseManifest)`, `.previousInstallFailed(ReleaseManifest, String)`, `.available(ReleaseManifest)`; `static func decide(...)` implements [Decision](#decision). |
| `UpdateDownloader` | struct | Steps 1 to 4 of [Download and verification](#download-and-verification).                                                                                                                            |
| `UpdateVerifier`   | struct | Steps 5 to 9; the Team ID reader is injectable for tests.                                                                                                                                           |
| `UpdateInstaller`  | struct | Steps 5 to 8 of [Restart for an update](#restart-for-an-update) and the `install-failed` file.                                                                                                      |
| `UpdaterState`     | enum   | `String` raw values `idle`, `checking`, `upToDate`, `available`, `downloading`, `ready`, `installing`, `error`.                                                                                     |
| `UpdaterStatus`    | struct | `state`, `version: String?`, `build: Int?`, `message: String?`; `init?(userInfo:)` and `userInfo(pid:)`.                                                                                            |
| `UpdaterIPC`       | enum   | The object string, the five `Notification.Name`s and the `userInfo` keys of [IPC](#ipc).                                                                                                            |
| `UpdaterMachine`   | actor  | The state machine of [Updater states](#updater-states) and the [check schedule](#check-schedule), with the clock, feed, downloader, verifier and installer injected.                                |

The `Updater` executable parses the [command line](#command-line), creates `UpdaterMachine` with the real dependencies, connects it to `UpdaterIPC` and runs the main run loop. The type names are Default chosen at design time.

## Tests

UpdaterCoreTests ([Development](development.md)) cover, without network access and without the real app bundle:

- `AppVersion` parsing, display and the build comparison;
- `ReleaseManifest` decoding and validation, including the example of [release.json](ci.md#releasejson) (a docs conformance test, [CI](ci.md#docs-conformance-tests));
- `ReleaseFeed` with a stubbed `URLProtocol`: 200, 404, 403 with `x-ratelimit-remaining: 0`, 429, 500, missing assets, invalid `release.json`;
- every row of [Decision](#decision);
- every failure of [Download and verification](#download-and-verification), using a small bundle that the test builds and signs ad hoc, and an injected Team ID reader for step 9;
- every transition of [Updater states](#updater-states), the requests ignored in each state, and the `pid` filtering;
- the `userInfo` round trip of every notification of [IPC](#ipc).

## Requirements covered

- R74: The app has a second executable, the Updater.
- R75: The Updater checks periodically whether an update is available.
- R76: When an update is found, the app updates itself automatically.
- R77: The Updater is controlled indirectly from the About menu.
- R78: Once shown, the About window shows the version.
- R79: Once shown, it starts checking for an update.
- R80: It then says "No update available" or "vX.Y.Z(N) available".
- R81: When an update is available, it asks whether the user wants to install it.
- R85: The app then restarts itself, updated.
