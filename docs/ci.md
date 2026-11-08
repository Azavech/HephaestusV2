# CI and releases

GitHub Actions builds, tests and publishes HephaestusV2. Every push to `main` runs the release workflow: it checks the repository for personal data, checks the docs, runs the tests (docs conformance tests included), computes the next version from the commit messages, assembles and signs the universal app bundle, and publishes a GitHub release `v<version>` with two assets, `HephaestusV2.zip` and `release.json`, which the [Updater](updater.md) of every installed copy picks up. Pull requests run the same checks, a build and the tests. This document gives the exact workflow files, the scripts' algorithms, the bundle layout and its Info.plist, the signing and notarization steps, the release assets, the checks, the docs conformance tests and the local `make` targets.

## Overview

```
push to main ──► release.yml: checks ─► swift test ─► next-version.sh ─► build-app.sh (build, assemble, sign, notarize)
                      ─► zip ─► CHANGELOG.md ─► release.json ─► tag v<version> ─► GitHub release
                                                                                        │
installed copies ◄── Updater: feed check, download, verification, install, restart ◄────┘

pull request ──► ci.yml: checks ─► swift build ─► swift test
```

| Piece                                 | Defined in                                |
| ------------------------------------- | ----------------------------------------- |
| `.github/workflows/release.yml`       | [Release workflow](#release-workflow)     |
| `.github/workflows/ci.yml`            | [CI workflow](#ci-workflow)               |
| `scripts/next-version.sh`             | [Versioning](#versioning)                 |
| `scripts/build-app.sh`                | [App bundle](#app-bundle)                 |
| `scripts/check-public.sh`             | [check-public.sh](#check-publicsh)        |
| `scripts/check-docs.sh`               | [check-docs.sh](#check-docssh)            |
| `scripts/tables.py`                   | [Table alignment](#table-alignment)       |
| `scripts/make-icon.swift`             | [App icon](#app-icon)                     |
| `Makefile`                            | [Local make targets](#local-make-targets) |
| `Resources/Info.plist`                | [Info.plist keys](#infoplist-keys)        |
| `Resources/Updater-Info.plist`        | [Updater Info.plist](#updater-infoplist)  |
| `Resources/HephaestusV2.entitlements` | [Entitlements](#entitlements)             |

## Runner and toolchain

- Both workflows run on `runs-on: xcode-27`: macOS 27 with Xcode 27.1 as the default Xcode and its Swift 6.4 toolchain. The workflows do not select another Xcode; the step "Show toolchain" prints the versions in use. Using the same runner for `ci.yml` is Default chosen at design time.
- The steps use these tools of the runner: `git`, `gh`, `jq` (`/usr/bin/jq`, jq 1.7), `python3` (the one installed with Xcode), `ditto`, `codesign`, `security`, `xcrun notarytool`, `xcrun stapler`, `plutil`, `lipo`, `shasum`, `stat`.
- Every `run` step uses `bash` through `defaults.run.shell: bash`, which GitHub runs as `bash --noprofile --norc -eo pipefail {0}`: a failing command, including one inside a pipeline, fails the step.

### Script conventions

- The scripts in `scripts/` that end in `.sh` start with `#!/bin/bash` and `set -euo pipefail`, are committed with the executable bit, and run with the macOS system `bash` 3.2: no associative arrays, no `mapfile` or `readarray`, no `${var,,}`.
- Each script changes to the repository root itself (the parent folder of `scripts/`), so it runs from any working directory.
- No script uses `set -x` or prints a secret, a signing identity name, a certificate subject or a Team ID: the workflow logs of a public repository are public.
- Exit statuses: 0 success, 1 failure, 2 usage error. Messages go to standard error, results to standard output.

These conventions are Default chosen at design time.

### Test parallelism

The runner is a small virtual machine with 3 cores. Swift Testing starts every test of a run at once, and the tests of one target share the threads of their process: the Swift concurrency pool, which has one thread per core, and the Dispatch queues of Network.framework and FSEvents. So the step Test of both workflows sets the environment variable `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH` to `4`, and Swift Testing runs at most 4 tests at a time. `swift test --no-parallel` would run one test at a time and take several times as long, and `--num-workers` only applies to XCTest. The width 4 is Default chosen at design time. `make test` and a plain `swift test` keep the default of Swift Testing, every test at once; `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4 swift test` runs the tests as CI does ([Running tests](development.md#running-tests)).

## Release workflow

`.github/workflows/release.yml` runs on every push to `main` and on manual dispatch (`workflow_dispatch`). Runs share the concurrency group `release` with `cancel-in-progress: false`: a running release is never cancelled and two releases are never built at once. While one runs, GitHub keeps only the newest waiting run and cancels the older waiting ones; that run builds every commit pushed meanwhile. The job needs `contents: write` to push the tag and create the release.

| #   | Step                         | What it does                                                                                                                                                              | Runs when           |
| --- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- |
| 1   | Check out                    | `actions/checkout@v5` with the whole history (`fetch-depth: 0`) and the tags.                                                                                             | always              |
| 2   | Show toolchain               | Prints `xcodebuild -version` and `swift --version`.                                                                                                                       | always              |
| 3   | Check public data            | `scripts/check-public.sh` ([check-public.sh](#check-publicsh)).                                                                                                           | always              |
| 4   | Check docs                   | `scripts/check-docs.sh` ([check-docs.sh](#check-docssh)).                                                                                                                 | always              |
| 5   | Test                         | `swift test` with at most 4 tests at a time ([Test parallelism](#test-parallelism)), docs conformance tests included ([Docs conformance tests](#docs-conformance-tests)). | always              |
| 6   | Compute version              | `scripts/next-version.sh`; its three output lines become the step outputs `version`, `build` and `previous_tag` ([Versioning](#versioning)).                              | always              |
| 7   | Look for an existing release | Sets `exists` to `true` when the release `v<version>` already exists, `false` otherwise.                                                                                  | always              |
| 8   | Build app                    | `scripts/build-app.sh` with the version, the build, `github.repository` and the signing secrets ([App bundle](#app-bundle)).                                              | `exists` is `false` |
| 9   | Zip                          | `ditto -c -k --sequesterRsrc --keepParent build/HephaestusV2.app build/HephaestusV2.zip`.                                                                                 | `exists` is `false` |
| 10  | Write changelog              | `build/CHANGELOG.md` ([Changelog](#changelog)).                                                                                                                           | `exists` is `false` |
| 11  | Write release.json           | `build/release.json` ([release.json](#releasejson)).                                                                                                                      | `exists` is `false` |
| 12  | Tag                          | Creates the lightweight tag `v<version>` on `HEAD` unless it exists, then pushes it.                                                                                      | `exists` is `false` |
| 13  | Publish release              | `gh release create v<version>` marked latest, titled `v<version>(<build>)`, body `build/CHANGELOG.md`, assets `HephaestusV2.zip` and `release.json`.                      | `exists` is `false` |

- Steps 2, 7 and 10, the lightweight tag and the release title are Default chosen at design time.
- A failing step fails the job and skips the later steps, so nothing is tagged or published unless the checks, the tests, the build, the zip and `release.json` succeeded.
- A run for a commit that is already released (a manual dispatch without new commits) ends successfully after step 7 without building. A run for a commit that is tagged but not released (an earlier run failed at step 13) reuses that tag's version and publishes it.
- The tag push made with the workflow's `GITHUB_TOKEN` starts no other workflow run.
- `main` is never force-pushed: the build number counts the commits of `main`, so a rewritten `main` with fewer commits gets build numbers at or below the installed ones, and the Updater installs none of them ([Versions and display](updater.md#versions-and-display)).

Contents of `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: release
  cancel-in-progress: false

permissions:
  contents: write

defaults:
  run:
    shell: bash

jobs:
  release:
    runs-on: xcode-27
    steps:
      - name: Check out
        uses: actions/checkout@v5
        with:
          fetch-depth: 0
          fetch-tags: true

      - name: Show toolchain
        run: |
          xcodebuild -version
          swift --version

      - name: Check public data
        run: scripts/check-public.sh

      - name: Check docs
        run: scripts/check-docs.sh

      - name: Test
        env:
          SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH: "4"
        run: swift test

      - name: Compute version
        id: version
        run: scripts/next-version.sh | tee -a "$GITHUB_OUTPUT"

      - name: Look for an existing release
        id: existing
        env:
          GH_TOKEN: ${{ github.token }}
          VERSION: ${{ steps.version.outputs.version }}
        run: |
          if gh release view "v$VERSION" > /dev/null 2>&1; then
            echo "exists=true" >> "$GITHUB_OUTPUT"
            echo "Release v$VERSION already exists; nothing to publish."
          else
            echo "exists=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Build app
        if: steps.existing.outputs.exists == 'false'
        env:
          VERSION: ${{ steps.version.outputs.version }}
          BUILD: ${{ steps.version.outputs.build }}
          REPOSITORY: ${{ github.repository }}
          MACOS_CERTIFICATE_P12_BASE64: ${{ secrets.MACOS_CERTIFICATE_P12_BASE64 }}
          MACOS_CERTIFICATE_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
          NOTARY_KEY_P8_BASE64: ${{ secrets.NOTARY_KEY_P8_BASE64 }}
        run: scripts/build-app.sh --version "$VERSION" --build "$BUILD" --repository "$REPOSITORY"

      - name: Zip
        if: steps.existing.outputs.exists == 'false'
        run: ditto -c -k --sequesterRsrc --keepParent build/HephaestusV2.app build/HephaestusV2.zip

      - name: Write changelog
        if: steps.existing.outputs.exists == 'false'
        env:
          PREVIOUS_TAG: ${{ steps.version.outputs.previous_tag }}
        run: |
          if [ -n "$PREVIOUS_TAG" ]; then
            git log --format='- %s' "$PREVIOUS_TAG..HEAD" > build/CHANGELOG.md
          else
            git log --format='- %s' HEAD > build/CHANGELOG.md
          fi

      - name: Write release.json
        if: steps.existing.outputs.exists == 'false'
        env:
          VERSION: ${{ steps.version.outputs.version }}
          BUILD: ${{ steps.version.outputs.build }}
        run: |
          sha256=$(shasum -a 256 build/HephaestusV2.zip | awk '{print $1}')
          size=$(stat -f %z build/HephaestusV2.zip)
          minimum=$(plutil -extract LSMinimumSystemVersion raw build/HephaestusV2.app/Contents/Info.plist)
          published=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          jq -n \
            --arg version "$VERSION" \
            --argjson build "$BUILD" \
            --arg sha256 "$sha256" \
            --argjson size "$size" \
            --arg minimumSystemVersion "$minimum" \
            --arg published "$published" \
            --rawfile notes build/CHANGELOG.md \
            '{version: $version, build: $build, sha256: $sha256, size: $size, minimumSystemVersion: $minimumSystemVersion, published: $published, notes: $notes}' \
            > build/release.json
          cat build/release.json

      - name: Tag
        if: steps.existing.outputs.exists == 'false'
        env:
          VERSION: ${{ steps.version.outputs.version }}
        run: |
          if ! git rev-parse -q --verify "refs/tags/v$VERSION" > /dev/null; then
            git tag "v$VERSION" HEAD
          fi
          git push origin "refs/tags/v$VERSION"

      - name: Publish release
        if: steps.existing.outputs.exists == 'false'
        env:
          GH_TOKEN: ${{ github.token }}
          VERSION: ${{ steps.version.outputs.version }}
          BUILD: ${{ steps.version.outputs.build }}
        run: |
          gh release create "v$VERSION" \
            --verify-tag \
            --latest \
            --title "v$VERSION($BUILD)" \
            --notes-file build/CHANGELOG.md \
            build/HephaestusV2.zip build/release.json
```

## CI workflow

`.github/workflows/ci.yml` runs on every pull request: the two checks, a debug build of every target and the tests, with the parallelism of the release workflow ([Test parallelism](#test-parallelism)). It needs no secret and only reads the repository. The debug build (`swift build`) is Default chosen at design time.

Contents of `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  pull_request:

permissions:
  contents: read

defaults:
  run:
    shell: bash

jobs:
  check:
    runs-on: xcode-27
    steps:
      - name: Check out
        uses: actions/checkout@v5

      - name: Show toolchain
        run: |
          xcodebuild -version
          swift --version

      - name: Check public data
        run: scripts/check-public.sh

      - name: Check docs
        run: scripts/check-docs.sh

      - name: Build
        run: swift build

      - name: Test
        env:
          SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH: "4"
        run: swift test
```

## Versioning

`scripts/next-version.sh` computes the version and the build number of the commit `HEAD` from the git history. It takes no argument, needs the whole history and the tags, and prints the result for `$GITHUB_OUTPUT`.

A **version tag** is a tag whose name matches `^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`; tags of other forms are ignored. Version tags are ordered by major, then minor, then patch, compared as numbers.

1. When the current folder is not inside a git work tree, or `git rev-parse --is-shallow-repository` prints `true`, the script writes `next-version.sh: the whole git history is needed` to standard error and exits with status 1.
2. `build` = the output of `git rev-list --count HEAD`.
3. `head_tag` = the highest version tag among `git tag --points-at HEAD`; empty when there is none.
4. `previous_tag` = the highest version tag among `git tag --merged HEAD` that does not point at `HEAD`; empty when there is none.
5. When `head_tag` is set, `version` is `head_tag` without its `v`: the commit is already tagged, and its version is reused. Default chosen at design time.
6. Otherwise the base is `previous_tag` without its `v`, or `0.0.0` when it is empty, and the commits considered are those of `git log <previous_tag>..HEAD`, or of `git log HEAD` when `previous_tag` is empty, merge commits included. The bump is the highest one any of these commits asks for:

| Bump  | A commit asks for it when                                                                                      | New version from `X.Y.Z` |
| ----- | -------------------------------------------------------------------------------------------------------------- | ------------------------ |
| major | its first line matches `^[A-Za-z]+(\([^()]*\))?!:`, or its message contains `BREAKING CHANGE` (case-sensitive) | `(X+1).0.0`              |
| minor | its first line matches `^feat(\([^()]*\))?:`                                                                   | `X.(Y+1).0`              |
| patch | any other commit                                                                                               | `X.Y.(Z+1)`              |

7. The script prints exactly three lines to standard output and exits with status 0:

```
version=0.5.0
build=61
previous_tag=v0.4.0
```

`previous_tag=` is printed with an empty value when there is no previous tag.

| Previous tag     | Commits since the previous tag                                                                 | `version` |
| ---------------- | ---------------------------------------------------------------------------------------------- | --------- |
| none             | `chore: start the project`                                                                     | `0.0.1`   |
| none             | `chore: start the project`, `feat: add tickets (HEPH-1)`                                       | `0.1.0`   |
| `v0.4.0`         | `fix: keep locked web tabs open on Command-W (HEPH-12)`, `docs: describe the banner (HEPH-14)` | `0.4.1`   |
| `v0.4.0`         | `feat: name chats with Haiku (HEPH-15)`, `fix: crash on empty ticket (HEPH-16)`                | `0.5.0`   |
| `v0.4.0`         | `feat(ui): add a toolbar button` (a commit made outside the ticket workflow)                   | `0.5.0`   |
| `v0.4.0`         | `feat!: store tickets as JSON (HEPH-17)`                                                       | `1.0.0`   |
| `v0.4.0`         | `fix: rename settings keys (HEPH-18)` whose body has a line `BREAKING CHANGE: ...`             | `1.0.0`   |
| `v0.4.0` on HEAD | none (rerun of a released commit)                                                              | `0.4.0`   |

- A breaking change bumps the major version also below 1.0.0.
- The build number counts every commit reachable from `HEAD`, so it grows with every commit on `main` and is the number the Updater compares ([Versions and display](updater.md#versions-and-display)).

## App bundle

`scripts/build-app.sh` builds the executables with SwiftPM, assembles `HephaestusV2.app`, writes its Info.plist values and signs it; with the notarization secrets it also notarizes and staples it.

```
scripts/build-app.sh --version <X.Y.Z> --build <N> --repository <owner/name>
                     [--configuration release|debug] [--arch universal|native] [--output <folder>]
```

| Option            | Required | Default     | Value                                                                                                 |
| ----------------- | -------- | ----------- | ----------------------------------------------------------------------------------------------------- |
| `--version`       | yes      | —           | `CFBundleShortVersionString`; matches `^(0\|[1-9][0-9]*)\.(0\|[1-9][0-9]*)\.(0\|[1-9][0-9]*)$`.       |
| `--build`         | yes      | —           | `CFBundleVersion`; matches `^(0\|[1-9][0-9]*)$`.                                                      |
| `--repository`    | yes      | —           | `HephaestusReleaseRepository`; matches `^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$`.                             |
| `--configuration` | no       | `release`   | SwiftPM configuration.                                                                                |
| `--arch`          | no       | `universal` | `universal`: arm64 and x86_64; `native`: the architecture of the building Mac.                        |
| `--output`        | no       | `build`     | Folder that receives `HephaestusV2.app` and the work folder `work/`, relative to the repository root. |

| Environment variable           | Effect                                                                                 |
| ------------------------------ | -------------------------------------------------------------------------------------- |
| `MACOS_CERTIFICATE_P12_BASE64` | With `MACOS_CERTIFICATE_PASSWORD`: Developer ID signing ([Signing](#signing)).         |
| `MACOS_CERTIFICATE_PASSWORD`   | Password of the certificate.                                                           |
| `NOTARY_KEY_ID`                | With the other two `NOTARY_*` variables: notarization ([Notarization](#notarization)). |
| `NOTARY_ISSUER_ID`             | Issuer of the notary key.                                                              |
| `NOTARY_KEY_P8_BASE64`         | The notary key.                                                                        |

An empty variable counts as unset. Invalid or missing options print the usage to standard error and exit with status 2. `--configuration`, `--arch` and `--output` are Default chosen at design time.

### Build steps

`<archs>` stands for `--arch arm64 --arch x86_64` with `--arch universal` and for nothing with `--arch native`; `<conf>` is the configuration; `<out>` is the absolute path of the output folder.

1. Validate the options; delete `<out>/HephaestusV2.app` and `<out>/work/`; create `<out>/work/`.
2. Copy `Resources/Updater-Info.plist` to `<out>/work/Updater-Info.plist` and set its `CFBundleShortVersionString` to the version and its `CFBundleVersion` to the build (`plutil -replace <key> -string <value>`).
3. `swift build -c <conf> <archs> --product HephaestusV2`.
4. `swift build -c <conf> <archs> --product Updater -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker <out>/work/Updater-Info.plist`. This embeds the Updater's Info.plist in its executable, which gives the executable its bundle id. Default chosen at design time.
5. `<bin>` = the output of `swift build -c <conf> <archs> --show-bin-path`.
6. Assemble the bundle ([Bundle layout](#bundle-layout)):
   - `<bin>/HephaestusV2` → `Contents/MacOS/HephaestusV2`;
   - `<bin>/Updater` → `Contents/Helpers/Updater`;
   - every `<bin>/*.bundle` folder whose name does not end in `Tests.bundle` → `Contents/Resources/` (copied with `ditto`);
   - `Resources/AppIcon.icns` → `Contents/Resources/AppIcon.icns`;
   - `Resources/Info.plist` → `Contents/Info.plist`, then `plutil -replace` sets `CFBundleShortVersionString` to the version, `CFBundleVersion` to the build and `HephaestusReleaseRepository` to the repository, all as strings;
   - the 8 bytes `APPL????` → `Contents/PkgInfo`.
7. Check: `plutil -lint Contents/Info.plist` passes; with `--arch universal`, `lipo -archs` lists `arm64` and `x86_64` for both executables.
8. Sign the Updater, then the app ([Signing](#signing)), then run `codesign --verify --deep --strict <out>/HephaestusV2.app`.
9. Notarize and staple when the notarization secrets are set ([Notarization](#notarization)).
10. Print `<out>/HephaestusV2.app v<version>(<build>), <signing>` to standard output, `<signing>` being `Developer ID`, `Developer ID, notarized` or `ad-hoc`.

With Xcode 27.1, `swift build` given both `--arch` options links universal executables directly; the bin folder is the same for every architecture set (`.build/out/Products/Release` or `.build/out/Products/Debug`), so the script always asks SwiftPM for it with `--show-bin-path`.

### Bundle layout

```
HephaestusV2.app/
  Contents/
    Info.plist                              Resources/Info.plist with version, build and repository
    PkgInfo                                 APPL????
    MacOS/
      HephaestusV2                          the app executable (universal in releases)
    Helpers/
      Updater                               the Updater executable, Updater-Info.plist embedded in __TEXT,__info_plist
    Resources/
      AppIcon.icns
      HephaestusV2_HephaestusCore.bundle/   SwiftPM resources of HephaestusCore (prompts)
      HephaestusV2_HephaestusUI.bundle/     SwiftPM resources of HephaestusUI (chat.html, doc.html, CSS, JavaScript)
    _CodeSignature/
      CodeResources                         written by codesign
```

- SwiftPM names each resource bundle `<package name>_<target name>.bundle`; the script copies every one it finds except those of test targets, so a target that gains resources needs no script change. The bundles are complete bundles (`Contents/Info.plist`, `Contents/Resources/`) and contain no code.
- The `Bundle.module` accessor that SwiftPM generates looks in `Bundle.main.resourceURL` first, which is `Contents/Resources/` in the app, so the code reads its resources with `Bundle.module` ([Modules](architecture.md#modules)).
- The bundle has no `Frameworks` folder. When `<bin>/PackageFrameworks` exists and is not empty, the script fails with `build-app.sh: dynamic frameworks are not supported`. Default chosen at design time.
- No other file is placed at the top of the bundle or directly in `Contents/`: `codesign` fails to sign a bundle that has one.

## Info.plist keys

`Resources/Info.plist` is copied into the bundle by `scripts/build-app.sh`, which sets the three keys marked "build-app.sh" ([Build steps](#build-steps)).

| Key                              | Type             | Value                                                                                                                  | Set by                      |
| -------------------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| `CFBundleDevelopmentRegion`      | string           | `en`                                                                                                                   | the file                    |
| `CFBundleExecutable`             | string           | `HephaestusV2`                                                                                                         | the file                    |
| `CFBundleIconFile`               | string           | `AppIcon`                                                                                                              | the file                    |
| `CFBundleIdentifier`             | string           | `ca.azavech.hephaestusv2`                                                                                              | the file                    |
| `CFBundleInfoDictionaryVersion`  | string           | `6.0`                                                                                                                  | the file                    |
| `CFBundleName`                   | string           | `HephaestusV2`                                                                                                         | the file                    |
| `CFBundlePackageType`            | string           | `APPL`                                                                                                                 | the file                    |
| `CFBundleShortVersionString`     | string           | The version, `X.Y.Z`; `0.0.0` in the file                                                                              | build-app.sh `--version`    |
| `CFBundleVersion`                | string           | The build number; `0` in the file                                                                                      | build-app.sh `--build`      |
| `HephaestusReleaseRepository`    | string           | `<owner>/<name>` of the GitHub repository that publishes the releases; empty in the file                               | build-app.sh `--repository` |
| `LSApplicationCategoryType`      | string           | `public.app-category.developer-tools`                                                                                  | the file                    |
| `LSMinimumSystemVersion`         | string           | `26.0`                                                                                                                 | the file                    |
| `NSAppTransportSecurity`         | dictionary       | `NSAllowsArbitraryLoads` = true ([Web tabs](web-tabs.md#infoplist), [OpenAPI contracts](openapi.md#sending-a-request)) | the file                    |
| `NSBonjourServices`              | array of strings | `_hephaestus2._tcp`                                                                                                    | the file                    |
| `NSHighResolutionCapable`        | boolean          | true                                                                                                                   | the file                    |
| `NSLocalNetworkUsageDescription` | string           | `HephaestusV2 uses the local network to find your other Macs running HephaestusV2 and to work on their projects.`      | the file                    |

- `HephaestusReleaseRepository` is read by the [Updater](updater.md#release-feed) and by Settings > Updates ([UI](ui.md#updates)). Feedback does not read it: it goes to the HephaestusV2 project, whose repository URL is hardcoded in the app ([HephaestusV2 project](projects.md#hephaestusv2-project)). CI passes `github.repository`; local builds pass the Makefile's `RELEASE_REPOSITORY` ([Local make targets](#local-make-targets)).
- `NSBonjourServices` and `NSLocalNetworkUsageDescription` are those of [Remote devices](remote.md#infoplist-keys).
- `NSAppTransportSecurity` lets the web views of [Web tabs](web-tabs.md) load any URL the user opens, `http://` pages of local servers included. Default chosen at design time.
- `CFBundleDevelopmentRegion`, `CFBundleExecutable`, `CFBundleIconFile`, `CFBundleInfoDictionaryVersion` and `CFBundlePackageType` are Default chosen at design time.

Contents of `Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>HephaestusV2</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>ca.azavech.hephaestusv2</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>HephaestusV2</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.0.0</string>
	<key>CFBundleVersion</key>
	<string>0</string>
	<key>HephaestusReleaseRepository</key>
	<string></string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
	<key>NSBonjourServices</key>
	<array>
		<string>_hephaestus2._tcp</string>
	</array>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>HephaestusV2 uses the local network to find your other Macs running HephaestusV2 and to work on their projects.</string>
</dict>
</plist>
```

### Updater Info.plist

`Resources/Updater-Info.plist` is embedded in the Updater executable (section `__TEXT,__info_plist`, step 4 of [Build steps](#build-steps)) after build-app.sh has set its version and build. It declares neither `NSBonjourServices` nor `NSLocalNetworkUsageDescription`.

| Key                             | Value                                  |
| ------------------------------- | -------------------------------------- |
| `CFBundleIdentifier`            | `ca.azavech.hephaestusv2.updater`      |
| `CFBundleInfoDictionaryVersion` | `6.0`                                  |
| `CFBundleName`                  | `Updater`                              |
| `CFBundleShortVersionString`    | The app's version; `0.0.0` in the file |
| `CFBundleVersion`               | The app's build; `0` in the file       |
| `LSMinimumSystemVersion`        | `26.0`                                 |

Contents of `Resources/Updater-Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>ca.azavech.hephaestusv2.updater</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Updater</string>
	<key>CFBundleShortVersionString</key>
	<string>0.0.0</string>
	<key>CFBundleVersion</key>
	<string>0</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
</dict>
</plist>
```

## Entitlements

`Resources/HephaestusV2.entitlements` is applied to the app when it is signed with a Developer ID. It holds an empty dictionary: the app is not sandboxed ([Process model](architecture.md#process-model)) and requests no hardened-runtime exception. The Updater is signed without entitlements. Default chosen at design time.

Contents of `Resources/HephaestusV2.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
```

## Signing

`scripts/build-app.sh` signs the Updater first, then the app, whose signature seals the signed Updater. It never signs with `--deep`.

| Mode         | Used when                                                                    | Updater                                                                                                                                                              | App                                                                                                                                               |
| ------------ | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Developer ID | `MACOS_CERTIFICATE_P12_BASE64` and `MACOS_CERTIFICATE_PASSWORD` are both set | `codesign --force --timestamp --options runtime --keychain <keychain> --sign <identity> --identifier ca.azavech.hephaestusv2.updater <app>/Contents/Helpers/Updater` | `codesign --force --timestamp --options runtime --keychain <keychain> --sign <identity> --entitlements Resources/HephaestusV2.entitlements <app>` |
| ad-hoc       | otherwise                                                                    | `codesign --force --sign - --identifier ca.azavech.hephaestusv2.updater <app>/Contents/Helpers/Updater`                                                              | `codesign --force --sign - <app>`                                                                                                                 |

When exactly one of the two certificate variables is set, the script writes `build-app.sh: MACOS_CERTIFICATE_P12_BASE64 and MACOS_CERTIFICATE_PASSWORD must both be set; signing ad-hoc` to standard error and signs ad-hoc. Default chosen at design time.

### Developer ID identity

1. Create a temporary folder (`mktemp -d`) and, in it, the keychain `signing.keychain-db` with a random password (`uuidgen`): `security create-keychain -p <password> <keychain>`, `security set-keychain-settings -lut 3600 <keychain>`, `security unlock-keychain -p <password> <keychain>`.
2. Decode `MACOS_CERTIFICATE_P12_BASE64` with `base64 --decode` into `certificate.p12` (mode 0600) in the temporary folder; `security import certificate.p12 -k <keychain> -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign`; delete `certificate.p12`.
3. `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <password> <keychain>`, its standard output discarded.
4. Put the keychain first in the user search list (`security list-keychains -d user -s <keychain> <current list>`), saving the current list.
5. `<identity>` = the SHA-1 hash of the first identity of `security find-identity -v -p codesigning <keychain>` whose name contains `Developer ID Application`, captured without being printed. When there is none, the script fails with `build-app.sh: the certificate holds no Developer ID Application identity`.
6. On exit, success or failure (`trap … EXIT`): restore the saved search list, `security delete-keychain <keychain>`, delete the temporary folder.

### Notarization

Notarization runs when the app was signed with a Developer ID and `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` and `NOTARY_KEY_P8_BASE64` are all set. When some but not all of them are set, or when they are set and the app was signed ad-hoc, the script writes `build-app.sh: notarization skipped: <reason>` to standard error and goes on without notarizing. Default chosen at design time.

1. Decode `NOTARY_KEY_P8_BASE64` into `AuthKey.p8` (mode 0600) in the temporary folder.
2. `ditto -c -k --sequesterRsrc --keepParent <app> <temporary folder>/notarize.zip`.
3. `xcrun notarytool submit <temporary folder>/notarize.zip --key <temporary folder>/AuthKey.p8 --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait --timeout 1h --output-format json`, its output saved to `notary.json` in the temporary folder.
4. When `jq -r .status notary.json` is not `Accepted`, the script prints the `issues` member of `xcrun notarytool log <id>` (same key options, `<id>` = `jq -r .id notary.json`) to standard error and fails with `build-app.sh: notarization failed: <status>`.
5. `xcrun stapler staple <app>`, then `xcrun stapler validate <app>`.

The release zip is made after this step (step 9 of the [Release workflow](#release-workflow)), so it holds the stapled app. The timeout is Default chosen at design time.

### Signing secrets

The secrets are set in the repository's settings (Settings ▸ Secrets and variables ▸ Actions) and never appear in the repository. Only the step "Build app" of `release.yml` receives them; `ci.yml` never does.

| Secret                         | Content                                                                                       |
| ------------------------------ | --------------------------------------------------------------------------------------------- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 of a `.p12` file holding a "Developer ID Application" certificate and its private key. |
| `MACOS_CERTIFICATE_PASSWORD`   | Password of that `.p12` file.                                                                 |
| `NOTARY_KEY_ID`                | Key ID of an App Store Connect API key.                                                       |
| `NOTARY_ISSUER_ID`             | Issuer ID of that API key.                                                                    |
| `NOTARY_KEY_P8_BASE64`         | Base64 of that API key's `.p8` file.                                                          |

| Secrets set                 | Signature                                        | Notarized                  | Team ID                |
| --------------------------- | ------------------------------------------------ | -------------------------- | ---------------------- |
| none                        | ad-hoc                                           | no                         | none                   |
| the two certificate secrets | Developer ID, hardened runtime, secure timestamp | no                         | the certificate's team |
| all five                    | Developer ID, hardened runtime, secure timestamp | yes, the ticket is stapled | the certificate's team |

Once a release is signed with a Developer ID, installed copies accept only releases of the same team ([Download and verification](updater.md#download-and-verification)): removing the certificate secrets afterwards produces ad-hoc releases that no installed copy installs.

## Release assets

Each release is tagged `v<version>`, titled `v<version>(<build>)`, marked latest, neither draft nor prerelease, and has the [changelog](#changelog) as its body. It carries exactly two assets:

| Asset              | Content                                                                                                                                                                                     |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `HephaestusV2.zip` | The signed app (stapled when notarized), made with `ditto -c -k --sequesterRsrc --keepParent build/HephaestusV2.app build/HephaestusV2.zip`; its only top-level item is `HephaestusV2.app`. |
| `release.json`     | The release manifest below.                                                                                                                                                                 |

The [Updater](updater.md#release-feed) reads the latest release through `GET https://api.github.com/repos/<owner>/<name>/releases/latest` and downloads both assets.

## release.json

`release.json` is UTF-8 JSON written by `jq` in step 11 of the [Release workflow](#release-workflow), with two-space indentation and the members in this order. Every member is required; a decoder ignores unknown members. UpdaterCore decodes it as `ReleaseManifest` ([Swift shape](updater.md#swift-shape)).

| Member                 | JSON type | Rule                                                                                                                                     | Example                  |
| ---------------------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| `version`              | string    | Matches `^(0\|[1-9][0-9]*)\.(0\|[1-9][0-9]*)\.(0\|[1-9][0-9]*)$`; equals the tag without `v` and the app's `CFBundleShortVersionString`. | `"0.5.0"`                |
| `build`                | integer   | ≥ 1; equals the app's `CFBundleVersion`.                                                                                                 | `61`                     |
| `sha256`               | string    | The SHA-256 of `HephaestusV2.zip`: 64 lowercase hexadecimal digits.                                                                      | see the example          |
| `size`                 | integer   | ≥ 1; the size of `HephaestusV2.zip` in bytes.                                                                                            | `18734592`               |
| `minimumSystemVersion` | string    | The app's `LSMinimumSystemVersion`; matches `^[0-9]+(\.[0-9]+){0,2}$`.                                                                   | `"26.0"`                 |
| `published`            | string    | When `release.json` was written: ISO-8601 UTC with seconds, `YYYY-MM-DDTHH:MM:SSZ`.                                                      | `"2026-10-31T14:03:00Z"` |
| `notes`                | string    | The content of `build/CHANGELOG.md` ([Changelog](#changelog)).                                                                           | see the example          |

```json
{
  "version": "0.5.0",
  "build": 61,
  "sha256": "50d858e0985ecc7f60418aaf0cc5ab587f42c2570a884095a9e8ccacd0f6545c",
  "size": 18734592,
  "minimumSystemVersion": "26.0",
  "published": "2026-10-31T14:03:00Z",
  "notes": "- feat: name chats with Haiku (HEPH-15)\n- fix: crash on empty ticket (HEPH-16)\n"
}
```

## Changelog

Step 10 of the [Release workflow](#release-workflow) writes `build/CHANGELOG.md` with `git log --format='- %s' <previous_tag>..HEAD`, or `git log --format='- %s' HEAD` when there is no previous tag: one line `- <subject>` per commit since the previous release, newest first, merge commits included. It holds commit subjects only, no author, e-mail or hash. The same text is the release body and the `notes` of `release.json`.

```
- feat: name chats with Haiku (HEPH-15)
- fix: crash on empty ticket (HEPH-16)
```

## Checks

### check-public.sh

`scripts/check-public.sh [<path>…]` fails when the repository holds personal data ([Public repository](development.md#public-repository)). Without arguments it scans the whole repository; with paths (relative to the repository root) it scans only them. It scans the tracked files and the untracked files that `.gitignore` does not ignore, skipping binary files, as `git grep -I --untracked` does.

| Rule           | Finds                                                                                                                                                                                                                                                                                     | Allowed                                                                                                                                                                                                                                                       |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `home-path`    | `/Users/<name>`, `<name>` being one or more characters of `A–Z a–z 0–9 . _ -`                                                                                                                                                                                                             | `/Users/example`, `/Users/Shared`                                                                                                                                                                                                                             |
| `email`        | An address `<local>@<domain>`: `<local>` of `A–Z a–z 0–9 . _ % + -`, `<domain>` of dot-separated labels of `A–Z a–z 0–9 -` ending with a label of two or more letters                                                                                                                     | Local part `noreply` or `no-reply`; domain `example.com`, `example.org`, `example.net` or one of their subdomains; a domain ending in `.noreply.github.com`; a domain starting with digits followed by `x.`, which is an image scale suffix such as `@2x.png` |
| `team-setting` | `DEVELOPMENT_TEAM` followed by `=` or `:` and a value that, trimmed of spaces, quotes and a final `;`, is not empty and does not start with `$`                                                                                                                                           | —                                                                                                                                                                                                                                                             |
| `team-id`      | A 10-character token made of `A–Z` and `0–9` with at least one letter and one digit (a token being a maximal run of letters and digits), on a line that contains `DEVELOPMENT_TEAM`, `TeamIdentifier`, `teamID`, `team-id`, `team_id`, `--team`, `Developer ID Application` or `codesign` | —                                                                                                                                                                                                                                                             |

- Each finding is printed to standard output as `<path>:<line>: <rule>`, sorted by path and line. The matched text is never printed: CI logs are public.
- Exit status 0 without findings, 1 with findings, 2 when a given path does not exist or is outside the repository.
- The script contains no personal value, and its own text passes its rules.
- The exact character classes, the allowed lists and the output format are Default chosen at design time.

### check-docs.sh

`scripts/check-docs.sh` takes no argument. It runs the three checks below, all of them even when one fails, prints their findings to standard output and exits with status 1 when any check failed, 0 otherwise.

| #   | Check         | Rule                                                                                                                                                                                                                                                                     | Finding                                                                                                                                        |
| --- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Index         | Every `.md` file under `docs/`, subfolders included, except `docs/README.md`, is the target of at least one inline link `](<target>)` of `docs/README.md`; `<target>` is the file's path relative to `docs/`, optionally prefixed by `./` and followed by `#<fragment>`. | `docs/README.md: <path> is not linked`, `<path>` being relative to the repository root as in `check-public.sh`, or `docs/README.md is missing` |
| 2   | Tables        | `python3 -I scripts/tables.py --check` on every `.md` file under `docs/` exits with status 0 ([Table alignment](#table-alignment)).                                                                                                                                      | The lines printed by `tables.py`                                                                                                               |
| 3   | Personal data | `scripts/check-public.sh docs` exits with status 0.                                                                                                                                                                                                                      | The findings of `check-public.sh`                                                                                                              |

Running `check-public.sh` on `docs/` for check 3, and the finding texts, are Default chosen at design time.

### Table alignment

`scripts/tables.py` aligns markdown tables: every row of a table has its pipes at the same columns.

- `python3 -I scripts/tables.py --fix <file>…` rewrites the files with aligned tables; `--check` prints `<file>:<line>: table not aligned` for every unaligned table and exits with status 1 when there is one.
- A table is a run of lines starting with `|`. Each column is padded to its widest cell; the separator row is made of dashes, keeping its `:` alignment marks. Widths count East Asian wide and full-width characters as 2 and combining characters as 0.
- `\|` and a `|` inside a code span do not split a cell. Fenced code blocks are left untouched.

## Docs conformance tests

`swift test` runs these tests in `ci.yml`, in `release.yml` before any version is computed, and locally with `make test`. They find the repository root by walking up from the test file (`#filePath`) to the folder holding `Package.swift`, so they always compare the docs and the code of the same checkout. A change of behaviour therefore changes the docs and the code in the same commit ([Docs conformance tests](development.md#docs-conformance-tests)).

| #   | Test                 | Target              | Docs side                                                                                                                                | Code side                                                               | Assertion                                                                                                                         |
| --- | -------------------- | ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| 1   | MCP tools            | HephaestusCoreTests | The rows of the tables of `docs/mcp.md` whose first two header cells are `Tool` and `Required inputs` ([MCP server](mcp.md#conformance)) | `tools/list` of the MCP server, with debug tools disabled, then enabled | The tool names, their order and each tool's `inputSchema.required` match the rows, as stated in [MCP server](mcp.md#conformance). |
| 2   | Engine methods       | HephaestusCoreTests | The table rows of `docs/engine-api.md` whose first cell is a backticked method name ([Engine API](engine-api.md#conformance))            | `Engine.registeredMethods`                                              | The two sets of method names are equal.                                                                                           |
| 3   | Prompts              | HephaestusCoreTests | The `text` block of every `### Prompt: <name>` section of `docs/chats.md` ([Chats](chats.md#system-prompts))                             | `Sources/HephaestusCore/Resources/prompts/<name>.md`                    | The sets of names are equal, and each file equals its block followed by one newline, byte for byte.                               |
| 4   | Data model examples  | HephaestusCoreTests | The YAML, JSON and JSON Lines examples of `docs/data-model.md` selected as stated in [Data model](data-model.md#conformance-tests)       | The Swift model type chosen by each example's path                      | Every example decodes, and passes the extra checks listed there.                                                                  |
| 5   | Repository files     | HephaestusCoreTests | Every fenced block of `docs/ci.md` whose preceding non-blank line is ``Contents of `<path>`:``                                           | The file `<path>`, relative to the repository root                      | The file's content equals the block's lines joined with `\n` plus one final `\n`, byte for byte.                                  |
| 6   | release.json example | UpdaterCoreTests    | The only fenced block of `docs/ci.md` whose info string is `json` ([release.json](#releasejson))                                         | `ReleaseManifest`                                                       | The block decodes and passes `validate()`.                                                                                        |
| 7   | Default skills       | HephaestusCoreTests | The `markdown` block of every `#### Default: <name>` section of `docs/skills.md` ([Internal skills](skills.md#default-skillmd-files))    | `Sources/HephaestusCore/Resources/skills/<name>/SKILL.md`               | The sets of names are equal, and each file equals its block followed by one newline, byte for byte.                               |

Tests 5, 6 and 7 are Default chosen at design time. Test 5 covers `.github/workflows/release.yml`, `.github/workflows/ci.yml`, `Resources/Info.plist`, `Resources/Updater-Info.plist` and `Resources/HephaestusV2.entitlements`.

## Local make targets

The `Makefile` at the repository root defines these targets ([Development](development.md)). `make` without a target runs `build`.

| Target                           | Commands                                                                                                                                                                                                                                                    | Result                                                                                                                                                                                                             |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `make build`                     | `swift build`                                                                                                                                                                                                                                               | Debug build of every target.                                                                                                                                                                                       |
| `make test`                      | `swift test`                                                                                                                                                                                                                                                | Every test target, docs conformance tests included.                                                                                                                                                                |
| `make app`                       | `scripts/build-app.sh --version 0.0.0 --build 0 --repository $(RELEASE_REPOSITORY) --configuration debug --arch native`                                                                                                                                     | The development bundle `build/HephaestusV2.app`: build number 0, so it never starts the Updater ([Starting the Updater](updater.md#starting-the-updater)); signed ad-hoc unless the certificate variables are set. |
| `make run`                       | `make app`, then `build/HephaestusV2.app/Contents/MacOS/HephaestusV2`                                                                                                                                                                                       | The development bundle runs in the foreground of the terminal with the terminal's environment; Control-C quits it like Quit.                                                                                       |
| `make release VERSION=… BUILD=…` | Fails with `VERSION and BUILD are required` when either is empty; `scripts/build-app.sh --version $(VERSION) --build $(BUILD) --repository $(RELEASE_REPOSITORY)`; `ditto -c -k --sequesterRsrc --keepParent build/HephaestusV2.app build/HephaestusV2.zip` | A universal release bundle and its zip in `build/`, signed and notarized as in CI when the variables of [App bundle](#app-bundle) are set; no `release.json`, tag or upload.                                       |
| `make check`                     | `scripts/check-public.sh` and `scripts/check-docs.sh`                                                                                                                                                                                                       | Runs both, then fails when either failed.                                                                                                                                                                          |
| `make install`                   | Fails when `build/HephaestusV2.app` does not exist; `rm -rf /Applications/HephaestusV2.app`; `ditto build/HephaestusV2.app /Applications/HephaestusV2.app`                                                                                                  | Installs the last bundle built. A development bundle installed this way never updates itself. It does not quit a running HephaestusV2: quit it first.                                                              |
| `make icon`                      | `swift scripts/make-icon.swift Resources/AppIcon.icns`                                                                                                                                                                                                      | Regenerates the app icon ([App icon](#app-icon)).                                                                                                                                                                  |
| `make clean`                     | `rm -rf .build build`                                                                                                                                                                                                                                       | Removes the build products.                                                                                                                                                                                        |

| Variable             | Default                | Used by                    |
| -------------------- | ---------------------- | -------------------------- |
| `RELEASE_REPOSITORY` | `Azavech/HephaestusV2` | `make app`, `make release` |
| `VERSION`            | —                      | `make release`             |
| `BUILD`              | —                      | `make release`             |

The version `0.0.0` and the debug native build of `make app`, the foreground run of `make run`, the targets `icon` and `clean`, and the variable `RELEASE_REPOSITORY` are Default chosen at design time.

### App icon

`swift scripts/make-icon.swift <output.icns>` draws the icon and writes it to the given path; `Resources/AppIcon.icns` is committed and no build runs the script. The icon is a square with rounded corners (radius 22.5 % of the side) filled with a vertical gradient from `#FF9F0A` at the top to `#FF3B30` at the bottom, with the SF Symbol `hammer.fill` in white, centred, 55 % of the side high. The script renders it at 16, 32, 128, 256 and 512 points, at 1x and 2x, into a temporary `AppIcon.iconset` (`icon_<n>x<n>.png` and `icon_<n>x<n>@2x.png`), then runs `iconutil -c icns` on it. The icon's design is Default chosen at design time.

## Requirements covered

- R1: HephaestusV2 is a new macOS app.
- R2: The project and the app are named HephaestusV2.
- R52: The app is on GitHub.
- R53: A GitHub pipeline builds the app automatically.
- R55: The app is built against the docs.
- R73: CI builds a new version of the app when changes are pushed to `main`.
- R74: The app has a second executable, the Updater.
- R84: GitHub CI then rebuilds the app.
