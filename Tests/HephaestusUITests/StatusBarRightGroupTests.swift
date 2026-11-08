import Testing
@testable import HephaestusUI

/// docs/ui.md › Status bar, docs/updater.md › Update item: the right group always starts with the
/// Version item, directly left of the Update item while that item shows; chat windows show only
/// the Version, Weekly usage and Ladybug items of the group.
@Suite("Status bar right group")
struct StatusBarRightGroupTests {
    static func items(mainWindow: Bool = true, update: Bool = false, weeklyUsage: Bool = false, costs: Bool = false,
                      ladybug: Bool = false) -> [StatusBarRightItem] {
        StatusBarRightItem.items(mainWindow: mainWindow, update: update, weeklyUsage: weeklyUsage, costs: costs,
                                 ladybug: ladybug)
    }

    @Test("The Version item shows first, once, whatever else shows", arguments: [true, false])
    func versionAlwaysFirst(_ mainWindow: Bool) {
        for flags in 0..<16 {
            let items = Self.items(mainWindow: mainWindow, update: flags & 1 != 0, weeklyUsage: flags & 2 != 0,
                                   costs: flags & 4 != 0, ladybug: flags & 8 != 0)
            #expect(items.first == .version, "flags \(flags)")
            #expect(items.filter { $0 == .version }.count == 1, "flags \(flags)")
        }
    }

    @Test("In a main window the Update item follows the Version item, before Weekly usage, Costs and the ladybug")
    func mainWindowOrder() {
        #expect(Self.items(update: true, weeklyUsage: true, costs: true, ladybug: true)
            == [.version, .update, .weeklyUsage, .costs, .ladybug])
        #expect(Self.items(update: true) == [.version, .update])
        #expect(Self.items(weeklyUsage: true, costs: true, ladybug: true) == [.version, .weeklyUsage, .costs, .ladybug])
        #expect(Self.items(ladybug: true) == [.version, .ladybug])
        #expect(Self.items() == [.version])
    }

    @Test("A chat window shows only the Version, Weekly usage and Ladybug items")
    func chatWindow() {
        #expect(Self.items(mainWindow: false, update: true, weeklyUsage: true, costs: true, ladybug: true)
            == [.version, .weeklyUsage, .ladybug])
        #expect(Self.items(mainWindow: false, update: true, costs: true) == [.version])
    }
}
