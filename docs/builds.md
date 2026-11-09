# Builds

The Builds section of the sidebar follows the GitHub Actions workflow runs and the releases of the active project's GitHub repository, so that the user does not leave HephaestusV2 for GitHub. The engine of the device that holds the project reads them with the GitHub CLI, `gh`, which the user installs and logs in to: the section lists the newest runs and releases, shows the jobs and steps of a run and the notes and assets of a release, re-runs and cancels runs, and saves release assets in the Downloads folder. It shows only for a project that has a [GitHub page](projects.md#github-page), and it refreshes itself every 30 seconds while it is shown.

## Section

| Property    | Value                                                                                                                                           |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Section     | `builds` ([ProjectSection](engine-api.md#projectsection))                                                                                       |
| Title       | `Builds`                                                                                                                                        |
| SF Symbol   | `shippingbox.and.arrow.backward`                                                                                                                |
| Shortcut    | ⌘B, View ▸ Builds ([Menus and keyboard shortcuts](ui.md#menus-and-keyboard-shortcuts))                                                          |
| Sidebar row | in the Project category, after Web and before Skills, without badge, only while the active project has a GitHub page ([Sidebar](ui.md#sidebar)) |
| Shows       | the workflow runs and the releases of the active project's GitHub repository                                                                    |

### Visibility

- The row shows while the active project's [ProjectDetail](engine-api.md#projectdetail) in the window's workspace has a `githubPage`. It follows `project.updated`, on This Mac and in remote windows: it appears when the page is typed in Project Settings, read from the origin or taken from the parent with `Use parent settings`, and it disappears when the project no longer has a page. While the active project's detail is not loaded, the row is hidden.
- View ▸ Builds (⌘B) is enabled while the row shows.
- When the window switches to another project or device while Builds is selected, and the new active project has no GitHub page once its detail is loaded, the window selects Dashboard. So does a window whose active project loses its GitHub page while Builds is selected, and a navigation to the `builds` section of a project that has no GitHub page ([Navigation](ui.md#navigation)). A page that the engine has not read from the origin yet counts as none there, for example right after Open Project… or before the engine has looked up its tools at launch: the window selects Dashboard, and the row appears when `project.updated` brings the page. Selecting Dashboard after the page was lost and after a navigation, and in this case, is Default chosen at design time.
- A window that opens on Builds, restored at launch or opened with New Window, keeps it, since a page read from the origin is not known before the engine has read the origin ([ProjectDetail](engine-api.md#projectdetail)). While the active project has no GitHub page, the lists show the failure of their calls, `Project <id> has no GitHub page.`, and the section reads again as soon as a page appears ([Refresh](#refresh)). Default chosen at design time.

## Repository

The section shows the repository `<owner>/<name>` of the project's GitHub page `https://github.com/<owner>/<name>`, as `githubPage` resolves it: a sub project whose `Use parent settings` is on shows the repository of its parent ([GitHub page](projects.md#github-page)). Each `builds.*` call resolves the page again, so a page that changes takes effect at the next refresh.

## gh calls

Every `builds.*` call runs `gh` on the device that holds the project, with the repository of its GitHub page; the calls of a remote window run on the main device, with its gh and its login ([Remote windows](#remote-windows)). `<repo>` stands for `github.com/<owner>/<name>`, so that a `GH_HOST` of the user's environment does not send the call to another host.

| Method                 | Command                                                                                                                                                        | Timeout |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `builds.listRuns`      | `gh run list --repo=<repo> --limit=50 --json=conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,startedAt,status,updatedAt,workflowName`    | 30 s    |
| `builds.getRun`        | `gh run view --repo=<repo> --json=conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,jobs,startedAt,status,updatedAt,workflowName -- <run>` | 30 s    |
| `builds.rerunRun`      | `gh run rerun --repo=<repo> -- <run>`; `gh run rerun --repo=<repo> --failed -- <run>` to run only the failed jobs again                                        | 30 s    |
| `builds.cancelRun`     | `gh run cancel --repo=<repo> -- <run>`                                                                                                                         | 30 s    |
| `builds.listReleases`  | `gh release list --repo=<repo> --limit=50 --exclude-drafts --json=createdAt,isLatest,isPrerelease,name,publishedAt,tagName`                                    | 30 s    |
| `builds.getRelease`    | `gh release view --repo=<repo> --json=assets,body,createdAt,isPrerelease,name,publishedAt,tagName -- <tag>`                                                    | 30 s    |
| `builds.downloadAsset` | `gh release download --repo=<repo> --pattern=<asset> --dir=<temporary folder> -- <tag>`                                                                        | 30 min  |

- Each option and its value are one argument. `<run>` is the run's id and `<tag>` the release's tag, both after `--`, so that a tag that starts with `-` is not read as an option. `<asset>` is the asset's name with `\` written before each `\`, `*`, `?` and `[`, so that the pattern matches that name only.
- **Lookup.** `gh` is the first executable file named `gh` in the `PATH` of the login-shell environment ([Child processes](architecture.md#child-processes)). The engine looks it up at every call, so that a gh installed while the app runs is found by the next refresh. A call that starts before the environment capture has finished waits for it. Default chosen at design time.
- **Process.** gh runs as a tool of [Child processes](architecture.md#child-processes): the login-shell environment without any `HEPHAESTUS_*` variable and without `CLICOLOR_FORCE`, `GH_FORCE_TTY`, `GH_DEBUG` and `DEBUG`, which make gh write colours into its JSON or debug lines into its standard error, plus `GH_PROMPT_DISABLED=1` and `GH_NO_UPDATE_NOTIFIER=1`, so that it never asks a question and never adds an update notice to its standard error; the project root as working directory; standard input empty; standard output and standard error read; after its timeout, `SIGTERM` to its process group, then `SIGKILL` 2 seconds later; at the app's shutdown, the signals of [Shutdown](architecture.md#shutdown). Default chosen at design time.
- Several calls run at the same time; the engine does not queue them.
- A date that gh writes as `0001-01-01T00:00:00Z`, for a time GitHub has not set, is absent from the results, and so is an empty conclusion.
- The timeouts, the one-argument options and passing the run or the tag after `--` are Default chosen at design time.

### Failures

| Case                                                                                      | Code        | Message                                                   |
| ----------------------------------------------------------------------------------------- | ----------- | --------------------------------------------------------- |
| The project has no GitHub page                                                            | unavailable | `Project <id> has no GitHub page.`                        |
| No `gh` in the `PATH`                                                                     | unavailable | `Install the GitHub CLI (gh) to see runs and releases.`   |
| gh exits with status 4, its status when it needs a login                                  | unavailable | `Run gh auth login in Terminal to see runs and releases.` |
| gh cannot start, exits with another status than 0, is ended by a signal or by its timeout | unavailable | `gh <command> failed: <reason>.`                          |
| The output of gh is not the JSON the call reads                                           | internal    | `gh <command> returned unexpected output: <reason>.`      |

- `<command>` is the gh command without its options, for example `run list` or `release download`.
- `<reason>` is `timeout` after the timeout; the system's error text when gh cannot be spawned; else the first non-empty line of its standard error, trimmed and without its trailing periods, for example `failed to get run: HTTP 404: Not Found (https://api.github.com/repos/owner/name/actions/runs/12?exclude_pull_requests=true)` for a run that does not exist; else `exit code <n>`, n being 128 + the signal number for a process ended by a signal. These are the reasons of [Version and status](chats.md#version-and-status).
- `<reason>` of unexpected output names the coding path and the problem, as the dispatcher writes them ([Dispatcher errors](engine-api.md#dispatcher-errors)).
- The messages of a missing gh and of a missing login come from the user; the others are Default chosen at design time.

## Engine API

Parameters, results and errors are in [Engine API](engine-api.md#builds). Only the user actor calls these methods, from local and remote windows: no MCP tool maps to them.

| Method                 | Effect                                                                                                        | Events |
| ---------------------- | ------------------------------------------------------------------------------------------------------------- | ------ |
| `builds.listRuns`      | the newest 50 workflow runs of every branch, newest first                                                     | none   |
| `builds.getRun`        | one run with its jobs and their steps                                                                         | none   |
| `builds.rerunRun`      | runs every job of a completed run again, or only its failed jobs                                              | none   |
| `builds.cancelRun`     | cancels a queued or running run                                                                               | none   |
| `builds.listReleases`  | the newest 50 published releases, newest first                                                                | none   |
| `builds.getRelease`    | one release with its notes and assets                                                                         | none   |
| `builds.downloadAsset` | saves an asset of a release in the Downloads folder of the device that holds the project and returns its path | none   |

- The results are read from GitHub at every call and kept nowhere: the engine stores no run and no release, and no event announces their changes. The section asks again instead ([Refresh](#refresh)).
- `builds.listRuns` and `builds.listReleases` keep the order of gh, newest first.
- In the engine (`Sources/HephaestusCore/Builds/`), the protocol `GitHubCLIRunning`, which the [Engine configuration](architecture.md#engine-configuration) gives, looks gh up and runs it: the app uses `SystemGitHubCLI`, and test engines a fake that never reaches GitHub. `GitHubCLIFailure` maps the outcome of a run to the failures above and `BuildsJSON` reads the output of gh into the [API types](engine-api.md#workflowrun). Default chosen at design time.

## Workflow runs

### Run list

The Workflow Runs list shows the result of `builds.listRuns`: the newest 50 runs of the repository, of every branch and every workflow, newest first. A row shows:

```
[status]  Release build of the app                  title, one line
          Release · main                            workflow name · branch
          7 Nov 2026 at 21:27 · 14m 17s             start time · duration
```

- **Status icon**, 16 points wide, from the run's `status` and `conclusion` ([Status](#status)).
- **Title**: the run's title (`displayTitle`), one line, truncated at its end.
- **Workflow name** and **branch**, separated by ` · `, in the secondary colour, one line truncated at its end. A run without workflow name, which gh gives for the runs of ruleset workflows, shows the branch alone.
- **Start time** and **duration**, separated by ` · `, in the secondary colour: the start time in the format of the ticket list's Created column ([Ticket list](tickets.md#ticket-list)) and the duration of [Durations](#durations).

The three lines and their content are Default chosen at design time.

### Status

The status icon and the status text of a run, a job or a step come from its `status` and, once it is `completed`, its `conclusion`:

| GitHub value                                                                                   | Icon                                        |
| ---------------------------------------------------------------------------------------------- | ------------------------------------------- |
| status `queued`, `requested`, `waiting` or `pending`                                           | `clock.fill` in orange                      |
| status `in_progress`                                                                           | a small spinner                             |
| conclusion `success`                                                                           | `checkmark.circle.fill` in green            |
| conclusion `failure`, `timed_out` or `startup_failure`                                         | `xmark.octagon.fill` in red                 |
| conclusion `cancelled`, `skipped`, `neutral`, `stale` or `action_required`, or any other value | `slash.circle.fill` in the secondary colour |

- The text is the conclusion of a completed item, otherwise its status, with `_` replaced by a space and its first letter in uppercase: `Success`, `Failure`, `Timed out`, `In progress`, `Queued`. A completed item without conclusion shows `Completed`.
- The icons of success and failure, the spinner and the grey of cancelled and skipped come from the user; the symbol and colour of queued, the grey symbol, the values grouped with failure and the texts are Default chosen at design time.

A run, job or step **failed** when its conclusion is `failure`, `timed_out` or `startup_failure`, and it is **running** while its status is not `completed`. Default chosen at design time.

### Durations

- A completed run lasts from its start (`startedAt`) to its last update (`updatedAt`), as gh counts it; a run that is not completed lasts from its start until now. A run has no `startedAt` before it starts: its start is then its creation (`createdAt`).
- A job or a step lasts from its `startedAt` to its `completedAt`, or until now while it has started and not completed; one that has not started has no duration and shows nothing.
- A duration is written with hours, minutes and seconds, a unit at 0 left out, for example `42s`, `14m 17s` or `1h 5s`; a negative duration counts as 0.
- The durations of what is not completed count up every second while they are shown.

The rules of the durations are Default chosen at design time.

### Run details

Clicking a run selects it (`ProjectViewState.selectedRunID`) and shows its details, read with `builds.getRun`:

| Part   | Content                                                                                                                                                         |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Header | the run's title, in a larger bold font, then the buttons below                                                                                                  |
| Fields | `Workflow`, `Branch`, `Commit` (the first 7 characters of `headSha`, monospaced), `Event` (for example `push`), `Status` (icon and text), `Duration`            |
| Jobs   | each job, in the order of gh: its status icon, its name and its duration, then its steps, indented, in step order, each with its status icon, name and duration |

| Button               | Shown                                                         | Call                                     |
| -------------------- | ------------------------------------------------------------- | ---------------------------------------- |
| `Re-run All Jobs`    | when the run is completed                                     | `builds.rerunRun` without `failedOnly`   |
| `Re-run Failed Jobs` | when the run is completed and at least one of its jobs failed | `builds.rerunRun` with `failedOnly` true |
| `Cancel Run`         | while the run is not completed: queued or in progress         | `builds.cancelRun`                       |

- While a call of these buttons runs, the three buttons are disabled. When it succeeds, the section refreshes at once ([Refresh](#refresh)). When it fails, the window shows the alert `<button title> failed` with the error's message ([Principles](ui.md#principles)).
- The commands of the buttons come from the user. Showing `Re-run All Jobs` and `Re-run Failed Jobs` only for a completed run is Default chosen at design time, and so are disabling the three buttons while a call runs, the layout of the details and the order of the parts.

## Releases

### Release list

The Releases list shows the result of `builds.listReleases`: the newest 50 published releases of the repository, newest first; drafts are left out. A row shows:

```
v0.41.0  [Latest]                           tag and badge
v0.41.0 (302) · 7 Nov 2026 at 21:41         name · date
```

- **Tag**, in the body font, and the **badge**: `Latest` in green when the release is the repository's latest release (`isLatest`), otherwise `Pre-release` in orange when it is a pre-release (`isPrerelease`), otherwise none. A badge is its text in a capsule of its colour.
- **Name** and **date**, separated by ` · `, in the secondary colour: the name, left out when it is empty, and the date of publication (`publishedAt`), or of creation when the release has none, in the format of the ticket list's Created column ([Ticket list](tickets.md#ticket-list)).

Leaving the drafts out, the colours of the badges and the layout of the rows are Default chosen at design time.

### Release details

Clicking a release selects it (`ProjectViewState.selectedReleaseTag`) and shows its details, read with `builds.getRelease`:

| Part   | Content                                                                                                                                                                                     |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Header | the tag, in a larger bold font, with the badge of the list row; under it the name, when it is not empty, and the date, as in the list                                                       |
| Notes  | the release notes (`body`) rendered as Markdown with the shared renderer ([Documentation viewer](documentation-viewer.md)); nothing when the release has no notes                           |
| Assets | under the heading `Assets`, one row per asset in the order of gh: its name, its size in the file style of `ByteCountFormatter` (for example `19 MB`), and `Download`; nothing without asset |

- The badge of the details is the badge of the release's row, since `gh release view` does not tell which release is the latest; a release that is no longer listed shows no badge.
- The notes render natively with `MarkdownBlockRenderer` and the options of the Skills editor: links do nothing and project images show as blocked ([Editor](skills.md#editor)); images with an `http` or `https` source load from the network on the Mac that shows the window ([Images](documentation-viewer.md#images)). Default chosen at design time.
- The notes draw the SF Symbol, color, font, shortcut, sound and animation markers as the Skills editor's preview does ([Editor](skills.md#editor), [Marker setup](documentation-viewer.md#marker-setup)): a click on the `▶` of a sound marker, the only link of the notes that acts, plays the sound of the section's project, and a failure shows the alert `Play Sound failed`; the font markers of a family of the project's font files are drawn in that face once it is read with `files.fonts` and `files.read` from that project.
- The source code archives that GitHub adds to every release are not assets and are not listed.
- The layout of the details and the order of the parts, the heading `Assets`, the size style and taking the badge from the list row are Default chosen at design time.

### Downloads

`Download` saves the asset with `builds.downloadAsset`, in the Downloads folder of the device that holds the project, which is This Mac, since remote windows have no `Download` ([Remote windows](#remote-windows)):

1. gh downloads the asset into a new folder of `<data dir>/Runtime/downloads/`, so that the Downloads folder never holds a partial file.
2. The engine moves the file into the Downloads folder with the asset's name, under the rules of a web download: `/` and `:` replaced by `_`, the name trimmed, and ` (1)`, ` (2)`, … inserted before the extension when the name is taken ([Downloads](web-tabs.md#downloads)).
3. The file gets the quarantine attributes of a web download, with the asset's URL (`https://github.com/<owner>/<name>/releases/download/<tag>/<asset>`) and the release's page (`https://github.com/<owner>/<name>/releases/tag/<tag>`), so that Gatekeeper checks it when it is opened.
4. The temporary folder is removed, also when a step fails, and the call returns the file's path.

- While the call runs, the asset's `Download` button shows a small spinner and is disabled, also when the section is shown again meanwhile (`ProjectViewState.buildsDownloads`, [WindowState](ui.md#windowstate)). Once the file is saved, the row shows `Show in Finder` in its place, which reveals the file in Finder, until the section is shown again. A failure shows the alert `Download failed` with the error's message.
- Downloads go on while the user switches section; they end with the app. Default chosen at design time.
- The temporary folder, the quarantine attributes, the spinner and `Show in Finder` are Default chosen at design time.

## Refresh

| When                                                                                                                         | What is read                                                               |
| ---------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| The section appears, the segmented control changes, the window switches project or device, the project's GitHub page changes | the list of the shown tab, then the details of its selected run or release |
| Every 30 seconds while the section is shown, counted from the end of the previous refresh                                    | the same                                                                   |
| `Refresh`, and the success of `Re-run All Jobs`, `Re-run Failed Jobs` or `Cancel Run`                                        | the same, at once                                                          |
| A run or release is selected                                                                                                 | its details                                                                |

- A window refreshes only the section it shows: the other tab, the other projects and the windows that do not show Builds read nothing. A remote window whose device reconnects reads again, as when the section appears.
- A refresh that is asked for while another one of the same window runs starts when that one ends, once.
- The list and the details keep what they show while a refresh runs, and replace it with its result; `Refresh` shows a small spinner in place of its icon meanwhile. A failed refresh replaces the list, or the details, with the failure ([Empty and error states](#empty-and-error-states)).
- The 30 seconds come from the user; counting them from the end of the previous refresh, reading only the shown tab, reading again when the page changes or the device reconnects, starting a refresh asked for meanwhile once after the running one, keeping the list and the details while a refresh runs and the spinner of `Refresh` are Default chosen at design time.

## Layout

```
┌──────────────────────────────────────┬──────────────────────────────────────────────┐
│ [Workflow Runs | Releases]       (↻) │ Release build of the app                     │ 36 pt header
├──────────────────────────────────────┤ [Re-run All Jobs]                            │
│ ✓ Release build of the app           │                                              │
│   Release · main                     │ Workflow  Release                            │
│   7 Nov 2026 at 21:27 · 14m 17s      │ Branch    main                               │
│ ◌ Add the Builds section             │ Commit    ec49a8f                            │
│   CI · HEPH-106                      │ …                                            │
│   7 Nov 2026 at 22:05 · 3m 2s        │ Jobs                                         │
│                                      │ ✓ release                          14m 13s   │
│                                      │     ✓ Set up job                        1s   │
└──────────────────────────────────────┴──────────────────────────────────────────────┘
```

- The section has two panes, side by side, separated by a divider that the user drags, as the list and the detail of the Tickets section ([Tickets section](tickets.md#tickets-section)): the list pane, at least 240 points wide and 320 points wide when the section appears, and the detail pane, at least 300 points wide, which takes the rest.
- The list pane has a header 36 points high, separated from the list by a hairline: the segmented control `Workflow Runs` | `Releases` on its left (`ProjectViewState.buildsTab`, `runs` or `releases`, `runs` at first), and on its right the `Refresh` button, which shows the SF Symbol `arrow.clockwise` with the tooltip and accessibility label `Refresh`.
- A click on a row of the list selects it; the selected row is drawn on a background in the accent colour.
- The detail pane shows the details of the run or release selected in the shown tab, in a scroll view.
- The tab and the selections are kept per window and per project, so that switching section or project and coming back shows the same run or release ([WindowState](ui.md#windowstate)).
- The widths of the panes, the icon of `Refresh`, the look of the selected row and the scroll view are Default chosen at design time.

## Empty and error states

| State                                   | Content                                                                        |
| --------------------------------------- | ------------------------------------------------------------------------------ |
| The list has not loaded yet             | a spinner in place of the list                                                 |
| No `gh` in the `PATH`                   | `Install the GitHub CLI (gh) to see runs and releases.` in place of the list   |
| gh is not logged in                     | `Run gh auth login in Terminal to see runs and releases.` in place of the list |
| The repository has no run               | `No workflow runs yet.` in place of the list                                   |
| The repository has no published release | `No releases yet.` in place of the list                                        |
| Another failure of the list             | the error's message in place of the list; `Refresh` tries again                |
| No run or release selected              | `Select a run` or `Select a release` in the detail pane                        |
| The details have not loaded yet         | a spinner in the detail pane                                                   |
| The details fail                        | the error's message in the detail pane; `Refresh` tries again                  |

- The texts of a missing gh, of a missing login, of no run and of no release come from the user; the others are Default chosen at design time.
- A selected run that has left the newest 50, or a release that has left the list, keeps its details, read with its id or tag; a run or release that no longer exists shows the message of its failed call. Default chosen at design time.

## Remote windows

- A remote window shows the section of the main device's projects through the same methods: gh runs on the main device, with its installation and its login, and the texts of a missing gh and of a missing login are about the main device ([Remote devices](remote.md)).
- `Download` and `Show in Finder` are hidden in remote windows, as `Reveal in Finder` is ([Principles](ui.md#principles)).
- Re-run and cancel act on GitHub from remote windows too.

## Requirements covered

- R173: A project with a GitHub page has a Builds section that tracks its workflow runs and releases, re-runs and cancels runs and downloads release assets.
- R189: Every Markdown view of the app draws the SF Symbol, color, font, shortcut, sound and animation markers the same way, and a click on ▶ plays the sound.
