# Virtual machines

HephaestusV2 runs macOS virtual machines with Apple's Virtualization framework, so that Claude can check what the offscreen check instance cannot reach: menus, typing, list rows, system dialogs and permission prompts. A virtual machine starts from an image: one macOS version, installed once from its IPSW and prepared once in a setup window, where the user completes Setup Assistant, turns off System Integrity Protection (SIP) and installs the guest agent, which gives the host full control of the guest. The user starts virtual machines from the Ready images in Settings, keeps them between runs, and shows the screen of one in a main window, where the mouse and the keyboard drive it. A bubble in the toolbar of the main window counts the virtual machines that run, and its popover shows a preview of the screen of each one. Claude starts its own virtual machines with the VM tools of the MCP server, in every chat, joins one that Claude already runs from the same image, and drives them, one action at a time on each virtual machine; Claude's virtual machines stop when they stay idle, and each virtual machine gets the Claude token of Settings when it starts. This document defines the images and their states, the list of macOS versions read from ipsw.me, the download and the install, the setup window with its texts, the install script, the guest agent and its protocol, the virtual machines with their lifecycle, the clone of the image's disk, the limit of 2 running virtual machines, Claude's virtual machines with the join, the wait for a free place, the queue, the idle stop, the rule of the user's virtual machines and the Claude token, the detail of a virtual machine and its link in the inspector's composer, the Virtual Machines bubble with its popover, and the storage under `<data dir>/VirtualMachines/`. The Settings tab is in [User interface](ui.md#virtual-machines), the bubble's toolbar item in [Toolbar](ui.md#toolbar), the file formats in [Data model](data-model.md#image-metadata-file), the methods and the events in [Engine API](engine-api.md#virtual-machine-images), the VM tools in [MCP server](mcp.md#rules-of-the-vm-tools).

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
  New VM… ───── vms.create ────────────────────► vm.yml, clone of the image's disk, boot
  Start, Stop ─ vms.start, vms.stop ───────────► the virtual machine boots, shuts down
  Virtual Machines table ◄── vms.changed ─────── the virtual machines, the number that run
  Delete… ───── vms.delete ────────────────────► the virtual machine's folder is deleted
  Show ──────── navigation ────────────────────► the detail in a main window ── screen service
Claude section ── settings.update ─────────────► settings.yml, claudeVMIdleMinutes
               ── Claude VM token service ─────► secrets.json, claudeVMToken
Main window toolbar
  Bubble ◄──── vms.changed, setup windows ────── the virtual machines that run, the setup ones included
  Popover ───── VM screens, image setup ───────► a screenshot by the guest agent, every 2 seconds
chat of Claude
  vm_start, vm_stop ── vmTools.start, .stop ───► Claude's virtual machines: join, wait, idle stop
  vm_click, vm_shell… ── vmTools.* ────────────► the queue of the virtual machine ── agent requests
```

| Piece                                  | Defined in                                         |
| -------------------------------------- | -------------------------------------------------- |
| The Settings tab, sheet, alert, window | [User interface](ui.md#virtual-machines)           |
| `image.yml`, `defaultVMImage`          | [Data model](data-model.md#image-metadata-file)    |
| `vm.yml`                               | [Data model](data-model.md#vm-metadata-file)       |
| `vmImages.*`, `vmImages.changed`       | [Engine API](engine-api.md#virtual-machine-images) |
| `vms.*`, `vms.changed`                 | [Engine API](engine-api.md#virtual-machines)       |
| The `virtualMachine` target            | [User interface](ui.md#resolving-a-target)         |
| The linked item of the detail          | [Chats](chats.md#linked-items)                     |
| The Virtual Machines bubble            | [User interface](ui.md#toolbar)                    |
| The entitlement, the bundle files      | [CI and release](ci.md#entitlements)               |
| The agent's target, the processes      | [Architecture](architecture.md#modules)            |
| The VM tools                           | [MCP server](mcp.md#rules-of-the-vm-tools)         |
| `vmTools.*`                            | [Engine API](engine-api.md#vm-tools)               |
| `claudeVMIdleMinutes`                  | [Data model](data-model.md#settings-file)          |
| `claudeVMToken`, its service           | [Data model](data-model.md#secrets-file)           |

## Host

- Virtual machines run only on a Mac with Apple silicon: the Virtualization framework runs macOS guests on no other Mac. On an Intel Mac, `vmImages.add`, `Set Up…`, `vms.create` and `vms.start` fail with `unavailable` and the message `Virtual machines need a Mac with Apple silicon.` Default chosen at design time.
- The app process needs the entitlement `com.apple.security.virtualization`, which `scripts/build-app.sh` gives every bundle it signs ([Entitlements](ci.md#entitlements)). A process without it, such as a test run, cannot create a virtual machine: the framework's error becomes the failure of the install, of `Set Up…` or of the start of a virtual machine.
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

The agent, `hephaestus-agent`, runs in the account's graphical session in every guest, as a LaunchAgent of the account. It talks to the host over virtio-vsock and does what the host asks: it reports its version and the SIP state, takes screenshots of the screen, posts mouse and keyboard events, reads the Accessibility tree, runs commands as the account or as root, copies files in and out, and sets variables of the environment. It runs on every macOS version of the ipsw.me list: it is built for macOS 12.0 and later on Apple silicon ([Build steps](ci.md#build-steps)).

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
| `version`         | string    | The agent's version, `1.1` in this version of the app.                                    |
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
| `setEnv`        | `name`, `value`                                                                                      | `{}`                                                           | —                    |

- **screenshot.** The main display, as a PNG. On macOS 14 and later the agent captures it with ScreenCaptureKit, with the pointer; before, with Core Graphics, without the pointer.
- **click, drag, scroll.** Posted as Core Graphics events at the point; a click with `count` 2 is a double click. A drag presses the left button at the first point, moves to the second in steps and releases.
- **type.** Types the text as Unicode characters, whatever the guest's keyboard layout; a line break types Return and a tab Tab.
- **key.** `key` is one character that the guest's keyboard layout types (`k`, `1`, `,`), for which the agent presses its key, with Shift when the layout types the character only with Shift, or one of `return`, `enter`, `tab`, `space`, `delete`, `forwardDelete`, `escape`, `left`, `right`, `up`, `down`, `home`, `end`, `pageUp`, `pageDown` and `f1` to `f20`. A letter is matched in either case. An unknown key fails with `Unknown key <key>.`: so does a character that the layout does not type, such as `[` on a German layout, and the character of a dead key, such as `^` on a French layout, which types nothing by itself. Only when the layout cannot be read does the agent press the key of the U.S. layout.
- **uiTree.** The Accessibility tree of the app: each element is `{role, subrole?, title?, value?, description?, identifier?, enabled?, focused?, frame?, children?}`, `frame` being `{x, y, width, height}` in screenshot pixels. The tree stops at `maxDepth` levels and 5,000 elements. A `value` longer than 2,000 characters is cut at 2,000. An unpaired surrogate in a string of the app becomes U+FFFD, and an element whose position or size is not a finite number has no `frame`. The app has 5 seconds to answer for each element; an element that does not answer in time is `{}`. Without an app of that name: `No running app named <app>.`
- **exec.** Runs `/bin/zsh -lc <command>`, a login shell, in the account's home folder, as the account, or through `sudo -n` as root. The command gets `/dev/null` as its standard input, no other descriptor of the agent, and the default action of `SIGPIPE`, which the agent itself ignores. `exitStatus` is the command's exit status, or 128 plus the number of the signal that ended it. `stdout` and `stderr` are the outputs decoded as UTF-8, each cut at 1,048,576 bytes with `truncated` true.
  - The answer comes when the command has ended and its outputs have ended. A process that the command left running, as `server &` does, may still hold an output: the agent then answers 1 second after the command ended, with what it read. That process goes on running, and the agent drops what it writes later; a command that needs that output redirects it to a file.
  - At the timeout the agent kills the command's process group, as the account and then through `sudo -n /bin/kill`, because the processes of the group that run as root, as those of a `sudo` in the command, take no signal from the account. It answers with `timedOut` true and the `exitStatus` 137, at the latest 6 seconds after the timeout.
- **stat, list, makeDirectory, readFile, writeFile.** Run as the account. `readFile` returns at most `length` bytes from `offset`, with `eof` true at the end of the file; a larger file is read with several requests. `writeFile` writes the data part at `offset`, creating the file and its missing parent folders; `truncate` empties the file first; `mode` sets its permission bits, for example 493 for 755.
- **setEnv.** Sets the environment variable `name` to `value` in the agent's own environment, which the commands that `exec` starts afterwards inherit, then runs `/bin/launchctl setenv <name> <value>` as the account, so that the apps that launchd starts afterwards in the account's session inherit it too. `name` is letters, digits and `_`, not starting with a digit (`name: use letters, digits and _, not starting with a digit.`); a `launchctl` that fails fails the request with its standard error. The engine sends it with the [Claude token](#claude-token). Agents of version 1.0 do not have it.
- The events and the Accessibility tree need the Accessibility permission and the screenshot the Screen Recording permission, both granted by the [install script](#install-script). Without the permission the request fails with `The agent has no Accessibility permission.` or `The agent has no Screen Recording permission.`

The methods, their params, results, limits and messages are Default chosen at design time.

## Lifecycle

A virtual machine is a Mac started from a Ready image: it has a name, its own disk, which starts as a clone of the image's disk, and the cores and the memory chosen for it. It has an id, a UUID, which names its folder; its metadata is the [VM metadata file](data-model.md#vm-metadata-file). The user starts virtual machines with `New VM…` of [Settings](ui.md#virtual-machines); Claude starts its own for its checks. Who started a virtual machine decides what becomes of it when it stops:

| Started by | `startedBy`                                         | `Started by` column                                                                     | When it stops                                                              |
| ---------- | --------------------------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| The user   | `user`                                              | `You`                                                                                   | It keeps its disk: `Start` boots it again from that disk, until `Delete…`. |
| Claude     | `claude`, with `projectID` and `chatID` of its chat | `<project id> · <chat name>`, the chat's current title; `<project id>` without the chat | It is deleted with its disk: it is listed only while it runs.              |

- The engine function that starts a virtual machine takes who starts it. `vms.create` starts one for the user, and the tool `vm_start` one for Claude ([Claude's virtual machines](#claudes-virtual-machines)).
- `<chat name>` follows the chat's title, renames included. The text `<project id>` alone for a chat that no longer exists is Default chosen at design time.
- Several virtual machines may have the same name, and several may start from the same image. Default chosen at design time.

### Virtual machine states

| State   | `state`   | Text of the State column | Meaning                                                                                              |
| ------- | --------- | ------------------------ | ---------------------------------------------------------------------------------------------------- |
| Running | `running` | `Running · <time>`       | The virtual machine has started and has not stopped yet: it counts among the 2 that run.             |
| Stopped | `stopped` | `Stopped`                | The virtual machine does not run. `Start` boots it from its disk. Only a user's one is ever stopped. |

- `<time>` is the running time, the time since the virtual machine's `startedAt` in whole minutes, rounded down: `<m> min` under an hour, and `<h> h <mm> min` from an hour on, the minutes written with two digits. `0 min`, `12 min`, `59 min`, `1 h 00 min`, `1 h 05 min`, `26 h 40 min`.
- The text changes when the minute does, without an event: each view computes it from `startedAt`.
- A virtual machine that shuts down stays Running until it has stopped.
- `state` and `startedAt` are never stored: after a launch every virtual machine is Stopped.

The hours that go on past 24, the virtual machine that stays Running while it shuts down and the two digits of `1 h 00 min` are Default chosen at design time.

### Creating

`Start` of the New VM sheet calls `vms.create` with the name, the image, the cores and the memory ([vms.create](engine-api.md#vmscreate)).

1. The engine checks, in this order:
   1. that the Mac has Apple silicon ([Host](#host));
   2. the name: one line of 1 to 100 characters once trimmed, otherwise `invalid` and `name: use 1 to 100 characters on one line.`;
   3. that the image exists (`notFound`, `Image <id> not found.`) and is Ready (`conflict`, `The image is not Ready.`);
   4. `cores` and `memoryGB`, with the ranges of [Adding an image](#adding-an-image) and its message;
   5. that fewer than 2 virtual machines run (`conflict`, `2 virtual machines are already running.`).
2. It creates the virtual machine: a new id and the folder `<data dir>/VirtualMachines/Machines/<VM id>/`, into which it copies the image's `HardwareModel`, `MachineIdentifier` and `AuxiliaryStorage`, clones the image's `Disk.img` ([Clone](#clone)) and writes `vm.yml`. When a file cannot be written, on a full disk for example, the folder is deleted and the call fails with `internal` and `The virtual machine could not be created: <reason>.`, `<reason>` being the system's message.
3. It starts the virtual machine ([Starting](#starting)). When the start fails, the call fails with the message of the start; a user's virtual machine stays, Stopped, with its disk, and Claude's is deleted.

The name's rule, the order of the checks and the messages are Default chosen at design time.

### Clone

The disk of a new virtual machine is an APFS clone of the image's `Disk.img`, made with `clonefile`: the two files share their blocks until one of them changes, so the clone is made at once, whatever the size of the disk, and takes no space of its own until the guest writes. On a volume that cannot clone a file, the disk is copied instead. The copy on such a volume is Default chosen at design time.

The virtual machine keeps the hardware model and the machine identifier of its image and starts from a copy of the image's auxiliary storage, so every virtual machine of an image has the identity that the image was set up with. Default chosen at design time. Not checked in a guest: that two virtual machines of one image run at once with the same machine identifier, and that the guest keeps SIP off with it.

### Starting

`vms.create`, and `vms.start` for a Stopped virtual machine ([vms.start](engine-api.md#vmsstart)), start a virtual machine:

1. It takes one of the 2 running virtual machines ([Running virtual machines](#running-virtual-machines)). While 2 already run, the start fails with `conflict` and `2 virtual machines are already running.`
2. The engine makes the virtual machine with its `cores`, its `memoryGB`, the files of its folder and the devices of the [setup virtual machine](#setup-virtual-machine), without its shared folder, and boots it from its disk.
3. A virtual machine that cannot be made or started, or that stops with a failure while it starts, fails the start with `unavailable` and the framework's message, and frees its place.
4. The virtual machine is Running, with the time of the start as `startedAt`, and `vms.changed` is emitted.

Each start listens for the [guest agent](#guest-agent) on the virtual machine's virtio socket device, as the setup virtual machine does. The devices and the missing shared folder are Default chosen at design time.

### Stopping

`Stop` calls `vms.stop` ([vms.stop](engine-api.md#vmsstop)), which shuts the virtual machine down and returns once it has stopped:

1. With the agent connected, the engine asks it to run `/sbin/shutdown -h now` as root, so that macOS writes to the disk what it still holds, and waits up to 60 seconds from the call for the virtual machine to stop. After that, or at once when the agent answers that the command failed, it stops the virtual machine itself.
2. Without the agent, as while the guest starts up, the virtual machine is stopped at once, as a power cut does: what the guest wrote in its last seconds may be missing from the disk.
3. A second `vms.stop` for a virtual machine that shuts down waits for that same shutdown.

A virtual machine also stops when the guest shuts down by itself, from its Apple menu for example, and when it fails while it runs; the framework's message of such a failure goes to `engine.log`. However it stopped:

- its place among the 2 running virtual machines is freed;
- a user's virtual machine becomes Stopped and keeps its folder;
- Claude's virtual machine is deleted: its folder is deleted with everything in it, and it leaves the list;
- `vms.changed` is emitted.

The shutdown through the agent, the wait, the power cut without the agent and the log are Default chosen at design time.

### Deleting a virtual machine

`Delete…` asks for confirmation with the alert of [User interface](ui.md#virtual-machines), then calls `vms.delete` ([vms.delete](engine-api.md#vmsdelete)):

1. A virtual machine that runs is stopped at once, as a power cut does: its disk is deleted anyway.
2. Its folder `<data dir>/VirtualMachines/Machines/<VM id>/` is deleted with everything in it. It is not moved to the Trash, as for an [image](#deleting-an-image).
3. `vms.changed` is emitted, and every window that shows the virtual machine's [detail](#detail) leaves it.

When the folder cannot be deleted, the call fails with `internal` and the virtual machine stays, Stopped. Any virtual machine can be deleted, Claude's too. Default chosen at design time.

## Running virtual machines

The Virtualization framework runs at most 2 macOS virtual machines at once on a Mac. The engine counts every virtual machine it runs:

| Virtual machine           | Counts from                           | Until                                                                                                       |
| ------------------------- | ------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| The install of an image   | The start of the install              | The install ends.                                                                                           |
| The setup virtual machine | `Set Up…` starts it                   | It has stopped: `Finish Setup`, a closed window, a guest that shut down, a deleted image.                   |
| A virtual machine         | `vms.create` or `vms.start` starts it | It has stopped: `Stop`, a guest that shut down, a failure, `Delete…`, a deleted image, the quit of the app. |

- Every virtual machine of the table counts, whoever started it: the user's, Claude's, the setup virtual machine of an image and its install.
- An install waits while 2 virtual machines run; the installs that wait start in the order they began to wait. Default chosen at design time.
- `Set Up…` does not wait for a free place: it fails with `conflict` ([Setup](#setup)). Neither do `vms.create` and `vms.start`: they fail with `conflict` and `2 virtual machines are already running.` ([Starting](#starting)). The tool `vm_start` waits up to 10 minutes ([Starting and joining](#starting-and-joining)).
- `runningCount` of `vms.list` and of `vms.changed` is the number of virtual machines that count ([VMList](engine-api.md#vmlist)). While it is 2, `New VM…` and `Start` are disabled, in Settings and in the header of a [detail](#detail).
- Quitting the app stops every virtual machine ([Shutdown](architecture.md#shutdown)): a setup virtual machine is stopped at once and its image stays in `needsSetup`; a virtual machine is stopped at once too, as a power cut does, the user's keeps its disk and Claude's is deleted. Stopping them at once is Default chosen at design time.
- The app does not restart by itself for an update while an image downloads or installs, while a setup window is open, while the virtual machine of a closed one still shuts down or while a virtual machine runs: the app is not idle then ([Restart rules](updater.md#restart-rules)).

## Claude's virtual machines

Claude starts and drives virtual machines with the VM tools of the MCP server, in every chat that HephaestusV2 starts, in every project ([Rules of the VM tools](mcp.md#rules-of-the-vm-tools)): `vm_list_images` and `vm_list` list the images and the virtual machines, `vm_start` and `vm_stop` start and stop Claude's virtual machines, and the actions `vm_screenshot`, `vm_click`, `vm_drag`, `vm_scroll`, `vm_type`, `vm_key`, `vm_ui_tree`, `vm_shell`, `vm_copy_in` and `vm_copy_out` drive one. The system prompt tells Claude to start one freely whenever a check needs one ([Default: common](skills.md#default-common)).

### Starting and joining

`vm_start` gives the calling chat a virtual machine of an image, in these steps:

1. **Mac.** On a Mac without Apple silicon the call fails as `vms.create` does ([Host](#host)).
2. **Image.** Without `image`, the [default image](#default-image); while no image is the default, the call fails with `conflict` and `No image is the default; name one with image.` An `image` that is a UUID names the image with that id (`notFound`, `Image <id> not found.`). Any other value is a macOS version, compared exactly with the `version` of the Ready images: the default image when it has that version, else the oldest of them (`notFound`, `No Ready image of macOS <version>.`). The image must be Ready (`conflict`, `The image is not Ready.`).
3. **Values.** `name`, `cores` and `memory` are checked as `vms.create` checks the name, `cores` and `memoryGB` ([Creating](#creating)); `cores` and `memory` are the image's `cores` and `memoryGB` when absent.
4. **Joining.** When a virtual machine that Claude started from that image runs, or starts, and is neither shutting down nor being deleted, the chat joins it: the call returns that virtual machine and starts nothing. With several, the oldest. Any chat joins it, whichever chat started it, and its name, cores and memory stay as they are.
5. **Starting.** Otherwise, while fewer than 2 virtual machines run ([Running virtual machines](#running-virtual-machines)), the engine creates and starts a new virtual machine as `vms.create` does ([Creating](#creating), [Starting](#starting)), with `startedBy` `claude` and the `projectID` and `chatID` of the calling chat, so that its `Started by` column reads `<project id> · <chat name>` ([Lifecycle](#lifecycle)). A start that fails fails the call, with the errors of `vms.create`.
6. **Waiting.** While 2 run, the call waits. Each time a place frees up, or a virtual machine of Claude starts, it takes steps 4 and 5 again. After 10 minutes of wait it fails with `unavailable` and `2 virtual machines are still running after a wait of 10 minutes.` A call that waits takes no place: an install that waits gets a freed place first ([Install](#install)). The quit of the app ends the wait with the same failure.
7. **Agent.** The call then waits for the virtual machine's agent: it returns once the agent is connected and has been given the [Claude token](#claude-token), at most 3 minutes after the virtual machine started or was joined; after that it returns the virtual machine all the same, with `agentConnected` false.
8. **Idle time.** The [idle time](#idle-stop) of the virtual machine starts again from the end of the call.

The 10 minutes of the wait, the join and the `Started by` text come from the user ([R204](requirements.md#requirements)). The order of the steps, the choice of an image and of a virtual machine among several, the messages, the wait for the agent and the idle time that starts again are Default chosen at design time.

### Actions and their queue

The ten tools from `vm_screenshot` to `vm_copy_out` are the actions on a virtual machine. Each virtual machine has one queue:

- The actions of every chat on one virtual machine run one at a time, in the order the engine receives them: an action starts once the actions received before it have ended, whatever their chat.
- When its turn comes, an action needs a virtual machine that runs: one that is stopped fails it with `conflict` and `The virtual machine “<name>” is not running.`; one that left the list, with `notFound` and `Virtual machine <id> not found.`
- An action whose virtual machine's agent is not connected, or has not been given the token yet, waits for it up to 60 seconds, keeping its turn, then fails with `unavailable` and `The agent of “<name>” is not connected.`
- Each action sends one request or more to the [agent](#methods), in the table below. A request has 60 seconds to be answered, `uiTree` 120 seconds and `exec` its `timeout` plus 15 seconds. A request that the agent fails fails the action with `unavailable` and the agent's message; a connection that ends, with `The agent of “<name>” disconnected.`; a request that gets no answer in time, with `The agent of “<name>” did not answer in time.`
- `vm_stop` is not an action: it does not wait for the queue, and the actions that wait fail as above once the virtual machine has stopped.

| Tool            | Requests of the agent                                                                                                                                                                                                                                    |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `vm_screenshot` | `screenshot`; the engine writes the PNG on this Mac.                                                                                                                                                                                                     |
| `vm_click`      | `click`.                                                                                                                                                                                                                                                 |
| `vm_drag`       | `drag`.                                                                                                                                                                                                                                                  |
| `vm_scroll`     | `scroll`.                                                                                                                                                                                                                                                |
| `vm_type`       | `type`.                                                                                                                                                                                                                                                  |
| `vm_key`        | `key`, with the key and the modifiers of the menu notation.                                                                                                                                                                                              |
| `vm_ui_tree`    | `uiTree`.                                                                                                                                                                                                                                                |
| `vm_shell`      | `exec`.                                                                                                                                                                                                                                                  |
| `vm_copy_in`    | A file: `writeFile`, 8 MiB at a time. A folder: a tar archive of its content made on this Mac with `/usr/bin/tar`, written to `/tmp/` of the guest with `writeFile`, then `exec` of `/usr/bin/tar -x` into the destination and of the archive's removal. |
| `vm_copy_out`   | `stat`, then for a file `readFile`, 8 MiB at a time; for a folder `exec` of `/usr/bin/tar -c` of its content into `/tmp/` of the guest, `readFile` of the archive, `exec` of its removal, and `/usr/bin/tar -x` of the archive on this Mac.              |

The one-at-a-time order across chats comes from the user ([R204](requirements.md#requirements)); the waits, the messages, the chunks and the archives are Default chosen at design time.

### Idle stop

- A virtual machine that Claude started stops, and is then deleted as every virtual machine of Claude that stops ([Stopping](#stopping)), after `claudeVMIdleMinutes` minutes without an action queued or running. The setting is `Stop Claude's idle VMs after` of Settings › Virtual Machines › Claude, from 1 to 1440, 10 by default ([Settings file](data-model.md#settings-file), [User interface](ui.md#virtual-machines)).
- Its idle time starts when it has started, again each time `vm_start` returns it, started or joined, and each time its queue becomes empty; an action received ends it.
- It stops as `vms.stop` stops a virtual machine: through the agent, waiting up to 60 seconds, then at once. `engine.log` gets `virtual machine <id> stopped after <n> minutes without an action`.
- A change of the setting applies at once to the virtual machines that are idle: one idle for longer than the new value stops at once.
- The user's virtual machines never stop for this, and the user's mouse and keyboard in a [detail](#detail) are no action.

The idle stop, its setting and its default come from the user ([R204](requirements.md#requirements)); the moments the idle time starts again, the change applied at once and the log line are Default chosen at design time.

### The user's virtual machines

- Claude acts on a virtual machine that the user started only when the user names it in the chat, by its name or with its [linked item](#linked-item) chip. The descriptions of the VM tools and the system prompt say so; the engine does not check it, so the actions accept any virtual machine that runs.
- `vm_stop` refuses a virtual machine that the user started, with `forbidden` and `“<name>” was started by the user: only the user stops it.` The descriptions and the system prompt say that Claude never stops one.
- `vm_start` never joins one.

### Claude token

The Claude CLI in a guest runs with the user's Claude account through a token that the user creates on this Mac with `claude setup-token` and enters in `Claude token` of Settings › Virtual Machines › Claude ([User interface](ui.md#virtual-machines)).

- The token is stored as `claudeVMToken` in `secrets.json` ([Secrets file](data-model.md#secrets-file)) through the Claude VM token service, a [local-only service](architecture.md#local-only-services): no engine method, MCP tool or remote device reads it, and it is never logged.
- Each time the agent of a virtual machine connects, at each start and again when it connects anew, the engine sends it `setEnv` with the name `CLAUDE_CODE_OAUTH_TOKEN` and the token, before any action. The agent sets the variable in its own environment, which the commands of `exec`, and so of `vm_shell`, inherit, and in the account's environment with `launchctl setenv`, which the apps started afterwards in the guest inherit, Terminal included. The guest's Claude CLI reads it, so `claude -p` runs there without a login.
- The token is never in an image: the setup virtual machine, which boots the image's own disk, never gets it, and neither the engine nor the agent writes it to a disk of a guest.
- Without a token, nothing is sent. A changed token reaches the virtual machines that start afterwards; the running ones keep the one they were given.
- When the agent fails `setEnv`, as an agent of version 1.0 does, `engine.log` gets `virtual machine <id>: the agent did not take the Claude token: <message>`, and the actions run without it.

The field, its storage in `secrets.json` through a local-only service, the variable and the start as the moment it is given come from the user ([R204](requirements.md#requirements)). The method `setEnv`, `launchctl setenv`, the new connections and the log line are Default chosen at design time.

## Detail

`Show` of [Settings](ui.md#virtual-machines), a click on its preview in the [Virtual Machines popover](#previews), a `virtualMachine` target of the app's navigation and `open_in_app` with such a target show the detail of a virtual machine in a main window ([Resolving a target](ui.md#resolving-a-target)): its screen, to look at and to use.

| Property  | Value                                                                                                                                                                                                       |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Window    | `Show`: the frontmost main window that shows This Mac, brought to front; a new main window on This Mac without one ([Choosing the window](ui.md#choosing-the-window)); a preview: the popover's window      |
| Place     | the centre column, in place of the selected section, as the Global Memories view ([Main window layout](ui.md#main-window-layout)); in a window whose device has no project, the welcome view's place        |
| Sidebar   | keeps its rows, none of them selected ([Sidebar](ui.md#sidebar))                                                                                                                                            |
| Inspector | stays; its composer links the virtual machine ([Linked item](#linked-item))                                                                                                                                 |
| Left by   | anything that selects a section, View ▸ Global Memories, View ▸ Internal Skills, a click on a sub project's row, a switch of device, and the end of the virtual machine: `Delete…`, or the stop of Claude's |
| State     | `WindowState.shownVirtualMachineID`, never persisted ([WindowState](ui.md#windowstate))                                                                                                                     |

The header is a pane header, 36 points high ([Pane headers](ui.md#pane-headers)). From its leading edge it shows the virtual machine's name in the headline font, then, in the secondary colour, `macOS <version>` and the text of the State column, `Running · <time>` or `Stopped` ([Virtual machine states](#virtual-machine-states)); at its trailing edge, one button:

| Virtual machine | Button  | Action                                                                      |
| --------------- | ------- | --------------------------------------------------------------------------- |
| Running         | `Stop`  | `vms.stop` ([Stopping](#stopping)).                                         |
| Stopped         | `Start` | `vms.start` ([Starting](#starting)); disabled while 2 virtual machines run. |

Under the header:

- For a Running virtual machine, its screen (`VZVirtualMachineView`), scaled to fit the column with the proportions of its display, on black. A click in the screen gives it the keyboard focus: the user's mouse and keyboard then drive the guest, and while the screen has the focus the system shortcuts, ⌘Tab for example, go to the guest too (`capturesSystemKeys`).
- For a Stopped virtual machine, `Stopped`, centred, in the secondary colour, in place of the screen.

Rules:

- The screen of a virtual machine shows only on the Mac that runs it: the detail shows only in a window that shows This Mac, and a `virtualMachine` target that a remote device's workspace delivers is ignored. The view takes the screen from the VM screens service of [Local-only services](architecture.md#local-only-services), `Engine.virtualMachineSession(_:)`.
- The header and the screen follow `vms.changed`: a virtual machine that stops shows `Stopped` and `Start`, and one that starts again shows its screen.
- When the virtual machine leaves the list, deleted by the user, with its image, or because Claude's stopped, every window that shows its detail goes back to the section it showed before, which the window kept.
- A switch of project keeps the detail, as it keeps the Global Memories view.
- A window restored by macOS, or reopened after a restart for an update, shows its section: the detail is not restored.
- A failed `Stop` or `Start` of the header shows the failure alert of [Principles](ui.md#principles) on the window, titled `Stop failed` or `Start failed`.

### Linked item

While a main window shows the detail, the composer of its inspector's chat, or of its draft, links the virtual machine as a linked item chip ([Linked items](chats.md#linked-items)):

| Chip symbol | Short name                 | `<item>`                             |
| ----------- | -------------------------- | ------------------------------------ |
| `display`   | the virtual machine's name | `virtual machine “<name>” (<VM id>)` |

Claude receives the line `Open in the app: virtual machine “<name>” (<VM id>)` with each message sent while the chip shows, and the `user` item stores the item with the kind `virtualMachine`. × unlinks it until the window leaves the detail, as for the other linked items.

The header's layout, the black around the screen, the capture of the system shortcuts, the text style of `Stopped`, ignoring the target on a remote device, keeping the detail across a switch of project, not restoring it and the alerts are Default chosen at design time. The place, the header's content, the chip and its line come from the user ([R202](requirements.md#requirements)).

## Virtual Machines bubble

Every main window that shows This Mac has the Virtual Machines bubble in its toolbar ([Toolbar](ui.md#toolbar)): it counts the virtual machines that run on This Mac, and its popover shows the screen of each one, stops it and opens it.

### Bubble

- The bubble is a pill of its own, right of the breadcrumb selector's pill and drawn as a pill like it. It holds the symbol `display` and, beside it, the number of the popover's rows: the virtual machines of the user and of Claude that are Running, and the setup virtual machines of the images. At 0 the number is hidden, and the bubble holds the symbol alone.
- The install of an image runs a virtual machine without a screen: it has no row and is not counted, so the number can be lower than `runningCount` ([Running virtual machines](#running-virtual-machines)).
- Its tooltip is `Virtual Machines`. A click opens the popover under the bubble; a click outside the popover closes it.
- A window that shows a remote device has no bubble: the screen of a virtual machine shows only on the Mac that runs it.
- The bubble and its popover follow This Mac's workspace and its setup windows. The workspace reads the virtual machines with `vms.list` when the bubble appears and it holds none yet, then follows `vms.changed` ([DeviceWorkspace](ui.md#deviceworkspace)); the setup virtual machines are those of `imageSetups` and `closingImageSetups` ([AppModel](ui.md#appmodel)). The number and the rows change at once when a virtual machine starts or stops.

### Popover

The popover lists one row per virtual machine that the bubble counts, the one that started first at the top. With none, it reads `No virtual machines running`, in the secondary colour.

A row shows, from its leading edge:

| Part         | Content                                                                                                                                                                                                                                                                                                 |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Preview      | A still image of the virtual machine's screen, 160 × 100 points ([Previews](#previews)).                                                                                                                                                                                                                |
| Name         | Beside the preview, in the headline font: the virtual machine's name, or `Set Up macOS <version>` for the setup virtual machine of an image, the title of its setup window.                                                                                                                             |
| Started by   | Under the name, in the secondary colour: `Started by you` for a virtual machine of the user and for a setup virtual machine; `<project id> · <chat name>` for one that Claude started, or `<project id>` alone once its chat no longer exists, as in the `Started by` column ([Lifecycle](#lifecycle)). |
| Running time | Under it, in the secondary colour: `<m> min` under an hour and `<h> h <mm> min` after, changing with the minute, as in the State column ([Virtual machine states](#virtual-machine-states)). A setup virtual machine runs from `Set Up…` on: `Restart in Recovery` does not start its time again.       |
| `Stop`       | At the trailing edge ([Stop](#stop)).                                                                                                                                                                                                                                                                   |

#### Previews

- The image is a screenshot that the guest agent takes with its `screenshot` method ([Methods](#methods)), scaled to fit the preview with the proportions of the display, on black.
- The first screenshot is asked for when the popover opens, then one every 2 seconds while it stays open; none while it is closed.
- The preview stays black while the guest agent is not connected, for example while the guest starts up, and until the first screenshot arrives. A screenshot that fails, without the Screen Recording permission for example, leaves the image that shows.
- A click on the preview closes the popover and shows the virtual machine: the virtual machine of the user or of Claude shows its [detail](#detail) in the window's centre column, as a `virtualMachine` target does; the setup virtual machine of an image brings its setup window to front, as `Set Up…` does.

The previews come from the local-only services of This Mac ([Local-only services](architecture.md#local-only-services)): `VMSession.capturePreview()` for a virtual machine, from the VM screens service, and `VMSetupSession.capturePreview()` for a setup virtual machine, from the image setup service. Each asks the connected agent for a screenshot, and gives nothing while no agent is connected.

#### Stop

- `Stop` stops the virtual machine without confirmation: `vms.stop` for the virtual machine of the user or of Claude ([Stopping](#stopping)), after which Claude's is deleted; for a setup virtual machine, what closing its setup window does: the virtual machine shuts down, its image stays in `needsSetup`, and the window closes once it has stopped ([Setup window](#setup-window)).
- A virtual machine that shuts down keeps its row, with `Stop` disabled, until it has stopped, whoever asked for the stop: the popover, Settings, the detail or a closed setup window.
- A setup virtual machine whose window has closed keeps its row until it has stopped too; a click on its preview does nothing then, since its window is gone.
- A failed `Stop` shows the failure alert of [Principles](ui.md#principles) on the window, titled `Stop failed`.

The bubble, its symbol, its place and its look, the virtual machines it counts, the number hidden at 0, its tooltip, the windows that show it, the popover's rows with their preview refreshed every 2 seconds and empty without the agent, their texts, `Stop` without confirmation, the click on a preview, `No virtual machines running` and following the events at once come from the user ([R203](requirements.md#requirements)), and so do the name of a setup virtual machine's row, the order of the rows, the layout of a row with its 160 × 100 preview, the black of an empty preview, the row kept with `Stop` disabled while the virtual machine shuts down after `Stop`, the row of a setup virtual machine whose window has closed and the popover that a click on a preview closes. The fonts and colours of the texts, the time of a setup virtual machine that restarts in Recovery, the image kept after a failed screenshot, `Stop` disabled too for a stop asked elsewhere, the stop of a setup virtual machine as by a closed window and the alert of a failed `Stop` are Default chosen at design time.

## Deleting an image

`Delete…` asks for confirmation with the alert of [User interface](ui.md#virtual-machines), then calls `vmImages.delete`. Delete stops and deletes the image's virtual machines, then deletes the image's folder:

1. The engine ends the image's download or install, and stops its setup virtual machine at once, which closes its setup window.
2. It deletes every virtual machine whose `imageID` is the image, as `vms.delete` does: one that runs is stopped at once first ([Deleting a virtual machine](#deleting-a-virtual-machine)). `vms.changed` is emitted when it deleted one. A virtual machine whose folder cannot be deleted stays, and the image is deleted all the same: the virtual machine has its own disk.
3. When the image is the default image, `defaultVMImage` becomes null, with `settings.updated`.
4. The folder `<data dir>/VirtualMachines/Images/<image id>/` is deleted with everything in it. It is not moved to the Trash: a disk in the Trash would keep its space. Default chosen at design time.
5. `vmImages.changed` is emitted.

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
    Machines/
      <VM-ID>/                  one folder per virtual machine, named by its id, an uppercase UUID
        vm.yml                  the VM metadata file
        HardwareModel           a copy of the image's hardware model
        MachineIdentifier       a copy of the image's machine identifier
        AuxiliaryStorage        a copy of the image's auxiliary storage, then the virtual machine's own
        Disk.img                the disk: a clone of the image's disk, then the virtual machine's own
  Runtime/
    guest/                      the folder shared into the guests
      install.sh                the install script
      hephaestus-agent          the guest agent
```

- The engine creates `VirtualMachines/Images/` with the first image. Folders of `Images/` whose name is not a UUID, or whose `image.yml` is missing or invalid, are skipped and logged at launch ([Loading](data-model.md#loading)).
- The `Disk` column of the Images table is the image's `diskBytes`: the space the files of its folder take on disk, which for the sparse `Disk.img` is the space written so far, not `diskGB`.
- The engine creates `VirtualMachines/Machines/` with the first virtual machine. At launch, the folders of `Machines/` whose name is not a UUID, or whose `vm.yml` is missing or invalid, are skipped and logged, and the folder of a virtual machine that Claude started is deleted: such a folder is left only when the app ended without stopping the virtual machine ([Loading](data-model.md#loading)).
- A clone shares the blocks of the image's disk until one of the two files changes them, so a new virtual machine takes almost no space, and its disk grows with what the guest writes. The image's disk no longer changes once the image is Ready.
- `Runtime/guest/` is generated: the engine fills it each time a setup virtual machine starts.

The folder and file names are Default chosen at design time.

## Swift shape

| Path                                                           | Content                                                                                                                                                                                                                                |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Sources/HephaestusCore/Models/VMImage.swift`                  | `VMImage`, `VMImageState`: the image metadata file.                                                                                                                                                                                    |
| `Sources/HephaestusCore/Models/VirtualMachine.swift`           | `VirtualMachine`, `VirtualMachineState`, `VMStarter`: the VM metadata file; `VMRunningTime`, the text of a running time.                                                                                                               |
| `Sources/HephaestusCore/VirtualMachines/`                      | The images, the provisioner, the setup and the host side of the agent's protocol: see [HephaestusCore folders](architecture.md#hephaestuscore-folders).                                                                                |
| `Sources/HephaestusCore/VirtualMachines/VirtualMachine*.swift` | `VirtualMachineStore`, the folders and the clone; `VirtualMachineService`, the lifecycle; `VMSession`, one running virtual machine.                                                                                                    |
| `Sources/HephaestusCore/VirtualMachines/VMScreenPreview.swift` | `GuestPreviewCapturing` and `capturePreview()` of `VMSession` and `VMSetupSession`: the screenshots of the previews of the [Virtual Machines popover](#previews).                                                                      |
| `Sources/HephaestusCore/Engine/API/VMImagesAPI.swift`          | The `vmImages.*` methods and `MacOSVersion`.                                                                                                                                                                                           |
| `Sources/HephaestusCore/Engine/API/VMsAPI.swift`               | The `vms.*` methods and `VMList`.                                                                                                                                                                                                      |
| `Sources/HephaestusCore/Engine/Handlers/VMImageHandlers.swift` | `registerVMImageHandlers()` and the handlers.                                                                                                                                                                                          |
| `Sources/HephaestusCore/Engine/Handlers/VMHandlers.swift`      | `registerVMHandlers()` and the handlers.                                                                                                                                                                                               |
| `Sources/HephaestusCore/VirtualMachines/VMTool*.swift`         | `VMToolService`, the queues, the idle timers and the calls of `vm_start` that wait; the methods of the VM tools, the copies and the menu notation of `vm_key`.                                                                         |
| `Sources/HephaestusCore/Engine/API/VMToolsAPI.swift`           | The `vmTools.*` methods and their result types.                                                                                                                                                                                        |
| `Sources/HephaestusCore/Engine/Handlers/VMToolHandlers.swift`  | `registerVMToolHandlers()` and the handlers.                                                                                                                                                                                           |
| `Sources/HephaestusAgent/`                                     | The guest agent: `main.swift`, the connection loop, the frames, the session, one file per group of methods, the display assertion.                                                                                                     |
| `Resources/install-agent.sh`                                   | The install script, `install.sh` in the shared folder.                                                                                                                                                                                 |
| `Sources/HephaestusUI/Settings/`                               | `VirtualMachinesSettingsPane`, `AddImageSheet`, `NewVMSheet`, the setup window with the view of a virtual machine's screen (`VZVirtualMachineView`), and `VirtualMachineDetailView`, the detail of a virtual machine in a main window. |
| `Sources/HephaestusUI/Toolbar/VirtualMachinesBubble.swift`     | The [Virtual Machines bubble](#virtual-machines-bubble) and its popover; `VMPopoverPresentation`, the number and the texts of the rows.                                                                                                |

Outside the app, the engine reaches ipsw.me, Apple's download server and the Virtualization framework only through `VMImageProvisioning`, the `imageProvisioner` of its configuration ([Engine configuration](architecture.md#engine-configuration)): the app uses `SystemVMImageProvisioner`, and tests a stand-in, so that no test downloads an IPSW or starts a virtual machine ([Test rules](development.md#test-rules)). The clone of an image's disk and the other files of a virtual machine's folder are plain files, which the engine writes itself.

## Requirements covered

- R201: Settings has a Virtual Machines tab whose Images section adds macOS images for virtual machines from the versions ipsw.me lists, downloads and installs them, prepares each one once in a setup window so that an agent in the guest gives full control of it, marks the default image and deletes images.
- R202: The user starts virtual machines from the Ready images in Settings, keeps them between runs, starts, stops and deletes them, and shows the screen of one in a main window, where the mouse and the keyboard drive it; at most 2 run at once, and the app does not restart by itself for an update while one runs.
- R203: The toolbar of a main window that shows This Mac has a bubble with the number of virtual machines that run; its popover shows a preview of the screen of each one, refreshed every 2 seconds, its name, who started it and its running time, opens it and stops it.
- R204: Every chat of every project gives Claude full control of virtual machines with the VM tools: Claude starts one freely or joins Claude's one of the same image, waits up to 10 minutes for a free place, drives it one action at a time across chats, acts on the user's only when named and never stops them; Claude's idle VMs stop after the minutes set in Settings, and each VM gets the Claude token of Settings at its start.
