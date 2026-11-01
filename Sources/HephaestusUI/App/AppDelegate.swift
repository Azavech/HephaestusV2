// OWNER: ui-shell — the application delegate: window tabbing, placement and activation policy,
// SIGTERM and SIGINT, quitting, startup step 9 (docs/ui.md › Windows; docs/architecture.md ›
// Window placement, › Startup, › Shutdown).
import AppKit
import Darwin
import Foundation

/// The `NSApplicationDelegate` of the app, installed with `@NSApplicationDelegateAdaptor`.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var signalSources: [DispatchSourceSignal] = []

    private var app: AppModel? { AppModel.shared }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Windows never merge into native tabs, and View ▸ Show Tab Bar does not exist.
        NSWindow.allowsAutomaticWindowTabbing = false
        WindowPlacement.resolveIfNeeded()
        if WindowPlacement.isOffscreen {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if WindowPlacement.isOffscreen {
            // No Dock icon and no menu bar (docs/architecture.md › Window placement, rule 2).
            NSApp.setActivationPolicy(.accessory)
        }
        installSignalHandlers()
        MenuValidation.shared.start()
        // Startup step 9: the Updater, unless a condition of docs/updater.md › Starting the
        // Updater holds.
        app?.updateController.start()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        app?.shouldTerminate() ?? .terminateNow
    }

    /// Closing the last window does not quit the app.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Edit ▸ Find (docs/ui.md › Menus and keyboard shortcuts, note 1)

    /// The Find items forwarded to a view that implements only `performTextFinderAction:` (the
    /// Docs preview and chat transcripts): Find…, Find Next and Find Previous.
    private static let forwardedFindActions: Set<Int> = [
        NSTextFinder.Action.showFindInterface.rawValue,
        NSTextFinder.Action.nextMatch.rawValue,
        NSTextFinder.Action.previousMatch.rawValue,
    ]

    /// The standard Find items send `performFindPanelAction:`, which text views and web tabs
    /// implement; it reaches the delegate, the end of the responder chain, when the focused view
    /// implements only `performTextFinderAction:`, and is sent on to that view.
    @objc func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        guard let (target, item) = Self.textFinderTarget(tag: tag) else {
            NSSound.beep()
            return
        }
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: target, from: item)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performFindPanelAction(_:)) {
            return Self.textFinderTarget(tag: menuItem.tag) != nil
        }
        return true
    }

    /// The responder that performs `performTextFinderAction:` with this tag and validates it.
    private static func textFinderTarget(tag: Int) -> (AnyObject, NSMenuItem)? {
        guard forwardedFindActions.contains(tag) else { return nil }
        let item = NSMenuItem()
        item.action = #selector(NSResponder.performTextFinderAction(_:))
        item.tag = tag
        guard let target = NSApp.target(forAction: #selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item) as AnyObject?,
              !(target is NSApplication), !(target is AppDelegate)
        else { return nil }
        if let validator = target as? NSUserInterfaceValidations, !validator.validateUserInterfaceItem(item) {
            return nil
        }
        return (target, item)
    }

    /// SIGTERM and SIGINT are handled like Quit without its confirmation alerts.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    AppModel.shared?.terminateWithoutConfirmation()
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
