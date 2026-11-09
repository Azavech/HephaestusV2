// OWNER: ui-tickets — the marker setup that every Markdown view shares (docs/documentation-viewer.md › Marker setup).
import AppKit
import HephaestusCore
import HephaestusText
import SwiftUI

/// The marker setup of every Markdown view of the app (docs/documentation-viewer.md › Marker
/// setup): the six marker options, the ▶ playback of sound markers and the reading of the faces
/// that font markers name in the project's font files, for a window and a project. No view builds
/// marker options of its own.
enum MarkdownMarkers {
    /// `options` with the six marker options: the SF Symbols, the colors and the fonts of this Mac,
    /// every sound marker, the shortcuts of the shortcut notation and the animation expressions
    /// (docs/chats.md › Links, images and files).
    static func options(_ options: MarkdownRenderOptions = MarkdownRenderOptions()) -> MarkdownRenderOptions {
        var options = options
        options.isSymbolAvailable = SFSymbols.isAvailable
        options.colorSwatch = ColorSwatches.swatch
        options.readsSoundMarkers = true
        options.shortcutKeys = { KeyShortcut.keyCaps(of: $0) }
        options.fontMarker = FontMarkers.marker
        options.animationCurve = AnimationExpression.markdownCurve
        return options
    }

    /// Plain text as `.text` inlines, the six kinds of markers and the ids of `projectIdentifiers`.
    static func inlines(in text: String, projectIdentifiers: Set<String> = []) -> [MarkdownInline] {
        MarkdownSymbolMarkers.inlines(in: text, isSymbolAvailable: SFSymbols.isAvailable, colorSwatch: ColorSwatches.swatch,
                                      readsSoundMarkers: true, shortcutKeys: { KeyShortcut.keyCaps(of: $0) },
                                      fontMarker: FontMarkers.marker, animationCurve: AnimationExpression.markdownCurve,
                                      projectIdentifiers: projectIdentifiers)
    }

    /// Plain text as HTML: escaped text, the HTML of the six kinds of markers and the links of the
    /// ids of `projectIdentifiers`.
    static func html(_ text: String, projectIdentifiers: Set<String> = []) -> String {
        MarkdownSymbolMarkers.html(text, isSymbolAvailable: SFSymbols.isAvailable, colorSwatch: ColorSwatches.swatch,
                                   readsSoundMarkers: true, shortcutKeys: { KeyShortcut.keyCaps(of: $0) },
                                   fontMarker: FontMarkers.marker, animationCurve: AnimationExpression.markdownCurve,
                                   projectIdentifiers: projectIdentifiers)
    }

    /// The window has no active project, so a sound marker has no project to read its sound from.
    struct NoProject: LocalizedError {
        var errorDescription: String? { "This window has no project." }
    }

    /// The ▶ of a sound marker: plays the sound of the project, read through the window's engine
    /// connection (docs/chats.md › Sound playback); a failure, or no project, shows the alert
    /// `Play Sound failed`.
    @MainActor
    static func playSound(projectID: String?, workspace: DeviceWorkspace, window: WindowState) -> @MainActor (String) -> Void {
        { [weak workspace, weak window] name in
            guard let workspace, let window else { return }
            guard let projectID else {
                window.alert = .failure("Play Sound", NoProject())
                return
            }
            Task {
                do {
                    try await SoundPlayer.play(name, projectID: projectID, workspace: workspace)
                } catch {
                    window.alert = .failure("Play Sound", error)
                }
            }
        }
    }

    /// The context of a Markdown preview that belongs to no project folder, such as a skill's body,
    /// a memory or release notes: the default options with the six marker options and the ▶
    /// playback of the project; its other links do nothing and project images show as blocked.
    @MainActor
    static func context(projectID: String?, workspace: DeviceWorkspace, window: WindowState) -> MarkdownContext {
        MarkdownContext(options: options(), playSound: playSound(projectID: projectID, workspace: workspace, window: window))
    }

    // MARK: Font faces (docs/tickets.md › Ticket detail, docs/chats.md › Font catalogue)

    /// A face that a font marker names: its family and its weight.
    struct FontFaceName: Hashable {
        var family: String
        var weight: String
    }

    /// The faces of the family fonts named by the font markers of the blocks that this Mac cannot
    /// draw yet, in order: faces to read from the project's font files.
    static func undrawnFaces(in blocks: [MarkdownBlock]) -> [FontFaceName] {
        var faces: [FontFaceName] = []
        collectFaces(in: blocks, into: &faces)
        return faces
    }

    /// The faces of the font markers of the inlines that this Mac cannot draw yet, in order.
    static func undrawnFaces(in inlines: [MarkdownInline]) -> [FontFaceName] {
        var faces: [FontFaceName] = []
        collectFaces(in: inlines, into: &faces)
        return faces
    }

    /// Reads the faces from the project's font files with `files.fonts` and `files.read` and
    /// registers them in `FontFaces` (docs/chats.md › Font catalogue); true when one was read.
    @MainActor
    static func loadFaces(_ faces: [FontFaceName], with fonts: ProjectFonts) async -> Bool {
        var loaded = false
        for face in faces {
            if await fonts.descriptor(family: face.family, weight: face.weight) != nil {
                loaded = true
            }
        }
        return loaded
    }

    private static func collectFaces(in blocks: [MarkdownBlock], into faces: inout [FontFaceName]) {
        for block in blocks {
            switch block {
            case .heading(_, _, let content), .paragraph(let content):
                collectFaces(in: content, into: &faces)
            case .blockQuote(let children):
                collectFaces(in: children, into: &faces)
            case .list(let list):
                for item in list.items {
                    collectFaces(in: item.blocks, into: &faces)
                }
            case .table(let table):
                for cell in table.header + table.rows.flatMap({ $0 }) {
                    collectFaces(in: cell, into: &faces)
                }
            case .codeBlock, .thematicBreak, .rawHTML:
                break
            }
        }
    }

    private static func collectFaces(in inlines: [MarkdownInline], into faces: inout [FontFaceName]) {
        for inline in inlines {
            switch inline {
            case .font(let marker):
                guard case .family(let family, let weight, _)? = FontNotation(marker.font),
                      FontFaces.systemDesign(family) == nil,
                      FontFaces.ctFont(family: family, weight: weight, size: 13) == nil
                else { continue }
                let face = FontFaceName(family: family, weight: weight)
                if !faces.contains(face) {
                    faces.append(face)
                }
            case .emphasis(let content), .strong(let content), .strikethrough(let content), .link(_, _, let content):
                collectFaces(in: content, into: &faces)
            default:
                break
            }
        }
    }
}

extension View {
    /// The marker setup of a Markdown preview that belongs to no project folder (a skill's body, a
    /// memory, release notes): the six marker options, the ▶ playback and the reading of the font
    /// faces of the project, `projectID` being nil when the window has no project
    /// (docs/documentation-viewer.md › Marker setup).
    func markdownMarkers(projectID: String?, workspace: DeviceWorkspace, window: WindowState) -> some View {
        markdownFontFaces(projectID: projectID, workspace: workspace)
            .environment(\.markdownContext, MarkdownMarkers.context(projectID: projectID, workspace: workspace, window: window))
    }

    /// The Markdown views inside read the faces that their font markers name in the font files of
    /// the project, with `files.fonts` and `files.read` through the window's engine connection, and
    /// draw their labels again once a face is read; without project they use only the fonts of
    /// this Mac (docs/documentation-viewer.md › Marker setup).
    func markdownFontFaces(projectID: String?, workspace: DeviceWorkspace) -> some View {
        modifier(MarkdownFontFacesSource(projectID: projectID, workspace: workspace))
    }
}

/// Gives the Markdown context the reading of the faces of a project's font files, through one
/// `ProjectFonts` per workspace and project, so that each file is read once.
private struct MarkdownFontFacesSource: ViewModifier {
    let projectID: String?
    let workspace: DeviceWorkspace
    @State private var cache = ProjectFontsCache()

    func body(content: Content) -> some View {
        let fonts = projectID.map { cache.fonts(workspace: workspace, projectID: $0) }
        content.transformEnvironment(\.markdownContext) { context in
            context.loadFontFace = fonts.map { fonts in
                { face in await MarkdownMarkers.loadFaces([face], with: fonts) }
            }
        }
    }
}

/// The `ProjectFonts` of the last workspace and project asked for.
@MainActor
private final class ProjectFontsCache {
    private var key: (ObjectIdentifier, String)?
    private var current: ProjectFonts?

    func fonts(workspace: DeviceWorkspace, projectID: String) -> ProjectFonts {
        let key = (ObjectIdentifier(workspace), projectID)
        if let current, let previous = self.key, previous == key {
            return current
        }
        let fonts = ProjectFonts(connection: workspace.connection, projectID: projectID)
        self.key = key
        current = fonts
        return fonts
    }
}
