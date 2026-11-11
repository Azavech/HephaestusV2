import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/views.md › Folder tree and › Live updates.
@Suite("Views list tree")
struct ViewTreeTests {
    static let views = [
        ProjectView(name: "ZetaView", path: "Sources/App/Zeta.swift", line: 3, kind: .swiftUI),
        ProjectView(name: "AlphaView", path: "Sources/App/Alpha.swift", line: 5, kind: .swiftUI),
        ProjectView(name: "Row", path: "Sources/App/Rows/B.swift", line: 9, kind: .swiftUI),
        ProjectView(name: "Row", path: "Sources/App/Rows/A.swift", line: 2, kind: .swiftUI),
        ProjectView(name: "Canvas", path: "Sources/Kit/Canvas.swift", line: 1, kind: .appKit),
        ProjectView(name: "Top", path: "Top.swift", line: 1, kind: .uiKit),
        ProjectView(name: "Sub10", path: "Packages/Folder10/S.swift", line: 1, kind: .swiftUI),
        ProjectView(name: "Sub2", path: "Packages/Folder2/S.swift", line: 1, kind: .swiftUI),
    ]

    @Test("Folders first, then views, each in Finder order; views of the same name by file name; each view under the folder of its file")
    func tree() {
        let rows = ViewTree.rows(ViewTree.build(Self.views), collapsed: [])
        let described = rows.map { row -> String in
            let indent = String(repeating: "  ", count: row.depth)
            switch row.node.kind {
            case .folder(_, let name): return indent + name + "/"
            case .view(let view): return indent + view.name + " " + view.path
            }
        }
        #expect(described == [
            "Packages/",
            "  Folder2/",
            "    Sub2 Packages/Folder2/S.swift",
            "  Folder10/",
            "    Sub10 Packages/Folder10/S.swift",
            "Sources/",
            "  App/",
            "    Rows/",
            "      Row Sources/App/Rows/A.swift",
            "      Row Sources/App/Rows/B.swift",
            "    AlphaView Sources/App/Alpha.swift",
            "    ZetaView Sources/App/Zeta.swift",
            "  Kit/",
            "    Canvas Sources/Kit/Canvas.swift",
            "Top Top.swift",
        ])
    }

    @Test("A collapsed folder hides what it holds")
    func collapsed() {
        let rows = ViewTree.rows(ViewTree.build(Self.views), collapsed: ["Sources/App", "Packages"])
        let ids = rows.map(\.id)
        #expect(ids.contains("folder:Sources/App"))
        #expect(!ids.contains("folder:Sources/App/Rows"))
        #expect(!ids.contains("folder:Packages/Folder2"))
        #expect(ids.contains("folder:Sources/Kit"))
    }

    @Test("The list reads again for Swift files, folders and the whole project, never for skipped folders or other files")
    func reloadRule() {
        #expect(ViewTree.shouldReload(changed: ["Sources/App/Alpha.swift"]))
        #expect(ViewTree.shouldReload(changed: ["Sources/App"]))
        #expect(ViewTree.shouldReload(changed: [""]))
        #expect(!ViewTree.shouldReload(changed: ["README.md", "docs/views.md"]))
        #expect(!ViewTree.shouldReload(changed: [".build/debug/X.swift", ".hephaestus/tickets", "build/x"]))
    }
}
