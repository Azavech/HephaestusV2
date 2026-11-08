import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/memories.md › List and › Saving: the groups of the list, the filter and the field
/// validation messages.
@MainActor
@Suite("Memories section")
struct MemoriesSectionTests {
    @Test("Memories are grouped under User, Feedback, Project, Reference and Other, sorted by name; empty groups are hidden")
    func groups() {
        let memories = [
            MemorySummary(file: "b.md", name: "beta", description: "", type: "project"),
            MemorySummary(file: "z.md", name: "alpha", description: "", type: nil),
            MemorySummary(file: "c.md", name: "gamma", description: "", type: "Project"),
            MemorySummary(file: "a.md", name: "alpha", description: "", type: "project"),
            MemorySummary(file: "u.md", name: "you", description: "", type: "user"),
            MemorySummary(file: "y.md", name: "alpha", description: "", type: nil),
        ]
        let groups = MemoryGroups.groups(of: memories)
        #expect(groups.map(\.title) == ["User", "Project", "Other"])
        #expect(groups[1].memories.map(\.file) == ["a.md", "b.md"])
        #expect(groups[2].memories.map(\.file) == ["y.md", "z.md", "c.md"])
    }

    @Test("The filter matches the name and the description without case")
    func filter() {
        #expect(MemoryGroups.matches(name: "user-role", description: "Backend developer", filter: ""))
        #expect(MemoryGroups.matches(name: "user-role", description: "Backend developer", filter: "ROLE"))
        #expect(MemoryGroups.matches(name: "user-role", description: "Backend developer", filter: "backend"))
        #expect(!MemoryGroups.matches(name: "user-role", description: "Backend developer", filter: "swift"))
        #expect(MemoryGroups.matches(name: "MEMORY.md", description: "", filter: "memory"))
    }

    @Test("Names follow the skill name rules and must not be taken by another memory's name or file")
    func validation() {
        let folder = MemoryFolder(projectID: "MEM", path: "/tmp/memory", hasIndex: true, memories: [
            MemorySummary(file: "user_role.md", name: "user-role", description: "", type: "user"),
            MemorySummary(file: "Style.md", name: "answer-style", description: "", type: "feedback"),
        ])
        #expect(MemoryValidation.nameMessage("User Role", folder: folder) == "Use 1–64 lowercase letters, digits and single hyphens.")
        #expect(MemoryValidation.nameMessage("user-role", folder: folder) == "A memory named “user-role” already exists.")
        #expect(MemoryValidation.nameMessage("style", folder: folder) == "A memory named “style” already exists.")
        #expect(MemoryValidation.nameMessage("user-role", folder: folder, except: "user_role.md") == nil)
        #expect(MemoryValidation.nameMessage("new-one", folder: folder) == nil)
        #expect(MemoryValidation.descriptionMessage("") == "A description is required.")
        #expect(MemoryValidation.descriptionMessage("x") == nil)
    }

    @Test("The form checks a field only when it differs from the saved value and keeps an Other type until one is chosen")
    func form() {
        let form = MemoryForm()
        form.reset(to: Memory(file: "Old Name.md", name: "Old Name", description: "", type: "notes", body: "Body"))
        #expect(form.type == nil)
        #expect(!form.hasUnsavedChanges)
        #expect(form.isValid(folder: nil, file: "Old Name.md"))
        form.body.text = "Changed"
        #expect(form.hasUnsavedChanges)
        #expect(form.isValid(folder: nil, file: "Old Name.md"))
        form.description = "x"
        form.description = ""
        form.name = "Bad Name"
        #expect(form.nameMessage(folder: nil, file: "Old Name.md") == "Use 1–64 lowercase letters, digits and single hyphens.")
        form.type = .reference
        form.discardChanges()
        #expect(form.type == nil)
        #expect(!form.hasUnsavedChanges)
    }

    @Test("After a save, the fields not edited meanwhile show the saved file's values")
    func formAfterSave() {
        let form = MemoryForm()
        form.reset(to: Memory(file: "m.md", name: "m", description: "D1", type: "user", body: "B1"))
        form.body.text = "B2"
        let sent = form.values
        // Saved elsewhere meanwhile: the description; the response carries it with the new body.
        form.adoptSaved(Memory(file: "m.md", name: "m", description: "D2", type: "user", body: "B2"), keepingEditsSince: sent)
        #expect(form.description == "D2")
        #expect(form.body.text == "B2")
        #expect(!form.hasUnsavedChanges)
    }

    @Test("Paths are written with ~: This Mac's home folder locally, a folder under /Users/<name> in a remote window")
    func displayPaths() {
        let path = "/Users/example/.claude/projects/-Users-example-Notes/memory"
        #expect(MemoryActions.displayPath(path, isLocal: true, home: "/Users/example") == "~/.claude/projects/-Users-example-Notes/memory")
        #expect(MemoryActions.displayPath(path, isLocal: true, home: "/Users/Shared") == path)
        #expect(MemoryActions.displayPath(path, isLocal: false, home: "/Users/Shared") == "~/.claude/projects/-Users-example-Notes/memory")
        #expect(MemoryActions.displayPath("/Volumes/Data/memory", isLocal: false, home: "/Users/Shared") == "/Volumes/Data/memory")
    }
}
