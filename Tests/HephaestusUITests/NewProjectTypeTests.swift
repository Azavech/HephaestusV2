import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/projects.md › Creating a project: Project type follows the project folder until the user
/// picks a type.
@Suite("New Project type")
struct NewProjectTypeTests {
    @Test func startsAtNone() {
        let choice = ProjectTypeChoice()
        #expect(choice.type == .none)
        #expect(!choice.picked)
    }

    @Test func followsTheFolderUntilPicked() {
        var choice = ProjectTypeChoice()
        choice.follow(folderHasGoMod: true)
        #expect(choice.type == .goService)
        choice.follow(folderHasGoMod: false)
        #expect(choice.type == .none)
        choice.follow(folderHasGoMod: true)
        #expect(choice.type == .goService)
    }

    @Test func aPickedTypeStaysWhateverTheFolder() {
        for picked in ProjectType.allCases {
            var choice = ProjectTypeChoice()
            choice.follow(folderHasGoMod: true)
            choice.pick(picked)
            #expect(choice.picked)
            for hasGoMod in [false, true, false] {
                choice.follow(folderHasGoMod: hasGoMod)
                #expect(choice.type == picked)
            }
        }
    }
}
