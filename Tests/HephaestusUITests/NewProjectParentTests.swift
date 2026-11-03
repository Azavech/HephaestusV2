import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/projects.md › Creating a project, › Sub projects: the New Project sheet's `Parent project`
/// pop-up, the folder rules of a selected parent and the inside-a-project note.
@Suite("New Project parent")
struct NewProjectParentTests {
    let projects = [
        ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo", subprojectIDs: ["API"]),
        ProjectSummary(id: "API", name: "Api", rootPath: "/Users/example/Demo/api", parentID: "DEMO", subprojectIDs: ["DB"]),
        ProjectSummary(id: "DB", name: "Db", rootPath: "/Users/example/Demo/api/db", parentID: "API"),
        ProjectSummary(id: "WEB", name: "Website", rootPath: "/Users/example/Web"),
    ]

    var demo: ProjectSummary { projects[0] }

    @Test func popUpListsNoneThenEveryProjectIndentedByDepth() {
        let items = ProjectRules.parentItems(projects: projects)
        #expect(items == [
            IndentedPopUpButton.Item(tag: "", title: "None"),
            .separator(),
            IndentedPopUpButton.Item(tag: "DEMO", title: "Demo", indentation: 0),
            IndentedPopUpButton.Item(tag: "API", title: "Api", indentation: 1),
            IndentedPopUpButton.Item(tag: "DB", title: "Db", indentation: 2),
            IndentedPopUpButton.Item(tag: "WEB", title: "Website", indentation: 0),
        ])
    }

    @Test func popUpWithoutProjectsListsOnlyNone() {
        #expect(ProjectRules.parentItems(projects: []) == [IndentedPopUpButton.Item(tag: "", title: "None"), .separator()])
    }

    @Test func newFolderAcceptsTheParentRootAndFoldersInsideIt() {
        for folder in ["/Users/example/Demo", "/Users/example/Demo/", "/Users/example/Demo/tools"] {
            #expect(ProjectRules.parentFolderMessage(parent: demo, newFolder: true, parentFolder: folder, chosenFolder: "") == nil)
        }
    }

    @Test func newFolderRefusesAParentFolderOutsideTheParent() {
        for folder in ["/Users/example", "/Users/example/Web", "/Users/example/Demonstration"] {
            #expect(ProjectRules.parentFolderMessage(parent: demo, newFolder: true, parentFolder: folder, chosenFolder: "")
                == "Choose a folder inside “Demo”.")
        }
    }

    @Test func existingFolderMustBeStrictlyInsideTheParent() {
        #expect(ProjectRules.parentFolderMessage(parent: demo, newFolder: false, parentFolder: "", chosenFolder: "/Users/example/Demo/tools") == nil)
        for folder in ["/Users/example/Demo", "/Users/example/Web/site"] {
            #expect(ProjectRules.parentFolderMessage(parent: demo, newFolder: false, parentFolder: "", chosenFolder: folder)
                == "Choose a folder inside “Demo”.")
        }
    }

    @Test func emptyFolderGivesNoParentMessage() {
        #expect(ProjectRules.parentFolderMessage(parent: demo, newFolder: true, parentFolder: "", chosenFolder: "/Users/example/Web") == nil)
        #expect(ProjectRules.parentFolderMessage(parent: demo, newFolder: false, parentFolder: "/Users/example/Web", chosenFolder: "") == nil)
    }

    @Test func insideNoteNamesTheInnermostProject() {
        #expect(ProjectRules.insideNote(projectFolder: "/Users/example/Demo/api/cli", projects: projects)
            == "This folder is inside “Api”: the new project becomes its sub project.")
    }

    @Test func noInsideNoteOutsideEveryProject() {
        #expect(ProjectRules.insideNote(projectFolder: "/Users/example/Other", projects: projects) == nil)
        #expect(ProjectRules.insideNote(projectFolder: "/Users/example/Demo", projects: projects) == nil)
        #expect(ProjectRules.insideNote(projectFolder: "", projects: projects) == nil)
    }
}
