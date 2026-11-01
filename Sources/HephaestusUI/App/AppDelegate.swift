// OWNER: ui-shell — the application delegate: window tabbing, placement and activation policy,
// SIGTERM and SIGINT, quitting, startup step 9 (docs/ui.md › Windows; docs/architecture.md ›
// Window placement, › Startup, › Shutdown).
import AppKit
import Darwin
import Foundation

/// The `NSApplicationDelegate` of the app, installed with `@NSApplicationDelegateAdaptor`.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
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
