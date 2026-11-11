# Views

The Views section of a Swift application project lists the views that its Swift files declare, SwiftUI, AppKit and UIKit views alike, in a tree of the folders that hold them, and shows the `#Preview` blocks of the view selected side by side, live: on the Mac, and on the iPhone and iPad devices the user checks for a view whose target builds for iOS, each with the device's screen size and size classes, in portrait or landscape. The user clicks, scrolls and types in them inside the section, gives the Mac previews their width and height, and switches them between Light and Dark and between Dynamic Type sizes. The devices come from `devices.json` in the data directory of the Mac that shows the window, where the user adds custom sizes. Beside the previews, the view's Swift file opens in the code editor of the Code section, where the user changes the view's code by hand. The engine of the device that holds the project finds the views, builds the previews in the background from the project's code, without the user building anything, and runs them, the device previews in the iOS Simulator; each save of a file of the project builds them again, and a build that fails shows the compiler's errors in place of the previews. It works for Swift packages and Xcode projects, the HephaestusV2 project included, and in the windows of remote devices. The user designs the views with Claude in the project chat of the inspector, while the section shows them: each message carries the view shown, Claude sees its previews after each change, writes the `#Preview` of a view that has none and creates the new views the user describes. This document specifies the section, the list of views, the editor of the view's file, the New View sheet, the previews, the device previews, their builds and their refresh, and the design with Claude. The visual inspector is not part of it.

## Section

| Property    | Value                                                                                                                                                              |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Section     | `views` ([ProjectSection](engine-api.md#projectsection))                                                                                                           |
| Title       | `Views`                                                                                                                                                            |
| SF Symbol   | `rectangle.3.group`                                                                                                                                                |
| Shortcut    | none; View ▸ Views ([Menus and keyboard shortcuts](ui.md#menus-and-keyboard-shortcuts))                                                                            |
| Sidebar row | the only row of the Swift Application category, after the Project category and before Sub Projects, without badge, while the active project is a Swift application |
| Shows       | the views of the active project, the file and the previews of the view selected ([List of views](#list-of-views), [Editor](#editor), [Previews](#previews))        |

The title, the symbol, the category with its place, the condition and the absence of a shortcut and of a badge come from the user. View ▸ Views is a design-time choice, as for the [Graph](graph.md#section). Default chosen at design time.

### Visibility

- The Swift Application category, with its heading `Swift Application` and its row `Views`, shows while the active project's [type](projects.md#project-types) in the workspace's `projects` is `swiftApplication` ([Sidebar](ui.md#sidebar)). The types `none` and `goService` have no Swift Application category. It follows `projects.changed`, on This Mac and in remote windows: changing the type of the project, or switching to a project of another type, adds or removes the category at once, as for the Go Service category.
- View ▸ Views, without shortcut, is enabled while the row shows.
- When the window's section is `views` and the active project's type is not `swiftApplication`, after a switch of project or device, a navigation or a change of the type, the window selects Dashboard.

The leave to Dashboard is a design-time choice, as for the [Graph](graph.md#enabling). Default chosen at design time.

## Layout

```
┌────────────────────┬──────────────────────────────────┬──────────────────────────────────────────────────────────────────┐
│ Views       12 [+] │ Sources/App/Counter.swift ●      │ CounterView                                    Built at 14:03:12 │ pane headers
│ ▾ Sources          │ 1 │ import SwiftUI               │ Width [400] Height [300] [Light|Dark] Dynamic Type [Large⌄]      │ controls bar
│   ▾ App            │ 2 │                              │ [Portrait|Landscape] [▯▯]                                        │
│       CounterView  │ 3 │ struct CounterView: View {   ├──────────────────────────────────────────────────────────────────┤
│       ProfileView  │ 4 │     @State var count = 0     │  Mac · 400 × 300 pt        iPhone 18 Pro · 402 × 874 pt · wC hR  │
│   ▾ Kit            │ 5 │     var body: some View {    │  First       Preview 2     First        Preview 2                │
│       Canvas       │ 6 │         Button("\(count)") { │  ┌────────┐  ┌────────┐    ┌────────┐   ┌────────┐               │
│ ▸ Packages         │ 7 │             count += 1       │  │  live  │  │  live  │    │  live  │   │  live  │               │
│                    │ 8 │         }                    │  │  view  │  │  view  │    │  view  │   │  view  │               │
│                    │ 9 │     }                        │  └────────┘  └────────┘    └────────┘   └────────┘               │
└────────────────────┴──────────────────────────────────┴──────────────────────────────────────────────────────────────────┘
  list of views, 260 pt   editor of the view's file             previews of the view selected
```

- The list of views is at the left, 260 points wide by default; the divider between it and the editor can be dragged between 180 and 480 points, as in the [Code section](code-editor.md#layout). Its pane header, 36 points high ([Pane headers](ui.md#pane-headers)), shows `Views` in the headline font and, at its trailing edge, the number of views of the list in the secondary colour, then the `+` button of the [New View sheet](#new-view-sheet).
- The [editor](#editor) of the view's file is in the middle and the previews at the right. The divider between them can be dragged: the editor takes half of their width at first, each side keeps at least 180 points, and the editor's share is kept for the project while the window is open. The editor's pane header shows the project path of the file, then `●` while the editor has unsaved changes; the editor's banner, when it has one, is under it.
- The pane header of the previews shows the name of the view selected in the headline font and, at its trailing edge, the [status line](#status-line). Without a view selected, the previews area shows `No View Selected` and the line `Select a view in the list.`, without pane header or controls bar; while the editor holds no file, that text takes the editor's place too.
- The controls bar under the pane header of the previews holds, in this order, the `Width` and `Height` fields, the `Light` / `Dark` segmented control, the `Dynamic Type` pop-up, the `Portrait` / `Landscape` segmented control and the device button ([Preview settings](#preview-settings), [Devices popover](#devices-popover)).
- The previews fill the rest, side by side in one row, in an area that scrolls in both directions when they do not fit, with 20 points of padding: the Mac's previews first, then those of each checked device in the order of the [devices popover](#devices-popover), each device's group 40 points from the next ([Devices side by side](#devices-side-by-side)). In a group, the previews are in the order of their `#Preview` blocks in the source, 20 points apart. Each preview shows its title above it in the subheadline font, its name, or `Preview <n>` for a block without a name, `<n>` its rank among the view's previews from 1, then the live view at its size, with a 1-point border in the separator colour. While the Mac's group is the only one, it has no heading, as before the device previews.
- When the controls bar is too narrow for its controls on one line, the `Portrait` / `Landscape` control and the device button go to a second line; when it is too narrow for its two lines, the bar scrolls horizontally.

The editor beside the previews comes from the user. Its place between the list and the previews, its share of the width, its pane header, the widths, the texts, the order of the controls, the spacing, the titles and the border are design-time choices. Default chosen at design time.

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
- The selected view stays selected while the list still has a view of the same name in the same file. When it disappears, no view is selected and its previews stop; the editor keeps its file ([Editor](#editor)).

The reading on `files.changed` and the paths that cause it are design-time choices. Default chosen at design time.

## Editor

The Swift file of the view selected opens beside its previews in the code editor of the Code section ([Code editor](code-editor.md#editor)): the same editor, with its line numbers, its [editing behaviour](code-editor.md#editing-behaviour), its find bar and the [syntax highlighting](code-editor.md#swift) of Swift, the same [saving](code-editor.md#saving) and the same handling of [changes on disk](code-editor.md#changes-on-disk). The user changes the view's code there by hand.

- Selecting a view opens its file in the editor, read with `files.read` ([Opening files](code-editor.md#opening-files)), and puts the line of the view's declaration in the vertical middle of the editor, the insertion point at the start of that line, without giving the editor the keyboard focus. Selecting another view of the same file keeps the editor's text, unsaved changes included, and moves to that view's line.
- Selecting a view of another file while the editor has unsaved changes first shows the alert of [Unsaved changes](ui.md#unsaved-changes-and-quitting): `Save` saves the file, then opens the other one, and a save that fails keeps the view selected; `Don't Save` drops the changes; `Cancel` keeps the view selected.
- File ▸ Save (⌘S) saves the file with `files.write`, formatted on save as in the Code section; Go to Line (⌘L), Toggle Comment (⌘/) and the find bar act in the editor while it has the focus ([Menus and keyboard shortcuts](ui.md#menus-and-keyboard-shortcuts)). Each save builds the previews again ([Refresh](#refresh)); what the user types does not, until it is saved.
- The editor only writes the file: nothing is committed or pushed. The change stays uncommitted in the project's working tree, for the user or Claude to commit.
- The editor follows the changes on disk as a Code section tab does: a clean editor takes the new text silently, an editor with unsaved changes shows the banner `This file changed on disk.` with `Reload` and `Keep Mine`, and a file deleted on disk removes a clean editor and shows the banner `This file was deleted on disk.` with `Save` and `Close` above an editor with unsaved changes ([Banners](code-editor.md#banners)). A file larger than 2 MB opens read-only, with the large-file banner ([Large and binary files](code-editor.md#large-and-binary-files)).
- The editor belongs to the window and the project, as the Docs section's doc does: it is kept while the window is open, when the window shows another section or project, and when the view selected disappears from the list, a view renamed in the editor for example; then `No View Selected` shows beside it until a view is selected again. It is never persisted. Its unsaved changes count when the window closes, the project is removed or the app quits ([Unsaved changes and quitting](ui.md#unsaved-changes-and-quitting)).
- The same file can be open in a Code section tab, in the Views section of another window or on another device: each editor follows the changes on disk on its own.

The editor beside the previews, the code editor of the Code section with its editing behaviour, its highlighting, its saving and its handling of changes on disk, the refresh on save and not while typing, and the changes left uncommitted come from the user. The declaration line shown without the focus, the alert when a view of another file is selected and the editor kept when its view disappears are design-time choices. Default chosen at design time.

## New View sheet

The `+` button at the trailing edge of the list's pane header, with the help tag `New View…`, opens the sheet `New View` on the window ([WindowState](ui.md#windowstate)). It shows in every state of the list: while the first read runs, after a read that failed and without views.

```
┌──────────────────────────────────────────────┐
│ New View                                     │
│                                              │
│   Name  [ProfileView                       ] │
│ Folder  [Sources/App                      ⌄] │
│                                              │
│                          [Cancel]  [Create]  │
└──────────────────────────────────────────────┘
```

| Element | Behaviour                                                                                                                                                                                                                                                                                                                                                       |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Name    | Text field, empty, with the keyboard focus when the sheet opens.                                                                                                                                                                                                                                                                                                |
| Folder  | Combo box: a project path that the user types, or picks in its list, which holds `/` for the project root, then every folder of the [list of views](#folder-tree), collapsed ones included, in the order of the list. It holds at first the folder of the view selected; without a view selected, the folder of the first view of the list; without views, `/`. |
| Create  | Default button, enabled while the name and the folder are valid, no creation runs and the window's device is connected.                                                                                                                                                                                                                                         |
| Cancel  | Closes the sheet; Escape does the same.                                                                                                                                                                                                                                                                                                                         |

1. The name is trimmed, and a `.swift` at its end, in any case, is removed. It is valid when it starts with a letter or `_`, holds only letters, digits and `_`, the letters being `A` to `Z` and `a` to `z`, and is not `_` alone: the name of a Swift type. Once the field has been edited, an invalid name shows `Use a name such as ProfileView.` under it.
2. The folder is trimmed, and every `/` at its start and at its end is removed; what remains is a project path, the project root when it is empty. It is invalid when it has an empty, `.` or `..` component, and then shows `Use a folder such as Sources/App, or / for the project root.` under it. A folder that does not exist is created, with its missing parents.
3. The path of the file is the folder joined with `<name>.swift`. [files.create](engine-api.md#filescreate) creates it; a `conflict` shows `<path> already exists.` under the name and keeps the sheet open.
4. [files.write](engine-api.md#fileswrite) writes the [new view's file](#new-views-file) to it; `Format Swift files on save` applies as for a save of the editor ([Editor](ui.md#editor)). Any other failure of either call shows the alert `Create failed` with the engine's message ([UI](ui.md#principles)) and keeps the sheet open.
5. The sheet closes. The folders above the file are expanded, the list is read again, and the new view is selected as soon as a read of the list has it, as a view the user selects ([Editor](#editor)): the list scrolls to its row, its file opens in the editor and its previews start ([Showing a view](#showing-a-view)).

The file stays in the project's working tree, uncommitted: nothing is committed or pushed. In a remote window, the engine of the device that holds the project writes it ([Remote windows](#remote-windows)).

### New view's file

The file holds a SwiftUI view of the name and a `#Preview` of it, in UTF-8, with LF line ends, a line end after its last line and four spaces of indentation. For the name `ProfileView`, the file `ProfileView.swift`:

```swift
import SwiftUI

struct ProfileView: View {
    var body: some View {
        Text("Hello, World!")
    }
}

#Preview {
    ProfileView()
}
```

The `+` button in the Views section, the sheet with the view's name and a folder of the project, the file `<name>.swift` in that folder with a SwiftUI view of that name and its `#Preview`, the new view selected with its preview, the file left uncommitted and the remote windows come from the user. The place of the button and its help tag, the combo box, its list and its first folder, the rules of the name and of the folder and their messages, the `.swift` removed, the folders created, the text of the file, Xcode's SwiftUI View template without its header comment, and the scroll to the new row are design-time choices. Default chosen at design time.

## Previews

### Preview blocks

- A preview block is a `#Preview` macro of a Swift file read, with its arguments in parentheses or without them, and a trailing closure: its body. Its name is its first argument when that argument is a string literal without interpolation; it has no name otherwise. A `#Preview` with an argument labelled `as`, the preview of a widget with its timeline, is not a preview block.
- A preview block belongs to each view declared in the same file whose name, the last part of a nested name, appears in its body as an identifier. A block that names none of the file's views belongs to every view of the file.
- The previews of a view are its blocks in the order of the file. A view without blocks has no preview: selecting it shows `No Preview`, the line `<name> has no #Preview.` and the `Create Preview` button ([Create Preview](#create-preview)) in the previews area, without starting a session.
- A block's body is used as written, with the declarations it may see in its file, `private` ones included. The lines that start with `@Previewable` declare the state of the preview, as in Xcode. A body that gives a SwiftUI view, an `NSView` or an `NSViewController` is shown on the Mac, and a body that gives a SwiftUI view, a `UIView` or a `UIViewController` on a device; on the Mac, a body that gives a `UIView` or a `UIViewController` does not build, and on a device a body that gives an `NSView` or an `NSViewController`. A block inside `#if` blocks whose conditions do not hold on the Mac shows `This preview does not build for macOS.` in the secondary colour in the Mac's group, and one whose conditions do not hold on iOS shows `This preview does not build for iOS.` in a device's group.

The previews from the `#Preview` blocks of the source, all side by side, come from the user. The blocks belonging to the views they name, or to every view of their file, and the widget previews left out are design-time choices. Default chosen at design time.

### Showing a view

- Selecting a view that has previews starts a preview session with [previews.start](engine-api.md#previewsstart), with the view's file and name and the section's [preview settings](#preview-settings), the checked devices included. The window follows the session with [previews.poll](engine-api.md#previewspoll) until it stops it with [previews.stop](engine-api.md#previewsstop): when another view is selected, when the section or the project is left and when the window closes.
- The engine builds the previews when the build of the view's target is missing or out of date ([Builds](#builds)), then runs them in a preview host ([Preview host](#preview-host)) and sends their images to the window. While the first build runs, the previews area shows a small spinner and `Building the previews…`; the status line shows the build's progress.
- The previews are live and interactive. A click, a drag, a move of the mouse over a preview and the scroll wheel or trackpad over it go to the view, at the same place in its coordinates. A click gives the preview the keyboard focus, drawn as the focus ring around it: the keys typed then go to the view, Tab and Escape included, and Copy, Cut, Paste, Select All, Undo and Redo of the Edit menu, with their shortcuts, act in the view. The other shortcuts keep their menu items.
- The menus, pop-up menus, popovers, sheets and other windows that a view opens are not shown: a menu closes as soon as it opens, so that the view never waits for it.
- A change of the [preview settings](#preview-settings) applies to the running previews with [previews.update](engine-api.md#previewsupdate), without a build, except the first device checked for a target that has no build for iOS yet, which starts that build ([Builds](#builds)).

Live and interactive previews come from the user. The keyboard focus, the Edit menu items, the menus closed at once and the texts are design-time choices. Default chosen at design time.

### Preview settings

| Setting      | Control                                                                                                                                                                 | Default                                                                     |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Width        | `Width` field, whole points from 50 to 2000                                                                                                                             | 400                                                                         |
| Height       | `Height` field, whole points from 50 to 2000                                                                                                                            | 300                                                                         |
| Appearance   | `Light` / `Dark` segmented control                                                                                                                                      | the app's appearance when the section first shows the project in the window |
| Dynamic Type | `Dynamic Type` pop-up: `Extra Small`, `Small`, `Medium`, `Large`, `Extra Large`, `Extra Extra Large`, `Extra Extra Extra Large`, `Accessibility 1` to `Accessibility 5` | `Large`                                                                     |
| Orientation  | `Portrait` / `Landscape` segmented control, for the device previews                                                                                                     | `Portrait`                                                                  |
| Devices      | the device button and its [devices popover](#devices-popover): the devices checked                                                                                      | the first device of the iPhone family                                       |

- A Mac preview has the width and the height of the fields, in points. A field takes its value when the user presses Return or leaves it; a value outside the range becomes its nearest bound, and a text that is not a number gives the field its previous value back.
- The appearance and the Dynamic Type size apply to every preview shown. On the Mac, the appearance is the appearance of the preview's window, Aqua or Dark Aqua, which SwiftUI gives as `colorScheme` and AppKit as `effectiveAppearance`; on a device, it is the `userInterfaceStyle` of the preview's traits, which SwiftUI also gives as `colorScheme`. The Dynamic Type size is the `dynamicTypeSize` of the SwiftUI environment of every preview: on the Mac, SwiftUI keeps the size of its text styles whatever the Dynamic Type size, so only the views that read `dynamicTypeSize` change; on a device, it is also the `preferredContentSizeCategory` of the preview's traits, so that the text styles take its size, as on the device.
- The Width and Height fields give the size of the Mac previews only. A device preview has the size and the size classes of its device in the orientation chosen ([Device previews](#device-previews)); the orientation does not change the Mac previews.
- The settings belong to the window and to the project: they apply to every view of the project the window shows, and are kept while the window is open, never synced nor persisted. The devices checked are kept by name: a device that `devices.json` no longer lists is no longer checked, and a device whose values change in the file shows its new values.

Light and Dark, the Dynamic Type size and the width and height that the user enters come from the user, as do the orientation, portrait or landscape, and the devices checked in the popover. The fields, the ranges, the defaults, the labels of the sizes and of the orientations, the first iPhone checked by default and the settings kept per window and project are design-time choices. Default chosen at design time.

### Status line

The status line, at the trailing edge of the pane header of the previews, shows in the caption font:

- `Building… <n>/<m>` while a build runs, `<n>/<m>` the last progress of the build tool's output, or `Building…` before the first one;
- `Built at <time>` once the previews run, `<time>` the time their build ended, `HH:mm:ss`;
- `Build failed` in red while the previews area shows the errors of the last build;
- `The previews stopped` in red while it shows why the preview host stopped.

The texts are design-time choices. Default chosen at design time.

## Device previews

A view whose target builds for iOS shows its previews on the iPhone and iPad devices that the user checks in the [devices popover](#devices-popover), live and interactive as the Mac previews, each with the device's screen size and its horizontal and vertical size classes in the orientation chosen, so that the view lays out as on that device. They run in the iOS Simulator of the device that holds the project ([iOS Simulator](#ios-simulator)).

The device previews of a view whose target builds for iOS or iPadOS, on the iPhone and iPad devices checked, live and interactive, with each device's screen size and size classes, in portrait or landscape, and their run in the iOS Simulator come from the user.

### Devices file

- The devices come from `devices.json` in the data directory of the Mac that shows the window, next to `settings.yml` ([Devices file](data-model.md#devices-file)). In a window of a remote device too, the list is that of the Mac the user uses.
- When HephaestusV2 starts and `devices.json` is missing, it writes the file with the [built-in devices](#built-in-devices). It writes the built-in list only into a missing file: never into an existing file, valid or not, also after an update that changes the built-in list. A file removed while the app runs is written again with the built-in list.
- HephaestusV2 reads the file again 300 ms after it changes on disk, whoever changed it: the popover and the device previews of every window follow it.
- A file that cannot be read or is not a valid devices file gives no device, and the popover shows `devices.json cannot be read: <reason>` in place of its list. A device of the file that breaks a rule of [Devices file](data-model.md#devices-file), or whose name an earlier device of the file has, is left out; the others show.

The 300 ms, the rewrite of a removed file, the devices left out and the text are design-time choices. Default chosen at design time.

### Built-in devices

The built-in list holds these devices, in this order: the iPhone models, the iPad models, then the iPad window sizes. The sizes are in points, in portrait; the size classes are horizontal, then vertical.

| Name                                 | Family | Size        | Scale | Portrait         | Landscape        |
| ------------------------------------ | ------ | ----------- | ----- | ---------------- | ---------------- |
| `iPhone 18 Pro`                      | iPhone | 402 × 874   | 3     | Compact, Regular | Compact, Compact |
| `iPhone 18 Pro Max`                  | iPhone | 440 × 956   | 3     | Compact, Regular | Regular, Compact |
| `iPhone Air`                         | iPhone | 420 × 912   | 3     | Compact, Regular | Regular, Compact |
| `iPhone 17`                          | iPhone | 402 × 874   | 3     | Compact, Regular | Compact, Compact |
| `iPhone 17e`                         | iPhone | 390 × 844   | 3     | Compact, Regular | Compact, Compact |
| `iPhone 16 Plus`                     | iPhone | 430 × 932   | 3     | Compact, Regular | Regular, Compact |
| `iPhone 13 mini`                     | iPhone | 360 × 780   | 3     | Compact, Regular | Compact, Compact |
| `iPhone SE (3rd generation)`         | iPhone | 375 × 667   | 2     | Compact, Regular | Compact, Compact |
| `iPad Pro 13-inch (M5)`              | iPad   | 1032 × 1376 | 2     | Regular, Regular | Regular, Regular |
| `iPad Pro 11-inch (M5)`              | iPad   | 834 × 1210  | 2     | Regular, Regular | Regular, Regular |
| `iPad Air 13-inch (M4)`              | iPad   | 1024 × 1366 | 2     | Regular, Regular | Regular, Regular |
| `iPad Air 11-inch (M4)`              | iPad   | 820 × 1180  | 2     | Regular, Regular | Regular, Regular |
| `iPad (A16)`                         | iPad   | 820 × 1180  | 2     | Regular, Regular | Regular, Regular |
| `iPad mini (A20 Pro)`                | iPad   | 756 × 1158  | 2     | Regular, Regular | Regular, Regular |
| `iPad Pro 13-inch (M5) · 1/3 window` | iPad   | 375 × 1032  | 2     | Compact, Regular | Compact, Regular |
| `iPad Pro 11-inch (M5) · 1/3 window` | iPad   | 375 × 834   | 2     | Compact, Regular | Compact, Regular |
| `iPad Pro 11-inch (M5) · 1/2 window` | iPad   | 600 × 834   | 2     | Compact, Regular | Compact, Regular |
| `iPad Air 11-inch (M4) · 1/2 window` | iPad   | 585 × 820   | 2     | Compact, Regular | Compact, Regular |
| `iPad mini (A20 Pro) · 1/3 window`   | iPad   | 320 × 756   | 2     | Compact, Regular | Compact, Regular |
| `iPad mini (A20 Pro) · 1/2 window`   | iPad   | 574 × 756   | 2     | Compact, Regular | Compact, Regular |

- The models and their screens are those of the iOS 27.2 Simulator runtime. An iPhone has a compact width and a regular height in portrait; in landscape, a compact height, and a regular width when it is 414 points wide or more in portrait.
- An iPad window size is a window that shares the screen of the iPad held in landscape with another app: a third or a half of its width, less the 10-point divider, and its full height, the widths that give the iPad a compact width. A window keeps its size classes in landscape.

The iPhone and iPad models and iPad window sizes come from the user. The models chosen, the windows chosen, their names, the rule of the iPhone landscape size classes and the size classes of the windows in landscape are design-time choices. Default chosen at design time.

### Devices popover

- The device button, at the end of the controls bar, is an icon button with the symbol `ipad.and.iphone` and the help tag `Devices`; it opens the devices popover under it.
- The popover, 520 points wide, shows `Devices` in the headline font, then the devices of `devices.json` grouped by family, in a list that scrolls when it is taller than 360 points: the heading `iPhone` and the devices of the iPhone family, then the heading `iPad` and the devices of the iPad family, each family in the order of the file. A family without device has no heading; a file without device shows `No Devices` in the secondary colour.
- Each row is a checkbox with the device's name; after it, in the secondary colour and the caption font, its size classes, `w<h> h<v>` with `C` for Compact and `R` for Regular, for example `wC hR`, and its resolution, `<width> × <height> pt · <width × scale> × <height × scale> px`, for example `402 × 874 pt · 1206 × 2622 px`, both in the orientation chosen.
- Checking a row shows the device's previews in the section, unchecking it removes them, at once ([previews.update](engine-api.md#previewsupdate)).
- The [custom size](#custom-size) form follows the list, after a divider.

The device button with the symbol `ipad.and.iphone`, the popover, the grouping iPhone then iPad and the content of the rows come from the user. The width, the heights, the help tag, the headings and the notations of the size classes and of the resolution are design-time choices. Default chosen at design time.

### Custom size

- The form shows `Custom Size` in the subheadline font, then the `iPhone` / `iPad` segmented control of the family, `iPhone` by default, the `Width` and `Height` fields, empty at first, the `Width Class` and `Height Class` pop-ups, `Compact` and `Regular`, by default `Compact` for the width and `Regular` for the height, and on the last line the `Add` button, enabled while both fields hold whole numbers from 50 to 2000.
- `Add` reads `devices.json` and writes it again with a new device after its devices: its name `Custom <width> × <height>`, followed by ` (2)`, ` (3)` and so on when the file already has a device of that name; the family chosen; the width and height entered; the scale 3 for an iPhone and 2 for an iPad; the size classes chosen, in portrait and in landscape. The rest of the file stays as it was, the keys HephaestusV2 does not know included. The new device is checked, and the fields empty again.
- When the file cannot be read, is not a valid devices file, or cannot be written, `Add` changes nothing and the form shows `devices.json cannot be written: <reason>` in red, before `Add`.

The custom size saved into `devices.json` as a new device of the list, with its width, its height and its size classes, comes from the user. The family control, the name, the scale, the same size classes in both orientations, the range, the defaults, the device checked and the texts are design-time choices. Default chosen at design time.

### Devices side by side

- The previews area shows, side by side, one group of previews per device that the view's previews run on: the Mac's when the view's target builds for macOS ([Platforms of a target](#platforms-of-a-target)), then, when it builds for iOS, the group of each checked device, in the order of the popover. A group starts with its heading in the subheadline font, semibold: `Mac · <width> × <height> pt` for the Mac, `<name> · <width> × <height> pt · w<h> h<v>` for a device, in the orientation chosen; its previews follow side by side, each with its title. While the Mac's group is the only one, it has no heading.
- A device preview has the device's width and height in points: landscape swaps them, for the iPad windows too, and gives the preview the device's landscape size classes.
- Before the first build of the target has read its platforms, the area shows the spinner of the first build. When the target builds for iOS only and no device is checked, the area shows `No Device Checked` and the line `Check a device with the device button to preview <name>.`

Every preview on every checked device side by side, beside the Mac previews, comes from the user. The groups per device with their headings, the order, the second line of the controls bar, the swap of the width and the height in landscape and the texts are design-time choices. Default chosen at design time.

### Device preview behaviour

- A device preview shows the view that its `#Preview` block gives, a SwiftUI view, a `UIView` or a `UIViewController`, in a window of the device's size whose traits are the device's horizontal and vertical size classes, the idiom `phone` for an iPhone and `pad` for an iPad, the device's scale, and the appearance and Dynamic Type size of the [settings](#preview-settings). The view's safe areas are empty: no status bar or home indicator takes room in it.
- The previews are live and interactive, with the input of a touch screen: a click is a tap at its place, a drag moves a touch, and the scroll wheel or the trackpad scrolls the scroll view under the pointer, the innermost first, then the ones around it, as on the Mac. The moves of the pointer and the right button do nothing.
- After a click, the keys typed go to the text input that has the focus in the view: their characters are inserted, Delete deletes backwards, Forward Delete forwards, Return inserts a line break or ends the editing of a text field, the arrow keys move the insertion point, and Copy, Cut, Paste, Select All, Undo and Redo of the Edit menu, with their shortcuts, act in it. The other keys do nothing; the software keyboard does not show in the preview.
- A sheet, an alert or a popover that the view presents shows in its preview, as on the device.

The traits, the empty safe areas, the touches, the keys and the presentations shown are design-time choices. Default chosen at design time.

### iOS Simulator

- The device previews run in the iOS Simulator of the device that holds the project, with its newest iOS Simulator runtime. Without one, the device previews fail with `No iOS Simulator runtime is installed: add one in Xcode › Settings › Components.`
- The engine keeps its own simulator devices, named `HephaestusV2 Previews <n>` from 1, in a device set of its own, `Runtime/simulators/` in its data directory ([Device data directory](architecture.md#device-data-directory)), so that they appear neither in Xcode nor in the Simulator app and leave the user's simulators alone. A device has the device type of the runtime whose screen has the most points, an iPad Pro 13-inch with the iOS 27 runtime, and runs without a window.
- A preview host for iOS runs on a simulator device of its own, since the iOS Simulator runs one app at a time in the foreground: previewing two targets at the same time uses two devices. The engine boots a device when a host needs one, creating it when no device of the set is free, which takes up to a few minutes the first time; it shuts the device down when the host stops, and every device of the set when the engine stops and when it starts, so that a device that a crash left booted does not stay so.

The runtime, the device set in the data directory, the names, the device type, the device per host, the shutdowns and the text are design-time choices. Default chosen at design time.

## Builds

The engine of the device that holds the project builds the previews, with the toolchain of its Xcode, in its data directory, `Runtime/previews/` ([Device data directory](architecture.md#device-data-directory)), one folder per package or Xcode project. The builds go there: the user's own `.build` and DerivedData folders are left alone.

### Package or Xcode project of a view

The view's file belongs to the nearest folder, from the file's folder up to the root of the project's top-level project, that holds a `Package.swift` or a folder whose name ends with `.xcodeproj`; a folder with both counts as the Swift package. A file under no such folder gives the failure `No Swift package or Xcode project holds <path>.`

### Platforms of a target

A target builds for macOS, for iOS, or for both: its previews show in the Mac's group for macOS and in the groups of the devices for iOS ([Devices side by side](#devices-side-by-side)).

- **Swift package.** The platforms that the `platforms` of its manifest lists, as `swift package describe --type json` gives them: macOS when it lists `macos`, iOS when it lists `ios`. A manifest without `platforms`, or whose `platforms` lists neither, builds for both.
- **Xcode project.** The `SUPPORTED_PLATFORMS` of the target's Debug configuration, else of the project's Debug configuration: macOS when it holds `macosx`, iOS when it holds `iphoneos` or `iphonesimulator`. Without `SUPPORTED_PLATFORMS`, the `SDKROOT` of the target, else of the project: `macosx` gives macOS, `iphoneos` gives iOS; without either, macOS, as Xcode.

The engine builds a target for a platform only when a session shows that platform: for macOS when the target builds for macOS, for the iOS Simulator when it builds for iOS and the session has a checked device.

The platforms read from the manifest and from the build settings, and the builds limited to the platforms shown, are design-time choices. Default chosen at design time.

### Swift package

1. The target of the view is the target of the package whose sources hold the file, as `swift package describe --type json` lists them. A file of no target gives the failure `No target of <package folder> builds <path>.`
2. The engine writes a build folder for the package in `Runtime/previews/`: a copy of its `Package.swift` with a preview host target added, links to the package's other entries, a copy of its `Package.resolved`, and for each target previewed a folder that copies the target's files, the code of each preview block added after its file, and the code of the preview host. The host target has the target's dependencies, resources and settings, and the name of its module, so that the code that names its own module compiles. A `@main` attribute is left out of the copy, and a `main.swift` with it.
3. `swift build --product <host target>` builds the host in that folder, with its own `.build`.
4. For the iOS Simulator, `swift build --product <host target> --triple <architecture>-apple-ios-simulator --sdk <iOS Simulator SDK>` builds the host in the same folder, `<architecture>` that of this Mac. The engine then makes the app of the host, `HephaestusPreviewApps/<target>/HephaestusPreviewHost.app` in the build folder: the executable, the resource bundles of the build and an `Info.plist` whose identifier is that of the preview host, with the iPhone and the iPad as device families.

### Xcode project

1. The target of the view is the target of the Xcode project whose sources hold the file: a source file of its Sources build phase, or a file of a folder that the target synchronizes and does not exclude. A file of no target gives the failure `No target of <project name> builds <path>.` Only an application or a framework target is previewed; another kind gives the failure `Previews need an application or framework target: <target> is <product type>.`
2. `xcodebuild` builds the scheme named like the target, or the project's first scheme when none is, for macOS on this Mac's architecture, in the Debug configuration, with a debug dylib for an application and with private imports, into a folder of `Runtime/previews/`.
3. `swiftc` compiles the preview host with the code of the target's preview blocks, which import the target's module with access to its private declarations, links it to the target's debug dylib or framework, and places it in the built application, so that the previews find the application's resources.
4. For the iOS Simulator, `xcodebuild` builds the same scheme for `generic/platform=iOS Simulator`, this Mac's architecture only, with the same settings, into another folder of the build folder, and `swiftc` compiles the host for the iOS Simulator against it. The engine copies the built application, or for a framework makes an empty one, as `HephaestusPreviewApps/<target>/HephaestusPreviewHost.app`, puts the host in it as its executable, and gives its `Info.plist` the identifier of the preview host, the iPhone and the iPad as device families and no storyboard or scene of the application.

### Build rules

- One build runs at a time for a package or an Xcode project. A change that comes during a build starts another build when it ends.
- A build that fails sets the session's state to `failed` with its errors: each `error:` line of the compiler, `<path>:<line>:<column>: error: <message>`, with the project path when the file is in the project, at most 50, in their order; a failed build without such a line gives the last 40 lines of its output. A failure before the build, such as a file of no target, gives its message.
- A build for a platform that the target's code does not build for, a package whose `platforms` lists both while its code imports UIKit for example, fails with its compiler's errors.
- A session that shows both platforms is `failed` when both builds fail: its messages are the errors of each build, after the line `macOS:` or `iOS:`. When one fails and the other's previews run, the session runs: the previews area shows the previews of the platform that built, and under them, in SF Mono, selectable, the line `macOS:` or `iOS:` of the other and its errors.
- The first build of a project builds its dependencies too and can take minutes; the builds that follow compile what changed.

The build folder in the data directory, the search up to the top-level project, the host target, the copies, the scheme, the debug dylib and the private imports, the kinds of targets, the one build at a time, the 50 errors, the 40 lines, the app of the iOS host and the messages of the two platforms are design-time choices. Default chosen at design time.

### Refresh

- When a file of the folder of a view's package or Xcode project changes on disk, outside the skipped folders of [Swift files read](#swift-files-read), whoever wrote it, HephaestusV2, Claude or another app, the engine builds its previews again, for each platform its sessions show, then restarts the preview hosts with the new builds. The previews show the new images; the state of the views, their scroll positions and the text typed in them included, starts again.
- Unsaved edits are not on disk and do not refresh the previews: the [editor](#editor) beside them refreshes them when it saves, with ⌘S, not while the user types.
- While the build runs, the previews keep showing their last images, still interactive, and the status line shows the build's progress.
- When the build fails, the previews area shows the compiler's errors in place of the previews, in SF Mono, selectable, the paths in the secondary colour; the next build that succeeds shows the previews again.

The refresh on save comes from the user. The changes that start a build and the previews kept during a build are design-time choices. Default chosen at design time.

## Preview host

- The preview host is the program that a build gives: it runs the previews of a target in windows that the user never sees, out of every display, draws each preview as a PNG image at 2 pixels per point, and gives the view the clicks, the moves, the scrolls and the keys of the window that shows it. It never takes the focus from the user's apps and has no Dock icon.
- One host runs per target previewed, for every session of that target, from every window and every device. It starts after the target's build succeeded, starts again after each build, and stops 60 seconds after its last session stopped, or when the engine stops.
- A host that stops while sessions use it, a crash of a preview for example, sets their state to `failed` with `The previews stopped: <reason>.`, `<reason>` being `exit code <n>` or `signal <n>`, followed by the last 40 lines of its standard error. The next build starts it again.
- A preview draws again when its view changes: the host sends a new image when its pixels changed, at most 20 times per second while the user acts on it and during the second after, then at most 4 times per second.
- One host runs per target and platform: the host of the Mac previews on the Mac, and the host of the device previews, an iOS app, in a simulator device ([iOS Simulator](#ios-simulator)). The engine installs the app of the iOS host in the device and launches it after each build; the host shows each preview on each device in a window of its own, out of the simulator's screen when it is larger.
- The iOS host talks with the engine through a TCP connection on `127.0.0.1`: the engine listens on a port of its choice and gives the host the port and a random token as launch arguments, and the host's first line is the token; a connection without it is closed. The host sends the lines of its standard error on the connection too, and the engine keeps the last 40.
- When the connection of an iOS host closes, a crash of a preview for example, its sessions are `stopped` with `The previews stopped: the app ended in the iOS Simulator.` followed by the last 40 lines of its standard error. The engine launches the app again when it has not connected 30 seconds after its launch; when it has not connected after 4 launches, they are `stopped` with `The previews stopped: the app did not start in the iOS Simulator.` A failure of the simulator, to boot, install or launch, stops them with `The previews stopped: <the tool's last line>.`

The windows out of every display, the 2 pixels per point, the host per target and platform, its 60 seconds, the rates, the TCP connection with its token, the 30 seconds and the 4 launches, and the texts are design-time choices. Default chosen at design time.

## Design with Claude

The user designs the views with Claude in the project chat of the inspector of the window ([Inspector](ui.md#inspector)): they say what to change, what is right and what is not, and the previews of the section show each change Claude saves ([Refresh](#refresh)).

### Linked view

- While the section of a main window shows a view, the view selected in the list, the composer of its inspector's chat, or of its draft, links that view as a linked item chip ([Linked items](chats.md#linked-items)): the chip symbol `rectangle.3.group`, the symbol of the section, the view's name as its short name, and as `<item>` `view <name> in <path>`, `<path>` being the project path of its file.
- Every message sent from that composer while the chip shows carries the view: Claude receives the line `Open in the app: view <name> in <path>` with it ([Linked items hook](chats.md#linked-items-hook)), so that it knows which view the user talks about, and the `user` item stores the item with the kind `view`. A message sent while the window shows another section, or the section without a view selected, carries no view.
- The chip follows the selection. × unlinks the view while it stays selected; selecting another view links that one, as for the other linked items ([Inspector](ui.md#inspector)).

The context Claude receives with a message sent while the section shows `CounterView`:

```text
Open in the app: view CounterView in Sources/App/Counter.swift
```

The view, its name and the path of its file carried by every message come from the user ([R215](requirements.md#requirements)). The chip, its symbol, its short name and the text of `<item>` are design-time choices. Default chosen at design time.

### Previews for Claude

- Claude sees the previews of a view with the MCP tool [get_view_previews](mcp.md#get_view_previews), which runs [previews.capture](engine-api.md#previewscapture): the engine builds the view's target when a Swift file of its package or Xcode project changed since the start of its last build, the file Claude has just saved included, and returns the path of a PNG image per preview, drawn by the preview host of that build, or the compiler's errors when the build fails.
- The images have the width, the height, the appearance and the Dynamic Type size that Claude gives, 400 by 300 points, Light and `Large` by default; the preview settings of the windows do not apply to them.
- The common skill tells Claude to call the tool after each change of a view, and to change the view again until its previews show what the user asked ([Default: common](skills.md#default-common)).
- When Claude writes the view's file, the section reads the list again and builds the previews again, as for any save, so the user sees the change in the previews shown ([Live updates](#live-updates), [Refresh](#refresh)).

The tool that gives Claude the images of the previews after the last build and the refresh on Claude's saves come from the user ([R215](requirements.md#requirements)). The build that starts when a Swift file is newer than the last build and the default settings are design-time choices. Default chosen at design time.

### Create Preview

- In the previews area of a view without `#Preview`, a `Create Preview` button shows under the line `<name> has no #Preview.`.
- `Create Preview` shows the inspector of the window when it is hidden and sends, from the composer of its chat, the message `Write a #Preview of <name> into <path>.`, `<name>` being the view's name and `<path>` the project path of its file. The message carries the linked items of that composer, the view included unless the user unlinked it, and its added resources, as Send does ([Linked items](chats.md#linked-items)); the text and the attachments in the composer stay there.
- It goes to the chat the inspector shows when it is a project chat, or to its draft, whose message creates the chat, as the first Send of a draft does ([Draft chats](chats.md#draft-chats)). When the inspector shows an Auto Setup chat, it goes to a new project chat, which the inspector then shows.
- The button is enabled while the window's device is connected and its Claude CLI is available, the conditions of Send that do not depend on the text ([Composer](chats.md#composer)). A call that fails shows the alert `Send failed` with the error.
- Claude writes a `#Preview` of the view into its file. The save reads the list again: the view has a preview block, and its previews start as for a view selected ([Showing a view](#showing-a-view)).

The button, the request in the inspector's project chat and the `#Preview` written into the view's file come from the user ([R215](requirements.md#requirements)). The text of the message, the new project chat for an Auto Setup chat and the conditions of the button are design-time choices. Default chosen at design time.

### New views

The user describes a new view in the inspector's chat. Claude writes it in a Swift file of the project, with a `#Preview` of it, and the list shows it once the file is saved ([Live updates](#live-updates)); selecting it shows its previews.

### Uncommitted changes

In a project chat, the changes Claude makes to the views, for a message that carries a view, for `Create Preview` or for a new view, stay uncommitted in the working tree: Claude commits them only when the user asks for it ([Commits](workflow.md#commits)).

## Remote windows

In a window that shows a remote device, the Views section works the same: the list is read with [views.list](engine-api.md#viewslist), and the builds and the preview hosts run on the device that holds the project, with its Xcode, the device previews in its iOS Simulator. The devices of the devices popover come from the `devices.json` of the Mac that shows the window, which sends the checked devices to the engine with the settings, and a custom size is saved into that file. The images of the previews come to the window with [previews.poll](engine-api.md#previewspoll), and the clicks, scrolls and keys go back with [previews.input](engine-api.md#previewsinput), so the previews stay live and interactive. The [editor](#editor) reads and writes the view's file through the engine of that device, which formats it on save, as the Code section's editor does ([Remote windows](code-editor.md#remote-windows)), so its saves build the previews there. The [New View sheet](#new-view-sheet) has the engine of that device write the new file there, with [files.create](engine-api.md#filescreate) and [files.write](engine-api.md#fileswrite). The preview settings, the selection, the folders collapsed and the editor belong to the window and are never synced. The inspector's chat links the view shown and `Create Preview` sends its message as in a window of This Mac; Claude runs on the device that holds the project, where `get_view_previews` builds and draws the previews ([Design with Claude](#design-with-claude)).

## Requirements covered

- R212: A Swift application has a Views section, in a Swift Application category, that lists its SwiftUI, AppKit and UIKit views by folder, sub projects included, and shows a view's `#Preview` blocks side by side, live and interactive on the Mac, at the entered size, in Light or Dark and a Dynamic Type size, built in the background and refreshed on save, with compiler errors, for packages, Xcode projects and remote windows.
- R213: A view whose target builds for iOS shows its previews live and interactive in the Views section on the iPhone and iPad devices checked in a devices popover, beside its Mac previews, with each device's size and size classes, in portrait or landscape, run in the iOS Simulator; the devices come from `devices.json` of the Mac showing the window, written with built-in models and iPad windows when missing, plus custom sizes.
- R214: In the Views section, the Swift file of the view selected opens beside its previews in the code editor of the Code section, with its editing behaviour, syntax highlighting, saving and handling of changes on disk; the previews refresh when the file is saved, not while the user types; the changes stay uncommitted in the working tree; it works the same in remote windows.
- R215: In the Views section, the user designs views with Claude in the inspector's project chat: each message carries the shown view's name and file path, an MCP tool gives Claude the preview images after the last build, the previews refresh when Claude saves, `Create Preview` asks Claude for a `#Preview`, Claude creates the new views the user describes, and the changes stay uncommitted until the user asks.
- R216: The `+` button of the Views section opens a New View sheet that writes `<name>.swift`, a SwiftUI view of that name with its `#Preview`, in a folder of the project, left uncommitted, and selects the new view with its preview, in remote windows too.
