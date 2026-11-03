import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/projects.md › Creating a project, › Sub projects: the New Project sheet's `Parent project`
/// pop-up, the parent that follows the project folder until the user picks one, the folder rules of
/// a selected parent and the inside-a-project note.
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

    // MARK: Following the project folder

    func folderParent(newFolder: Bool, parentFolder: String = "", chosenFolder: String = "") -> String? {
        ProjectRules.folderParent(newFolder: newFolder, parentFolder: parentFolder, chosenFolder: chosenFolder, projects: projects)?.id
    }

    @Test func existingFolderSelectsTheInnermostProjectAtAnyDepth() {
        #expect(folderParent(newFolder: false, chosenFolder: "/Users/example/Demo/tools") == "DEMO")
        #expect(folderParent(newFolder: false, chosenFolder: "/Users/example/Demo/api/cli") == "API")
        #expect(folderParent(newFolder: false, chosenFolder: "/Users/example/Demo/api/db/migrations/v1") == "DB")
        #expect(folderParent(newFolder: false, chosenFolder: "/Users/example/Web/site/") == "WEB")
    }

    @Test func existingFolderOutsideEveryProjectSelectsNone() {
        for folder in ["", "/Users/example", "/Users/example/Other", "/Users/example/Demonstration", "/Users/example/Demo"] {
            #expect(folderParent(newFolder: false, chosenFolder: folder) == nil)
        }
        // A project's own root lies strictly inside its parent only.
        #expect(folderParent(newFolder: false, chosenFolder: "/Users/example/Demo/api") == "DEMO")
    }

    @Test func newFolderSelectsTheProjectOfTheParentFolder() {
        #expect(folderParent(newFolder: true, parentFolder: "/Users/example/Demo") == "DEMO")
        #expect(folderParent(newFolder: true, parentFolder: "/Users/example/Demo/") == "DEMO")
        #expect(folderParent(newFolder: true, parentFolder: "/Users/example/Demo/tools") == "DEMO")
        #expect(folderParent(newFolder: true, parentFolder: "/Users/example/Demo/api") == "API")
        #expect(folderParent(newFolder: true, parentFolder: "/Users/example/Demo/api/db/sql") == "DB")
    }

    @Test func newFolderOutsideEveryProjectSelectsNone() {
        for folder in ["", "/Users/example", "/Users/example/Demonstration"] {
            #expect(folderParent(newFolder: true, parentFolder: folder) == nil)
        }
    }

    @Test func eachModeReadsItsOwnFolder() {
        #expect(folderParent(newFolder: true, parentFolder: "/Users/example", chosenFolder: "/Users/example/Demo/tools") == nil)
        #expect(folderParent(newFolder: false, parentFolder: "/Users/example/Demo", chosenFolder: "/Users/example/Other") == nil)
    }

    @Test func newProjectParentFollowsTheFolderBackToNone() {
        let choice = ParentProjectChoice()
        #expect(!choice.picked)
        #expect(choice.parentID(following: nil) == nil)
        #expect(choice.parentID(following: projects[1]) == "API")
        #expect(choice.parentID(following: projects[2]) == "DB")
        #expect(choice.parentID(following: nil) == nil)
    }

    @Test func aPickedParentStaysWhateverTheFolder() {
        for picked in [nil, "DEMO", "API", "WEB"] as [String?] {
            var choice = ParentProjectChoice()
            choice.pick(picked)
            #expect(choice.picked)
            for folderParent in [nil, projects[0], projects[2], projects[3]] as [ProjectSummary?] {
                #expect(choice.parentID(following: folderParent) == picked)
            }
        }
    }

    @Test func subProjectParentNeverFollowsTheFolder() {
        let choice = ParentProjectChoice(preselected: "DEMO")
        #expect(choice.picked)
        for folderParent in [nil, projects[1], projects[2], projects[3]] as [ProjectSummary?] {
            #expect(choice.parentID(following: folderParent) == "DEMO")
        }
    }
}
