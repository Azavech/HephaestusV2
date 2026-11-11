# Views

The Views section of a Swift application project lists the views that its Swift files declare, SwiftUI, AppKit and UIKit views alike, in a tree of the folders that hold them, and shows the `#Preview` blocks of the view selected side by side, live on the Mac: the user clicks, scrolls and types in them inside the section, gives the Mac previews their width and height, and switches them between Light and Dark and between Dynamic Type sizes. The engine of the device that holds the project finds the views, builds the previews in the background from the project's code, without the user building anything, and runs them; each save of a file of the project builds them again, and a build that fails shows the compiler's errors in place of the previews. It works for Swift packages and Xcode projects, the HephaestusV2 project included, and in the windows of remote devices. This document specifies the section, the list of views, the previews, their builds and their refresh. The iPhone and iPad previews, the code editor beside the previews, the design with Claude, the New View sheet and the visual inspector are not part of it.

## Section

| Property    | Value                                                                                                                                                              |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Section     | `views` ([ProjectSection](engine-api.md#projectsection))                                                                                                           |
| Title       | `Views`                                                                                                                                                            |
| SF Symbol   | `rectangle.3.group`                                                                                                                                                |
| Shortcut    | none; View ▸ Views ([Menus and keyboard shortcuts](ui.md#menus-and-keyboard-shortcuts))                                                                            |
| Sidebar row | the only row of the Swift Application category, after the Project category and before Sub Projects, without badge, while the active project is a Swift application |
| Shows       | the views of the active project and the previews of the view selected ([List of views](#list-of-views), [Previews](#previews))                                     |

The title, the symbol, the category with its place, the condition and the absence of a shortcut and of a badge come from the user. View ▸ Views is a design-time choice, as for the [Graph](graph.md#section). Default chosen at design time.

### Visibility

- The Swift Application category, with its heading `Swift Application` and its row `Views`, shows while the active project's [type](projects.md#project-types) in the workspace's `projects` is `swiftApplication` ([Sidebar](ui.md#sidebar)). The types `none` and `goService` have no Swift Application category. It follows `projects.changed`, on This Mac and in remote windows: changing the type of the project, or switching to a project of another type, adds or removes the category at once, as for the Go Service category.
- View ▸ Views, without shortcut, is enabled while the row shows.
- When the window's section is `views` and the active project's type is not `swiftApplication`, after a switch of project or device, a navigation or a change of the type, the window selects Dashboard.

The leave to Dashboard is a design-time choice, as for the [Graph](graph.md#enabling). Default chosen at design time.

## Layout

```
┌───────────────────────────┬────────────────────────────────────────────────────────────────┐
│ Views                  12 │ CounterView  Sources/App/Counter.swift       Built at 14:03:12 │ pane headers
│ ▾ Sources                 │ Width [400] Height [300]   [Light|Dark]   Dynamic Type [Large⌄]│ controls bar
│   ▾ App                   ├────────────────────────────────────────────────────────────────┤
│       CounterView         │  First                      Preview 2                          │
│       ProfileView         │  ┌──────────────────────┐   ┌──────────────────────┐           │
│   ▾ Kit                   │  │                      │   │                      │           │
│       Canvas              │  │      live view       │   │      live view       │           │
│ ▸ Packages                │  │                      │   │                      │           │
│                           │  └──────────────────────┘   └──────────────────────┘           │
└───────────────────────────┴────────────────────────────────────────────────────────────────┘
  list of views, 260 pt                   previews of the view selected
```

- The list of views is at the left, 260 points wide by default; the divider between it and the previews can be dragged between 180 and 480 points, as in the [Code section](code-editor.md#layout). Its pane header, 36 points high ([Pane headers](ui.md#pane-headers)), shows `Views` in the headline font and, at its trailing edge, the number of views of the list in the secondary colour.
- The pane header of the previews shows the name of the view selected in the headline font, its project path in the secondary colour, and at its trailing edge the [status line](#status-line). Without a view selected, the previews area shows `No View Selected` and the line `Select a view in the list.`, without pane header or controls bar.
- The controls bar under it holds, in this order, the `Width` and `Height` fields, the `Light` / `Dark` segmented control and the `Dynamic Type` pop-up ([Preview settings](#preview-settings)).
- The previews fill the rest: side by side in one row, in the order of their `#Preview` blocks in the source, 20 points apart, with 20 points of padding, in an area that scrolls in both directions when they do not fit. Each preview shows its title above it in the subheadline font, its name, or `Preview <n>` for a block without a name, `<n>` its rank among the view's previews from 1, then the live view at the width and height of the settings, with a 1-point border in the separator colour.

The widths, the texts, the order of the controls, the spacing, the titles and the border are design-time choices. Default chosen at design time.

## List of views

The list comes from [views.list](engine-api.md#viewslist), which the engine of the device that holds the project runs on the project's folder.

### Swift files read

- Every regular file whose name ends with `.swift` under the project root, the folders of its sub projects included, at any depth. Folders named `.git`, `.build`, `build`, `DerivedData`, `node_modules`, `.swiftpm` and `.hephaestus` are skipped at any depth, as are symbolic links, files larger than 1 MiB and files that are not UTF-8.
- Comments and the contents of string literals are not read as code, raw and multi-line strings included.

The skipped folders, the 1 MiB limit and the encoding are design-time choices; the folders are those the walk of the code scope of search skips, with `.swiftpm` and `.hephaestus` ([File list](search.md#file-list)). Default chosen at design time.

### What a view is

A type declaration, `struct`, `class`, `enum` or `actor`, at the top level of a file or in the body of another type or of an extension, is a view when one of these holds; a type declared in a function, a closure, a property or a `#Preview` block is not.

1. **SwiftUI.** The type conforms to `View`: its inheritance clause, or the inheritance clause of an extension of it in the project, names `View`, `NSViewRepresentable`, `UIViewRepresentable`, `NSViewControllerRepresentable`, `UIViewControllerRepresentable`, `Shape` or `InsettableShape`, alone or after `SwiftUI.`, or a protocol of the project that names one of them in its own inheritance clause, at any depth. Its kind is `swiftUI`.
2. **AppKit and UIKit.** The type is a class whose superclass, the first type of its inheritance clause, is `NSView`, `UIView`, a class of the Apple frameworks that descends from them, or a class of the project that is itself an AppKit or UIKit view, at any depth. A class of the Apple frameworks descends from them when its name is two or three capital letters followed by a name that ends with `View`, such as `NSTableView`, `WKWebView`, `MKMapView` or `UICollectionReusableView`, or when it is one of `NSControl`, `NSButton`, `NSPopUpButton`, `NSTextField`, `NSSecureTextField`, `NSSearchField`, `NSTokenField`, `NSComboBox`, `NSSlider`, `NSSegmentedControl`, `NSStepper`, `NSSwitch`, `NSColorWell`, `NSDatePicker`, `NSLevelIndicator`, `NSPathControl`, `NSProgressIndicator`, `NSMatrix`, `NSBrowser`, `NSBox`, `NSRuleEditor`, `NSPredicateEditor`, `UIControl`, `UIButton`, `UILabel`, `UITextField`, `UISlider`, `UISwitch`, `UISegmentedControl`, `UIStepper`, `UIDatePicker`, `UIPageControl`, `UIRefreshControl`, `UIColorWell`, `UISearchBar`, `UINavigationBar`, `UIToolbar`, `UITabBar`, `UIWindow`, `UITableViewCell` and `UICollectionViewCell`. Its kind is `appKit` when the class at the top of its chain starts with `NS`, `uiKit` when it starts with `UI`, and otherwise `uiKit` when its file imports UIKit and not AppKit, `appKit` else.
3. Nothing else is a view: a type that conforms to `ViewModifier`, `ButtonStyle`, `App` or `Scene`, a view controller, a protocol and an extension are not listed.

- The name of a view is its name, after the names of the types it is declared in, separated by `.`, for example `SettingsView.Row`; generic parameters are not part of it. A type declared inside an `#if` block counts, whatever its condition. A file that declares the same name twice, in the branches of an `#if`, gives one view, the first declaration.
- The project's types are those of every Swift file read, whatever the module that compiles them: a superclass or a protocol is found by its name, after its last `.` for a qualified name.

The SwiftUI views with `NSViewRepresentable` and `UIViewRepresentable`, the AppKit and UIKit views and nothing else come from the user. The other representables, `Shape` and `InsettableShape`, which conform to `View`, the protocols of the project, the framework classes found by their names, the kinds, the names of nested views and the matching by name are design-time choices. Default chosen at design time.

### Folder tree

- The list is a tree of the folders that hold views, from the project root: a folder shows when one of its files, at any depth, declares a view, and a sub project's folder appears as an ordinary folder of its parent, as in the [Code section's file tree](code-editor.md#file-tree). Each view appears by its name under the folder of its file.
- Under a folder: its folders first, then its views, each group sorted by name in Finder order; views of the same name by file name, then by line.
- A folder row shows the `folder` symbol and its name, with a disclosure triangle. A view row shows the symbol of its kind, `swift` for SwiftUI, `macwindow` for AppKit and `iphone` for UIKit, in the accent colour, then its name; its help tag is its project path and line, `<path>:<line>`.
- Every folder is expanded when the list first shows. A click on a folder row, its triangle included, collapses or expands it; the folders collapsed are kept for the project while the window is open.
- A click on a view row selects it; the selected row is drawn on the accent colour with its symbol and name in white.
- While the first read of the list runs, the list shows a small spinner with `Reading the views…`. A read that fails shows the engine's message and a `Try Again` button. A project without views shows `No Views` and the line `This project declares no SwiftUI, AppKit or UIKit view.`

The tree of folders comes from the user. The order, the symbols, the help tag, the folders expanded at first and the texts are design-time choices. Default chosen at design time.

### Live updates

- The section reads the list again after each `files.changed` of the project ([Events](engine-api.md#event-list)) whose paths hold `""`, a path that ends with `.swift`, or a path whose last component has no `.`, a folder that may have changed, outside the skipped folders. It follows the Swift files on disk, whoever changed them: HephaestusV2, Claude or another app.
- The selected view stays selected while the list still has a view of the same name in the same file. When it disappears, no view is selected and its previews stop.

The reading on `files.changed` and the paths that cause it are design-time choices. Default chosen at design time.

## Previews

### Preview blocks

- A preview block is a `#Preview` macro of a Swift file read, with its arguments in parentheses or without them, and a trailing closure: its body. Its name is its first argument when that argument is a string literal without interpolation; it has no name otherwise. A `#Preview` with an argument labelled `as`, the preview of a widget with its timeline, is not a preview block.
- A preview block belongs to each view declared in the same file whose name, the last part of a nested name, appears in its body as an identifier. A block that names none of the file's views belongs to every view of the file.
- The previews of a view are its blocks in the order of the file. A view without blocks has no preview: selecting it shows `No Preview` and the line `<name> has no #Preview.` in the previews area, without starting a session.
- A block's body is used as written, with the declarations it may see in its file, `private` ones included. The lines that start with `@Previewable` declare the state of the preview, as in Xcode. A body that gives a SwiftUI view, an `NSView` or an `NSViewController` is shown; on the Mac, a body that gives a `UIView` or a `UIViewController` does not build. A block inside `#if` blocks whose conditions do not hold on the Mac shows `This preview does not build for macOS.` in the secondary colour.

The previews from the `#Preview` blocks of the source, all side by side, come from the user. The blocks belonging to the views they name, or to every view of their file, and the widget previews left out are design-time choices. Default chosen at design time.

### Showing a view

- Selecting a view that has previews starts a preview session with [previews.start](engine-api.md#previewsstart), with the view's file and name and the section's [preview settings](#preview-settings). The window follows the session with [previews.poll](engine-api.md#previewspoll) until it stops it with [previews.stop](engine-api.md#previewsstop): when another view is selected, when the section or the project is left and when the window closes.
- The engine builds the previews when the build of the view's target is missing or out of date ([Builds](#builds)), then runs them in a preview host ([Preview host](#preview-host)) and sends their images to the window. While the first build runs, the previews area shows a small spinner and `Building the previews…`; the status line shows the build's progress.
- The previews are live and interactive. A click, a drag, a move of the mouse over a preview and the scroll wheel or trackpad over it go to the view, at the same place in its coordinates. A click gives the preview the keyboard focus, drawn as the focus ring around it: the keys typed then go to the view, Tab and Escape included, and Copy, Cut, Paste, Select All, Undo and Redo of the Edit menu, with their shortcuts, act in the view. The other shortcuts keep their menu items.
- The menus, pop-up menus, popovers, sheets and other windows that a view opens are not shown: a menu closes as soon as it opens, so that the view never waits for it.
- A change of the [preview settings](#preview-settings) applies to the running previews with [previews.update](engine-api.md#previewsupdate), without a build.

Live and interactive previews come from the user. The keyboard focus, the Edit menu items, the menus closed at once and the texts are design-time choices. Default chosen at design time.

### Preview settings

| Setting      | Control                                                                                                                                                                 | Default                                                                     |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Width        | `Width` field, whole points from 50 to 2000                                                                                                                             | 400                                                                         |
| Height       | `Height` field, whole points from 50 to 2000                                                                                                                            | 300                                                                         |
| Appearance   | `Light` / `Dark` segmented control                                                                                                                                      | the app's appearance when the section first shows the project in the window |
| Dynamic Type | `Dynamic Type` pop-up: `Extra Small`, `Small`, `Medium`, `Large`, `Extra Large`, `Extra Extra Large`, `Extra Extra Extra Large`, `Accessibility 1` to `Accessibility 5` | `Large`                                                                     |

- A Mac preview has the width and the height of the fields, in points. A field takes its value when the user presses Return or leaves it; a value outside the range becomes its nearest bound, and a text that is not a number gives the field its previous value back.
- The appearance and the Dynamic Type size apply to every preview shown. The appearance is the appearance of the preview's window, Aqua or Dark Aqua, which SwiftUI gives as `colorScheme` and AppKit as `effectiveAppearance`. The Dynamic Type size is the `dynamicTypeSize` of the SwiftUI environment of every preview: on the Mac, SwiftUI keeps the size of its text styles whatever the Dynamic Type size, so only the views that read `dynamicTypeSize` change.
- The settings belong to the window and to the project: they apply to every view of the project the window shows, and are kept while the window is open, never synced nor persisted.

Light and Dark, the Dynamic Type size and the width and height that the user enters come from the user. The fields, the ranges, the defaults, the labels of the sizes and the settings kept per window and project are design-time choices. Default chosen at design time.

### Status line

The status line, at the trailing edge of the pane header of the previews, shows in the caption font:

- `Building… <n>/<m>` while a build runs, `<n>/<m>` the last progress of the build tool's output, or `Building…` before the first one;
- `Built at <time>` once the previews run, `<time>` the time their build ended, `HH:mm:ss`;
- `Build failed` in red while the previews area shows the errors of the last build;
- `The previews stopped` in red while it shows why the preview host stopped.

The texts are design-time choices. Default chosen at design time.

## Builds

The engine of the device that holds the project builds the previews, with the toolchain of its Xcode, in its data directory, `Runtime/previews/` ([Device data directory](architecture.md#device-data-directory)), one folder per package or Xcode project. The builds go there: the user's own `.build` and DerivedData folders are left alone.

### Package or Xcode project of a view

The view's file belongs to the nearest folder, from the file's folder up to the root of the project's top-level project, that holds a `Package.swift` or a folder whose name ends with `.xcodeproj`; a folder with both counts as the Swift package. A file under no such folder gives the failure `No Swift package or Xcode project holds <path>.`

### Swift package

1. The target of the view is the target of the package whose sources hold the file, as `swift package describe --type json` lists them. A file of no target gives the failure `No target of <package folder> builds <path>.`
2. The engine writes a build folder for the package in `Runtime/previews/`: a copy of its `Package.swift` with a preview host target added, links to the package's other entries, a copy of its `Package.resolved`, and for each target previewed a folder that copies the target's files, the code of each preview block added after its file, and the code of the preview host. The host target has the target's dependencies, resources and settings, and the name of its module, so that the code that names its own module compiles. A `@main` attribute is left out of the copy, and a `main.swift` with it.
3. `swift build --product <host target>` builds the host in that folder, with its own `.build`.

### Xcode project

1. The target of the view is the target of the Xcode project whose sources hold the file: a source file of its Sources build phase, or a file of a folder that the target synchronizes and does not exclude. A file of no target gives the failure `No target of <project name> builds <path>.` Only an application or a framework target is previewed; another kind gives the failure `Previews need an application or framework target: <target> is <product type>.`
2. `xcodebuild` builds the scheme named like the target, or the project's first scheme when none is, for macOS on this Mac's architecture, in the Debug configuration, with a debug dylib for an application and with private imports, into a folder of `Runtime/previews/`.
3. `swiftc` compiles the preview host with the code of the target's preview blocks, which import the target's module with access to its private declarations, links it to the target's debug dylib or framework, and places it in the built application, so that the previews find the application's resources.

### Build rules

- One build runs at a time for a package or an Xcode project. A change that comes during a build starts another build when it ends.
- A build that fails sets the session's state to `failed` with its errors: each `error:` line of the compiler, `<path>:<line>:<column>: error: <message>`, with the project path when the file is in the project, at most 50, in their order; a failed build without such a line gives the last 40 lines of its output. A failure before the build, such as a file of no target, gives its message.
- A target that does not build for macOS, an iOS-only target for example, fails with its compiler's errors.
- The first build of a project builds its dependencies too and can take minutes; the builds that follow compile what changed.

The build folder in the data directory, the search up to the top-level project, the host target, the copies, the scheme, the debug dylib and the private imports, the kinds of targets, the one build at a time, the 50 errors and the 40 lines are design-time choices. Default chosen at design time.

### Refresh

- When a file of the folder of a view's package or Xcode project changes on disk, outside the skipped folders of [Swift files read](#swift-files-read), whoever wrote it, HephaestusV2, Claude or another app, the engine builds its previews again, then restarts the preview host with the new build. The previews show the new images; the state of the views, their scroll positions and the text typed in them included, starts again.
- Unsaved edits are not on disk and do not refresh the previews.
- While the build runs, the previews keep showing their last images, still interactive, and the status line shows the build's progress.
- When the build fails, the previews area shows the compiler's errors in place of the previews, in SF Mono, selectable, the paths in the secondary colour; the next build that succeeds shows the previews again.

The refresh on save comes from the user. The changes that start a build and the previews kept during a build are design-time choices. Default chosen at design time.

## Preview host

- The preview host is the program that a build gives: it runs the previews of a target in windows that the user never sees, out of every display, draws each preview as a PNG image at 2 pixels per point, and gives the view the clicks, the moves, the scrolls and the keys of the window that shows it. It never takes the focus from the user's apps and has no Dock icon.
- One host runs per target previewed, for every session of that target, from every window and every device. It starts after the target's build succeeded, starts again after each build, and stops 60 seconds after its last session stopped, or when the engine stops.
- A host that stops while sessions use it, a crash of a preview for example, sets their state to `failed` with `The previews stopped: <reason>.`, `<reason>` being `exit code <n>` or `signal <n>`, followed by the last 40 lines of its standard error. The next build starts it again.
- A preview draws again when its view changes: the host sends a new image when its pixels changed, at most 20 times per second while the user acts on it and during the second after, then at most 4 times per second.

The windows out of every display, the 2 pixels per point, the host per target, its 60 seconds and the rates are design-time choices. Default chosen at design time.

## Remote windows

In a window that shows a remote device, the Views section works the same: the list is read with [views.list](engine-api.md#viewslist), and the builds and the preview hosts run on the device that holds the project, with its Xcode. The images of the previews come to the window with [previews.poll](engine-api.md#previewspoll), and the clicks, scrolls and keys go back with [previews.input](engine-api.md#previewsinput), so the previews stay live and interactive. The preview settings, the selection and the folders collapsed belong to the window and are never synced.

## Requirements covered

- R212: A Swift application has a Views section, in a Swift Application category, that lists its SwiftUI, AppKit and UIKit views by folder, sub projects included, and shows a view's `#Preview` blocks side by side, live and interactive on the Mac, at the entered size, in Light or Dark and a Dynamic Type size, built in the background and refreshed on save, with compiler errors, for packages, Xcode projects and remote windows.
