# Virtual machines

HephaestusV2 runs macOS virtual machines with Apple's Virtualization framework, so that Claude can check what the offscreen check instance cannot reach: menus, typing, list rows, system dialogs and permission prompts. A virtual machine starts from an image: one macOS version, installed once from its IPSW and prepared once in a setup window, where the user completes Setup Assistant, turns off System Integrity Protection (SIP) and installs the guest agent, which gives the host full control of the guest. This document defines the images and their states, the list of macOS versions read from ipsw.me, the download and the install, the setup window with its texts, the install script, the guest agent and its protocol, the limit of 2 running virtual machines and the storage under `<data dir>/VirtualMachines/`. The Settings tab is in [User interface](ui.md#virtual-machines), the file format in [Data model](data-model.md#image-metadata-file), the methods and the event in [Engine API](engine-api.md#virtual-machine-images).

## Overview

```
Settings ▸ Virtual Machines                      engine of This Mac                        outside
  Add Image… ── vmImages.versions ─────────────► list of macOS versions ◄── GET api.ipsw.me
             ── vmImages.add ──────────────────► download ◄──────────────── GET the IPSW's Apple URL
                                                 install (Virtualization framework)
  Images table ◄── vmImages.changed ──────────── image.yml, state, progress
  Set Up… ───── image setup service ───────────► setup virtual machine ──── screen in the setup window
                                                        ▲ virtio socket, port 47822
                                                 guest agent (LaunchAgent of the account)
  Default radio ── settings.update ────────────► settings.yml, defaultVMImage
  Delete… ───── vmImages.delete ───────────────► the image's folder is deleted
```

| Piece                                  | Defined in                                         |
| -------------------------------------- | -------------------------------------------------- |
| The Settings tab, sheet, alert, window | [User interface](ui.md#virtual-machines)           |
| `image.yml`, `defaultVMImage`          | [Data model](data-model.md#image-metadata-file)    |
| `vmImages.*`, `vmImages.changed`       | [Engine API](engine-api.md#virtual-machine-images) |
| The entitlement, the bundle files      | [CI and release](ci.md#entitlements)               |
| The agent's target, the processes      | [Architecture](architecture.md#modules)            |

## Host

- Virtual machines run only on a Mac with Apple silicon: the Virtualization framework runs macOS guests on no other Mac. On an Intel Mac, `vmImages.add` and `Set Up…` fail with `unavailable` and the message `Virtual machines need a Mac with Apple silicon.` Default chosen at design time.
- The app process needs the entitlement `com.apple.security.virtualization`, which `scripts/build-app.sh` gives every bundle it signs ([Entitlements](ci.md#entitlements)). A process without it, such as a test run, cannot create a virtual machine: the framework's error becomes the failure of the install or of `Set Up…`.
- Every virtual machine runs inside the app process's own Virtualization service ([Processes](architecture.md#processes)); the engine starts no other process for it.

## Images

An image is one macOS version installed on a disk, with the values its virtual machines start with: `cores`, `memoryGB` and `diskGB`. Each virtual machine started from the image uses them unless it asks for others. An image has an id, a UUID, which names its folder; its metadata is the [image metadata file](data-model.md#image-metadata-file). Two images may hold the same macOS version. Default chosen at design time.

`GB` stands for 1024³ bytes in `memoryGB`, in `diskGB` and in the fields of the Add Image sheet: 4 GB of memory are 4,294,967,296 bytes. Default chosen at design time.

### Image states

| State       | `state`       | Text of the State column | Meaning                                                                                            |
| ----------- | ------------- | ------------------------ | -------------------------------------------------------------------------------------------------- |
| Downloading | `downloading` | `Downloading… <n>%`      | The IPSW of the version is being downloaded.                                                       |
| Installing  | `installing`  | `Installing… <n>%`       | macOS is being installed into the image's disk, or the install waits for a free virtual machine.   |
| Needs setup | `needsSetup`  | `Needs setup`            | macOS is installed; the setup is not finished. `Set Up…` is enabled.                               |
| Ready       | `ready`       | `Ready`                  | The setup is finished: virtual machines can start from the image, and it can be the default image. |
| Failed      | `failed`      | `Failed: <message>`      | The download or the install failed; `<message>` is the image's `failure` ([Failures](#failures)).  |

```
vmImages.add ─► downloading ─► installing ─► needsSetup ─► ready
                     │              │        (Finish Setup)
                     └──────────────┴─► failed
```

- `<n>` is the image's `progress`, a fraction from 0 to 1, as a percentage rounded down: `Downloading… 42%`. An image without `progress` shows 0.
- No state goes back: a failed image stays failed until the user deletes it, and adding the version again makes a new image. There is no retry. Default chosen at design time.
- The engine emits `vmImages.changed` at every change of state, each time the percentage of an image changes, and when a setup ends without `Finish Setup`: the guest wrote to the image's disk, so the image's `diskBytes` has changed.

### Default image

The default image is the one Claude uses when it asks for no version. The host setting `defaultVMImage` holds its id ([Settings file](data-model.md#settings-file)); the `Default` radio of the Images table shows it and sets it with `settings.update`.

1. The first image that becomes Ready is the default while no image is the default: when `Finish Setup` sets an image to `ready` and `defaultVMImage` is null, the engine sets `defaultVMImage` to that image and emits `settings.updated`.
2. Only a Ready image can be the default: `settings.update` refuses another id with `invalid` and `defaultVMImage: use the id of an image that is Ready.`, and the radio of an image that is not Ready is disabled. Default chosen at design time.
3. Deleting the default image sets `defaultVMImage` to null. No image is the default until the user turns a radio on or another image becomes Ready. Default chosen at design time.
4. At launch, a `defaultVMImage` that names no Ready image is set to null and `settings.yml` is written. A `settings.yml` changed outside the app with such a value is refused as any value `settings.update` refuses ([Reactions](data-model.md#reactions)). Default chosen at design time.

## macOS versions

The `Version` pop-up of the Add Image sheet lists the macOS versions for virtual machines that ipsw.me gives. That list is the only source of versions: the engine asks neither Apple nor the Virtualization framework for one.

`vmImages.versions` sends `GET https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw` with the header `Accept: application/json` and a timeout of 30 seconds, and reads the answer, a JSON object, as follows.

| Member of a `firmwares` element | JSON type | Read as                                                                                         |
| ------------------------------- | --------- | ----------------------------------------------------------------------------------------------- |
| `version`                       | string    | `MacOSVersion.version`, for example `27.2.1`.                                                   |
| `buildid`                       | string    | `MacOSVersion.build`, for example `26B131`.                                                     |
| `url`                           | string    | `MacOSVersion.url`: the Apple URL of the IPSW.                                                  |
| `filesize`                      | integer   | `MacOSVersion.sizeBytes`; 0 when absent.                                                        |
| `sha256sum`                     | string    | `MacOSVersion.sha256`, in lowercase; absent when the member is missing or is not 64 hex digits. |
| `releasedate`                   | string    | The release date, used for the order only.                                                      |

- An element is kept when `version` and `buildid` are strings that are not empty and `url` is an `https` URL; any other element is skipped. When two elements have the same `buildid`, the first is kept. The other members are not read; `signed` is `false` for every element of this device.
- The versions are ordered newest first: by `version`, compared number by number (`27.2.1` before `27.2`, `27.2` before `26.6.2`), then by `releasedate`, the latest first.
- The engine keeps the last list it read in memory, for `vmImages.add`.
- When the request fails, the status is not 200 or the answer is not a JSON object with a `firmwares` array, `vmImages.versions` fails with `unavailable` and `The macOS versions cannot be read from ipsw.me: <reason>.`, `<reason>` being the localized description of the network error, `HTTP <status>` or `unexpected answer`.

The header, the timeout, the rules for the elements and the order within one version are Default chosen at design time.

## Adding an image

`Add` of the Add Image sheet calls `vmImages.add` with the `build` of the chosen version and the values of the fields ([vmImages.add](engine-api.md#vmimagesadd)).

1. The engine checks the values: `cores` from 2 to the number of cores of the Mac, `memoryGB` from 4 to the memory of the Mac in GB, rounded down, `diskGB` from 32 to 2048. A value outside its range fails with `invalid` and `<param>: use a number from <min> to <max>.` The ranges are Default chosen at design time.
2. It finds the version whose `build` equals the param in the list it keeps, reading the list first when it has none ([macOS versions](#macos-versions)); no version: `notFound` `macOS build <build> not found.`
3. It creates the image: a new id, the folder `<data dir>/VirtualMachines/Images/<image id>/` and its `image.yml` with the state `downloading`. It emits `vmImages.changed` and returns the image. The download and the install then run in the background.

### Download

1. The engine sends `GET <url>` to the version's Apple URL and writes the bytes, as they arrive, to `Restore.ipsw` in the image's folder. The request has no overall timeout; it fails after 60 seconds without data.
2. `progress` is the number of bytes received divided by the `Content-Length` of the answer, or by the version's `sizeBytes` when the answer has none.
3. An answer whose status is not 200 fails the image with `The download failed: HTTP <status>.`
4. When ipsw.me gave a `sha256`, the engine computes the SHA-256 of the bytes while it writes them; a different value fails the image with `The downloaded file does not match its checksum.`
5. The image's state becomes `installing`.

The checksum, the timeout and the two messages are Default chosen at design time.

### Install

1. The install takes one of the 2 running virtual machines ([Running virtual machines](#running-virtual-machines)). While 2 already run it waits, and the row shows `Installing… 0%`.
2. The engine reads `Restore.ipsw` with the Virtualization framework (`VZMacOSRestoreImage`) and takes its most featureful configuration that this Mac supports. Without one, the image fails with `This Mac cannot run macOS <version>.` When the image's `cores` or `memoryGB` is below the minimum of that configuration, the image fails with `macOS <version> needs at least <n> cores and <m> GB of memory.` The two messages are Default chosen at design time.
3. It writes the files of the virtual machine in the image's folder: `HardwareModel` (the hardware model of the configuration), `MachineIdentifier` (a new machine identifier), `AuxiliaryStorage` and `Disk.img`, a sparse file of `diskGB` GB.
4. It installs macOS with `VZMacOSInstaller` in a virtual machine that has the image's `cores` and `memoryGB` and the devices of the [setup virtual machine](#setup-virtual-machine), without its shared folder. `progress` is the installer's fraction completed.
5. The IPSW file is deleted once the install ends, whether it succeeded or failed.
6. The image's state becomes `needsSetup`.

### Failures

- A failure of the download or of the install sets the image's state to `failed` and its `failure` to the message: one of the messages above, or the localized description of the error that the network or the Virtualization framework gave, on one line.
- The `Restore.ipsw` of a failed image is deleted; the other files of its folder stay until the user deletes the image.
- Quitting the app ends the downloads and the installs. At the next launch, an image whose `image.yml` holds `downloading` or `installing` becomes `failed` with `The app quit before the image was ready.`, and its `Restore.ipsw` is deleted. Default chosen at design time.

## Setup

An image in `needsSetup` is prepared once, by the user, in the setup window. `Set Up…` belongs to the image setup service, a [local-only service](architecture.md#local-only-services) of This Mac: the screen of a virtual machine shows only on the Mac that runs it, so no engine method starts a setup and no remote device can.

`Set Up…` on the selected image:

1. Brings the image's setup window to front when it is already open. When the window of an earlier setup of the image closed and its virtual machine still shuts down, `Set Up…` first waits for that virtual machine to stop: two virtual machines never share a disk.
2. Otherwise checks that the image exists (`notFound`), that the Mac has Apple silicon ([Host](#host)), that the image is in `needsSetup` (`conflict`, `The image is not waiting for setup.`) and that fewer than 2 virtual machines run (`conflict`, `2 virtual machines are already running.`).
3. Fills the shared folder `<data dir>/Runtime/guest/` with `install.sh` and `hephaestus-agent`, copied from the app bundle ([Bundle layout](ci.md#bundle-layout)), replacing older copies. Without these files in the bundle, as in a process that is not a bundle: `unavailable`, `The guest agent is missing from the app bundle.`
4. Boots the setup virtual machine of the image and opens the setup window. A virtual machine that cannot be made or started fails with `unavailable` and the framework's message.

A failure shows the alert `Set Up failed` with the message ([Principles](ui.md#principles)), on the Settings window. A virtual machine that stops with a failure while it starts counts as one that cannot be started. The checks, their messages and the folder are Default chosen at design time.

### Setup virtual machine

The setup virtual machine boots the image's own disk, so everything the user does in it stays in the image.

| Part            | Configuration                                                                                                                                                          |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Processor       | The image's `cores`.                                                                                                                                                   |
| Memory          | The image's `memoryGB`.                                                                                                                                                |
| Platform        | The image's `HardwareModel`, `MachineIdentifier` and `AuxiliaryStorage`, started with the macOS boot loader.                                                           |
| Disk            | `Disk.img`, a virtio block device.                                                                                                                                     |
| Display         | One display of 2560 × 1600 pixels at 220 pixels per inch.                                                                                                              |
| Keyboard        | A Mac keyboard and a USB keyboard: a guest older than macOS 13 uses the USB one.                                                                                       |
| Pointing device | A Mac trackpad and a USB pointing device with screen coordinates: a guest older than macOS 13 uses the USB one.                                                        |
| Network         | One virtio network device behind the framework's NAT.                                                                                                                  |
| Entropy         | One virtio entropy device.                                                                                                                                             |
| Socket          | One virtio socket device, on which the host listens for the [guest agent](#guest-agent).                                                                               |
| Shared folder   | `<data dir>/Runtime/guest/`, read-only, as a virtio file system with the framework's automount tag for macOS guests: the guest shows it at `/Volumes/My Shared Files`. |

A guest older than macOS 13 mounts no shared folder: macOS has shared directories in virtual machines from macOS 13 on. An image of macOS 12 can therefore not run the install script, and its setup cannot be finished.

The display size and the choice of devices are Default chosen at design time.

### Setup window

The window is titled `Set Up macOS <version>`. It shows the virtual machine's screen, scaled to fit and usable with the user's mouse and keyboard, and beside it, in a column 300 points wide on the right, these steps:

1. `Complete Setup Assistant: create an account and turn on automatic login.`
2. `Turn off SIP:` with a `Restart in Recovery` button, then `In Recovery, open Utilities ▸ Terminal, run csrutil disable, then restart.`
3. `Install the agent: in Terminal, run` followed by the command, in SF Mono, and a `Copy` button.

The command is:

```
sh "/Volumes/My Shared Files/install.sh"
```

Under the steps, a status line and the `Finish Setup` button:

| Agent                                            | Status line                 | `Finish Setup` |
| ------------------------------------------------ | --------------------------- | -------------- |
| Not connected                                    | `Waiting for the agent…`    | disabled       |
| Connected, and it reports SIP disabled           | `Agent connected · SIP off` | enabled        |
| Connected, and it reports SIP enabled or unknown | `Agent connected · SIP on`  | disabled       |

- `Restart in Recovery` restarts the virtual machine into macOS Recovery:
  1. The engine shuts the guest down, so that macOS writes to the image's disk what it still holds, for example the automatic login of step 1. With the agent connected, the agent shuts the guest down, as for `Finish Setup`. Without the agent, or when the agent answers that the command failed, the engine sends the framework's stop request, which acts as the power button of a Mac: macOS asks in the guest whether to shut down, and the user chooses `Shut Down` there.
  2. A virtual machine that has not stopped 30 seconds after the click, or that takes no stop request, is stopped at once, as a power cut does.
  3. The engine starts the virtual machine with the framework's option to start up from macOS Recovery. The guest shows its startup options, where the user chooses `Options`, then `Continue`.

  The button is disabled while the virtual machine restarts. The restart that the user then asks for in Recovery boots macOS normally.
- `Copy` copies the command and reads `Copied` for 2 seconds, as the Copy buttons of Settings do. The command goes to the pasteboard of this Mac. The setup virtual machine shares no pasteboard with this Mac, so the command cannot be pasted in the guest: the user types it there.
- `Finish Setup` shuts the virtual machine down and sets the image to `ready`: the engine asks the agent to run `/sbin/shutdown -h now` as root, waits up to 60 seconds from the click for the virtual machine to stop and stops it itself after that, or at once when the agent answers that the command failed, then writes the image's state, applies the [default image](#default-image) rule, emits `vmImages.changed` and closes the window.
- Closing the window before `Finish Setup` shuts the virtual machine down and leaves the image in `needsSetup`: through the agent when it is connected, waiting up to 30 seconds, otherwise at once, as a power cut does, so that what the guest wrote in its last seconds may be missing from the disk. `Set Up…` starts again from the image's current disk.
- When the guest shuts down by itself, the window closes as when the user closes it.
- When the virtual machine fails while it runs, the setup ends and the image stays in `needsSetup`: the setup window shows the failure alert of [Principles](ui.md#principles), titled `Set Up failed`, with the framework's message, and closes after `OK`. When `Restart in Recovery` cannot start the virtual machine, the alert is titled `Restart in Recovery failed`.
- The setup virtual machine counts as a running virtual machine ([Running virtual machines](#running-virtual-machines)).

The texts of the three steps, the command's place, the status texts `Waiting for the agent…` and `Agent connected · SIP off`, and the buttons are the user's choices. The status text `Agent connected · SIP on`, the way the virtual machine restarts and shuts down, the waits, the closing of the window when the guest shuts down and the alerts of a virtual machine that fails are Default chosen at design time.

### Install script

`install.sh` runs in the guest, in Terminal, as the account that Setup Assistant created; it asks for the account's password once, for `sudo`. It refuses to run as root (`Run this script as your account, without sudo.`) and while SIP is on (`System Integrity Protection is on. Do step 2 first.`), because the privacy database cannot be written then. Its steps, in order:

1. **Agent.** Copies `hephaestus-agent` from the shared folder to `/usr/local/bin/hephaestus-agent`, owned by root, mode 755.
2. **sudo.** Writes `/etc/sudoers.d/hephaestus` with the line `<account> ALL=(ALL) NOPASSWD: ALL`, mode 440, checked first with `visudo -c`: the account gets sudo without a password.
3. **Privacy.** Grants `/usr/local/bin/hephaestus-agent` Accessibility (`kTCCServiceAccessibility`) and Screen Recording (`kTCCServiceScreenCapture`) with one row each in the `access` table of `/Library/Application Support/com.apple.TCC/TCC.db`, the guest's privacy database, which SIP off makes writable. On macOS 15 and later it also records the agent's screen capture approval ([below](#screen-capture-approval)).
4. **LaunchAgent.** Writes `~/Library/LaunchAgents/ca.azavech.hephaestusv2.agent.plist`, which runs the agent in the account's graphical session at every login and restarts it when it exits, and loads it at once.
5. **Claude CLI.** Runs Anthropic's installer, `curl -fsSL https://claude.ai/install.sh | bash`, as the account, and adds `~/.local/bin`, where the installer puts `claude`, to the `PATH` of the account's login shells in `~/.zprofile` when it is missing. When this step fails, the script says so at its end and exits with status 1; the agent stays installed.

The script can be run again: every step replaces what an earlier run wrote. The paths, the label, the file names and the messages are Default chosen at design time.

#### Screen capture approval

In a macOS 26.6.2 guest, the agent's first screenshot raised an alert of macOS in the middle of the screen: `“hephaestus-agent” is requesting to bypass the system private window picker and directly access your screen and audio.`, with the buttons `Allow` and `Open System Settings`. The Screen Recording permission of step 3 did not prevent it, and the screenshots showed the alert until `Allow` was chosen in the guest. A macOS 13.0 guest raised no such alert.

On macOS 15 and later, the script therefore records the agent's approval where `replayd`, a process of macOS, keeps it: `~/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist` of the account, which holds one dictionary per tool, under the path of its executable. The script creates the folder and the file when they are missing, writes the agent's dictionary, then ends `replayd`, which holds the file in memory and reads it again when it starts:

| Key                                 | Value written            |
| ----------------------------------- | ------------------------ |
| `kScreenCaptureApprovalLastAlerted` | `4001-01-01T00:00:00Z`   |
| `kScreenCapturePrivacyHintDate`     | `4001-01-01T00:00:00Z`   |
| `kScreenCapturePrivacyHintPolicy`   | `2592000`                |
| `kScreenCaptureApprovalLastUsed`    | The time of the install. |
| `kScreenCaptureAlertableUsageCount` | `0`                      |

- Seen in the macOS 26.6.2 guest, where these commands were run by hand: with this dictionary, the screenshots that followed raised no alert, and `replayd` kept the two dates. Without a dictionary, and with one that lacked `kScreenCaptureApprovalLastUsed` and `kScreenCaptureAlertableUsageCount`, the alert showed again. With a `kScreenCapturePrivacyHintDate` in the past, macOS showed a reminder at the top of the screen and set a later date.
- Not checked: the other macOS versions, and the script with this step in a guest. The file is no documented interface of macOS.
- A failure of this step does not stop the script: macOS then shows its alert at the agent's first screenshot.

The step, the macOS version it starts at and the values are Default chosen at design time.

## Guest agent

The agent, `hephaestus-agent`, runs in the account's graphical session in every guest, as a LaunchAgent of the account. It talks to the host over virtio-vsock and does what the host asks: it reports its version and the SIP state, takes screenshots of the screen, posts mouse and keyboard events, reads the Accessibility tree, runs commands as the account or as root, and copies files in and out. It runs on every macOS version of the ipsw.me list: it is built for macOS 12.0 and later on Apple silicon ([Build steps](ci.md#build-steps)).

While it runs, the agent keeps the guest's display awake, with a power assertion of the type `PreventUserIdleDisplaySleep`. A macOS 13.0 guest left without input turned its display off and then locked its screen: its screenshots were black, and the events that the agent posted did not wake it. Default chosen at design time.

### Connection

- The host listens on port 47822 of the virtual machine's virtio socket device. The agent connects to that port of the host (`AF_VSOCK`, CID 2) and tries again every 2 seconds while it has no connection.
- One connection at a time: a new connection replaces the one the host holds.
- When the connection ends, the agent connects again, and the host shows the agent as not connected meanwhile.

The port and the delay are Default chosen at design time.

### Frames

Both sides send frames. A frame is:

| Bytes | Content                                                        |
| ----- | -------------------------------------------------------------- |
| 4     | `N`, the length of the JSON part, big-endian, 1 to 16,777,216. |
| 4     | `M`, the length of the data part, big-endian, 0 to 67,108,864. |
| `N`   | One JSON object in UTF-8.                                      |
| `M`   | Raw bytes: a PNG, a part of a file.                            |

A frame that breaks a limit, or whose JSON part is not an object, ends the connection. The agent sends no such frame: an answer that would break a limit is replaced by the error `The answer is over the limits of the protocol.` Default chosen at design time.

### Messages

| Message  | From  | JSON part                                                                                    |
| -------- | ----- | -------------------------------------------------------------------------------------------- |
| hello    | agent | `{"type": "hello", "protocol": 1, "status": <status>}`, the first frame of every connection. |
| request  | host  | `{"type": "request", "id": <integer>, "method": <string>, "params": <object>}`.              |
| response | agent | `{"type": "response", "id": <integer>, "result": <object>}` or `{…, "error": <string>}`.     |

- The agent answers the requests of a connection one at a time, in the order they arrive, each with one response that carries the request's `id`.
- A failed request is answered with `error`, a message of one line; an unknown method with `Unknown method <name>.`; a result that JSON cannot carry, with `The answer cannot be written as JSON.`
- The agent sends no request and the host no response.
- `<status>` is the object below, also the result of the method `status`.

| Member of status  | JSON type | Value                                                                                     |
| ----------------- | --------- | ----------------------------------------------------------------------------------------- |
| `version`         | string    | The agent's version, `1.0` in this version of the app.                                    |
| `sip`             | string    | `disabled`, `enabled` or `unknown`, read from the output of `/usr/bin/csrutil status`.    |
| `user`            | string    | The short name of the account the agent runs as.                                          |
| `osVersion`       | string    | The guest's macOS version, for example `27.2.1`.                                          |
| `osBuild`         | string    | The guest's macOS build, for example `26B131`.                                            |
| `accessibility`   | boolean   | Whether the agent has the Accessibility permission (`AXIsProcessTrusted`).                |
| `screenRecording` | boolean   | Whether the agent has the Screen Recording permission (`CGPreflightScreenCaptureAccess`). |

### Methods

Coordinates are pixels of the screenshot of the main display, from its top-left corner. Paths are absolute paths in the guest, or start with `~/`, the account's home folder.

| Method          | Params                                                                                               | Result                                                         | Data part            |
| --------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- | -------------------- |
| `status`        | none                                                                                                 | The status object.                                             | —                    |
| `screenshot`    | none                                                                                                 | `{width, height, scale}`: pixels, and pixels per point.        | Response: the PNG.   |
| `click`         | `x`, `y`, `button`? (`left` or `right`, default `left`), `count`? (1 to 3, default 1)                | `{}`                                                           | —                    |
| `drag`          | `fromX`, `fromY`, `toX`, `toY`                                                                       | `{}`                                                           | —                    |
| `scroll`        | `x`, `y`, `deltaX`?, `deltaY`? (pixels, default 0; positive values scroll down and right)            | `{}`                                                           | —                    |
| `type`          | `text`                                                                                               | `{}`                                                           | —                    |
| `key`           | `key`, `modifiers`? (an array of `control`, `option`, `shift`, `command`)                            | `{}`                                                           | —                    |
| `uiTree`        | `app`? (a bundle identifier or an app name; the frontmost app when absent), `maxDepth`? (default 40) | `{app, bundleID, pid, tree}`                                   | —                    |
| `exec`          | `command`, `asRoot`? (default false), `timeout`? (seconds, default 60)                               | `{exitStatus, timedOut, stdout, stderr, truncated}`            | —                    |
| `stat`          | `path`                                                                                               | `{exists, isDirectory, size, mode}`                            | —                    |
| `list`          | `path`                                                                                               | `{entries: [{name, isDirectory, size, mode}]}`, sorted by name | —                    |
| `makeDirectory` | `path`                                                                                               | `{}`; the missing parent folders are created                   | —                    |
| `readFile`      | `path`, `offset`? (default 0), `length`? (default and at most 8,388,608)                             | `{size, eof}`                                                  | Response: the bytes. |
| `writeFile`     | `path`, `offset`? (default 0), `truncate`? (default false), `mode`?                                  | `{}`                                                           | Request: the bytes.  |

- **screenshot.** The main display, as a PNG. On macOS 14 and later the agent captures it with ScreenCaptureKit, with the pointer; before, with Core Graphics, without the pointer.
- **click, drag, scroll.** Posted as Core Graphics events at the point; a click with `count` 2 is a double click. A drag presses the left button at the first point, moves to the second in steps and releases.
- **type.** Types the text as Unicode characters, whatever the guest's keyboard layout; a line break types Return and a tab Tab.
- **key.** `key` is one character that the guest's keyboard layout types (`k`, `1`, `,`), for which the agent presses its key, with Shift when the layout types the character only with Shift, or one of `return`, `enter`, `tab`, `space`, `delete`, `forwardDelete`, `escape`, `left`, `right`, `up`, `down`, `home`, `end`, `pageUp`, `pageDown` and `f1` to `f20`. A letter is matched in either case. An unknown key fails with `Unknown key <key>.`: so does a character that the layout does not type, such as `[` on a German layout, and the character of a dead key, such as `^` on a French layout, which types nothing by itself. Only when the layout cannot be read does the agent press the key of the U.S. layout.
- **uiTree.** The Accessibility tree of the app: each element is `{role, subrole?, title?, value?, description?, identifier?, enabled?, focused?, frame?, children?}`, `frame` being `{x, y, width, height}` in screenshot pixels. The tree stops at `maxDepth` levels and 5,000 elements. A `value` longer than 2,000 characters is cut at 2,000. An unpaired surrogate in a string of the app becomes U+FFFD, and an element whose position or size is not a finite number has no `frame`. The app has 5 seconds to answer for each element; an element that does not answer in time is `{}`. Without an app of that name: `No running app named <app>.`
- **exec.** Runs `/bin/zsh -lc <command>`, a login shell, in the account's home folder, as the account, or through `sudo -n` as root. The command gets `/dev/null` as its standard input, no other descriptor of the agent, and the default action of `SIGPIPE`, which the agent itself ignores. `exitStatus` is the command's exit status, or 128 plus the number of the signal that ended it. `stdout` and `stderr` are the outputs decoded as UTF-8, each cut at 1,048,576 bytes with `truncated` true.
  - The answer comes when the command has ended and its outputs have ended. A process that the command left running, as `server &` does, may still hold an output: the agent then answers 1 second after the command ended, with what it read. That process goes on running, and the agent drops what it writes later; a command that needs that output redirects it to a file.
  - At the timeout the agent kills the command's process group, as the account and then through `sudo -n /bin/kill`, because the processes of the group that run as root, as those of a `sudo` in the command, take no signal from the account. It answers with `timedOut` true and the `exitStatus` 137, at the latest 6 seconds after the timeout.
- **stat, list, makeDirectory, readFile, writeFile.** Run as the account. `readFile` returns at most `length` bytes from `offset`, with `eof` true at the end of the file; a larger file is read with several requests. `writeFile` writes the data part at `offset`, creating the file and its missing parent folders; `truncate` empties the file first; `mode` sets its permission bits, for example 493 for 755.
- The events and the Accessibility tree need the Accessibility permission and the screenshot the Screen Recording permission, both granted by the [install script](#install-script). Without the permission the request fails with `The agent has no Accessibility permission.` or `The agent has no Screen Recording permission.`

The methods, their params, results, limits and messages are Default chosen at design time.

## Running virtual machines

The Virtualization framework runs at most 2 macOS virtual machines at once on a Mac. The engine counts every virtual machine it runs:

| Virtual machine           | Counts from              | Until                                                                                     |
| ------------------------- | ------------------------ | ----------------------------------------------------------------------------------------- |
| The install of an image   | The start of the install | The install ends.                                                                         |
| The setup virtual machine | `Set Up…` starts it      | It has stopped: `Finish Setup`, a closed window, a guest that shut down, a deleted image. |

- An install waits while 2 virtual machines run; the installs that wait start in the order they began to wait. Default chosen at design time.
- `Set Up…` does not wait for a free place: it fails with `conflict` ([Setup](#setup)).
- Quitting the app stops every virtual machine ([Shutdown](architecture.md#shutdown)): a setup virtual machine is stopped at once and its image stays in `needsSetup`.
- The app does not restart by itself for an update while an image downloads or installs, while a setup window is open or while the virtual machine of a closed one still shuts down: the app is not idle then ([Restart rules](updater.md#restart-rules)).

## Deleting an image

`Delete…` asks for confirmation with the alert of [User interface](ui.md#virtual-machines), then calls `vmImages.delete`. Delete stops and deletes the image's virtual machines, then deletes the image's folder:

1. The engine ends the image's download or install, and stops its setup virtual machine at once, which closes its setup window.
2. When the image is the default image, `defaultVMImage` becomes null, with `settings.updated`.
3. The folder `<data dir>/VirtualMachines/Images/<image id>/` is deleted with everything in it. It is not moved to the Trash: a disk in the Trash would keep its space. Default chosen at design time.
4. `vmImages.changed` is emitted.

## Storage

```
<data dir>/
  VirtualMachines/
    Images/
      <IMAGE-ID>/               one folder per image, named by the image's id, an uppercase UUID
        image.yml               the image metadata file
        Restore.ipsw            the IPSW, while the image downloads and installs
        HardwareModel           the hardware model the image was installed for
        MachineIdentifier       the machine identifier of the image's own virtual machine
        AuxiliaryStorage        the auxiliary storage of the virtual machine
        Disk.img                the disk, a sparse file of diskGB GB
  Runtime/
    guest/                      the folder shared into the guests
      install.sh                the install script
      hephaestus-agent          the guest agent
```

- The engine creates `VirtualMachines/Images/` with the first image. Folders of `Images/` whose name is not a UUID, or whose `image.yml` is missing or invalid, are skipped and logged at launch ([Loading](data-model.md#loading)).
- The `Disk` column of the Images table is the image's `diskBytes`: the space the files of its folder take on disk, which for the sparse `Disk.img` is the space written so far, not `diskGB`.
- `Runtime/guest/` is generated: the engine fills it each time a virtual machine starts.

The folder and file names are Default chosen at design time.

## Swift shape

| Path                                                           | Content                                                                                                                                                 |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Sources/HephaestusCore/Models/VMImage.swift`                  | `VMImage`, `VMImageState`: the image metadata file.                                                                                                     |
| `Sources/HephaestusCore/VirtualMachines/`                      | The images, the provisioner, the setup and the host side of the agent's protocol: see [HephaestusCore folders](architecture.md#hephaestuscore-folders). |
| `Sources/HephaestusCore/Engine/API/VMImagesAPI.swift`          | The `vmImages.*` methods and `MacOSVersion`.                                                                                                            |
| `Sources/HephaestusCore/Engine/Handlers/VMImageHandlers.swift` | `registerVMImageHandlers()` and the handlers.                                                                                                           |
| `Sources/HephaestusAgent/`                                     | The guest agent: `main.swift`, the connection loop, the frames, the session, one file per group of methods, the display assertion.                      |
| `Resources/install-agent.sh`                                   | The install script, `install.sh` in the shared folder.                                                                                                  |
| `Sources/HephaestusUI/Settings/`                               | `VirtualMachinesSettingsPane`, `AddImageSheet`, and the setup window with the view of a virtual machine's screen (`VZVirtualMachineView`).              |

Outside the app, the engine reaches ipsw.me, Apple's download server and the Virtualization framework only through `VMImageProvisioning`, the `imageProvisioner` of its configuration ([Engine configuration](architecture.md#engine-configuration)): the app uses `SystemVMImageProvisioner`, and tests a stand-in, so that no test downloads an IPSW or starts a virtual machine ([Test rules](development.md#test-rules)).

## Requirements covered

- R201: Settings has a Virtual Machines tab whose Images section adds macOS images for virtual machines from the versions ipsw.me lists, downloads and installs them, prepares each one once in a setup window so that an agent in the guest gives full control of it, marks the default image and deletes images.
