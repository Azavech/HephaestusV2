// OWNER: ui-shell — the console drawer of the active project's runs (docs/projects.md › Console; docs/ui.md › Console drawer).
import AppKit
import HephaestusCore
import SwiftUI

extension WindowState {
    /// The run the console drawer shows: the selected run (`consoleRunID`) while the workspace
    /// knows it, otherwise the newest run of the active project (docs/projects.md › Console,
    /// Selection).
    var consoleRun: RunState? {
        guard let projectID, let workspace else { return nil }
        let runs = workspace.runs(of: projectID)
        if let selected = viewState.consoleRunID, let run = runs.first(where: { $0.id == selected }) {
            return run
        }
        return runs.first
    }
}

/// Run picker, starter, status, Stop, Clear, Hide and the output of the selected run (`ProjectViewState.consoleRunID`).
struct ConsoleDrawer: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Environment(AppModel.self) private var app

    var body: some View {
        let runs = workspace.runs(of: projectID)
        let run = window.consoleRun
        VStack(spacing: 0) {
            Divider()
            header(runs: runs, run: run)
                .padding(.horizontal, 8)
                .frame(height: 30)
            Divider()
            if let run {
                ConsoleOutputView(runID: run.id, console: run.console)
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: selectShownRun)
        .onChange(of: run?.id) {
            selectShownRun()
        }
    }

    /// A run started elsewhere is selected only when the console shows no run: the shown run
    /// becomes the selection when there is none, so a newer run started elsewhere does not
    /// replace it.
    private func selectShownRun() {
        guard window.projectID == projectID, window.viewState.consoleRunID == nil, let run = window.consoleRun else { return }
        window.updateViewState(of: projectID) { $0.consoleRunID = run.id }
    }

    // MARK: Header

    @ViewBuilder
    private func header(runs: [RunState], run: RunState?) -> some View {
        HStack(spacing: 8) {
            if let run {
                Picker("Run", selection: selection(run)) {
                    ForEach(runs) { item in
                        Text(Self.pickerTitle(item)).tag(item.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if let starter = starterText(run) {
                    Text(starter)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                status(run)
                Button {
                    stop(run)
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop")
                .disabled(!run.isRunning)
                Button {
                    workspace.runs[run.id]?.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear Console (⌘K)")
            } else {
                Spacer()
            }
            Button {
                window.consoleVisible = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Hide Console (⇧⌘Y)")
        }
        .font(.system(size: 11))
    }

    private func selection(_ run: RunState) -> Binding<String> {
        Binding(get: { run.id }, set: { id in
            window.updateViewState(of: projectID) { $0.consoleRunID = id }
        })
    }

    /// `<Kind> · <command> · <start time>` followed by its state.
    static func pickerTitle(_ run: RunState) -> String {
        let state: String
        if run.endMissed {
            state = "Ended while disconnected"
        } else if let exitCode = run.exitCode {
            state = "Exit \(exitCode)"
        } else {
            state = "Running"
        }
        return "\(run.info.kind.title) · \(run.info.command) · \(RunState.timeFormatter.string(from: run.info.started)) · \(state)"
    }

    /// The starter text of docs/projects.md › Console.
    private func starterText(_ run: RunState) -> String? {
        switch run.starter {
        case nil:
            return nil
        case .user(let deviceID)?:
            return deviceID.uppercased() == app.localDeviceID ? "Started on this Mac" : "Started on another device"
        case .claude(let chatID)?:
            if let id = UUID(uuidString: chatID)?.uuidString, let chat = workspace.chats[id] {
                return "Started by Claude · \(chat.title)"
            }
            return "Started by Claude"
        case .system?:
            return "Started by HephaestusV2"
        }
    }

    @ViewBuilder
    private func status(_ run: RunState) -> some View {
        if run.endMissed {
            Text("Ended while disconnected")
                .foregroundStyle(.gray)
        } else if let exitCode = run.exitCode {
            Text("Exited with code \(exitCode)")
                .foregroundStyle(exitCode == 0 ? Color.green : Color.red)
        } else {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Running…")
            }
        }
    }

    private func stop(_ run: RunState) {
        Task {
            do {
                _ = try await workspace.call(ProjectsStopRun.self, ProjectsStopRun.Params(runID: run.info.runID))
            } catch {
                window.alert = .failure("Stop", error)
            }
        }
    }

    // MARK: Empty state

    /// No run known: the commands hint, or the Project Settings… button when the project has no
    /// command.
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if hasNoCommand {
                Text("Set the project's commands in Project Settings.")
                    .foregroundStyle(.secondary)
                Button("Project Settings…") {
                    window.section = .settings
                }
            } else {
                Text("No runs yet. Use Run (⌘R), Build (⌘B) or Test (⌘U).")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasNoCommand: Bool {
        guard let commands = workspace.details[projectID]?.project.commands else { return false }
        return [commands.build, commands.run, commands.test].allSatisfy { ModelRules.normalizedCommand($0) == nil }
    }
}

/// The output of a run: read-only, selectable text in SF Mono 12 with wrapped lines. New output
/// keeps the view at the end while it is scrolled to the end; otherwise the view stays where it
/// is. The text view follows the buffer incrementally: it appends new lines and removes dropped
/// ones, and rebuilds only after a clear or for another run.
struct ConsoleOutputView: NSViewRepresentable {
    let runID: String
    let console: ConsoleBuffer

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.usesFindBar = false
            textView.font = Coordinator.font
            textView.textColor = .textColor
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 4, height: 4)
            textView.textContainer?.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.setAccessibilityLabel("Console output")
            // TextKit 1 with non-contiguous layout: exact document heights for following the end,
            // and layout of only what is shown for long outputs.
            textView.layoutManager?.allowsNonContiguousLayout = true
        }
        context.coordinator.observeScrolling(of: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.update(textView, in: scrollView, runID: runID, console: console)
    }

    @MainActor
    final class Coordinator: NSObject {
        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private static let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        private static let droppedLineLength = (ConsoleBuffer.droppedLine + "\n").utf16.count

        private var runID: String?
        private var clearCount = 0
        private var firstLineNumber = 0
        private var lineCount = 0
        private var partialLength = 0
        private var dropped = false
        /// True while new output keeps the view at the end: the user has not scrolled away from it.
        private var following = true

        /// A scroll by the user decides whether new output follows: it does while the view shows
        /// the end of the text.
        func observeScrolling(of scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(self, selector: #selector(userScrolled(_:)),
                                                   name: NSScrollView.didLiveScrollNotification, object: scrollView)
            NotificationCenter.default.addObserver(self, selector: #selector(userScrolled(_:)),
                                                   name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        }

        @objc private func userScrolled(_ notification: Notification) {
            guard let scrollView = notification.object as? NSScrollView else { return }
            following = Self.isScrolledToEnd(scrollView)
        }

        func update(_ textView: NSTextView, in scrollView: NSScrollView, runID: String, console: ConsoleBuffer) {
            guard let storage = textView.textStorage else { return }
            let unchanged = runID == self.runID && console.clearCount == clearCount && console.lineCount == lineCount
                && console.firstLineNumber == firstLineNumber && console.partial.utf16.count == partialLength
                && console.dropped == dropped
            guard !unchanged else { return }
            let rebuild = runID != self.runID || console.clearCount != clearCount || console.firstLineNumber >= lineCount
                && console.firstLineNumber > firstLineNumber
            storage.beginEditing()
            if rebuild {
                storage.setAttributedString(NSAttributedString(string: console.text, attributes: Self.attributes))
            } else {
                let text = storage.mutableString
                if partialLength > 0 {
                    storage.deleteCharacters(in: NSRange(location: text.length - partialLength, length: partialLength))
                }
                let droppedCount = console.firstLineNumber - firstLineNumber
                if droppedCount > 0 {
                    let start = dropped ? Self.droppedLineLength : 0
                    var end = start
                    for _ in 0..<droppedCount {
                        let found = text.range(of: "\n", range: NSRange(location: end, length: text.length - end))
                        guard found.location != NSNotFound else { break }
                        end = found.location + 1
                    }
                    storage.deleteCharacters(in: NSRange(location: start, length: end - start))
                }
                if console.dropped && !dropped {
                    storage.insert(NSAttributedString(string: ConsoleBuffer.droppedLine + "\n", attributes: Self.attributes), at: 0)
                }
                var appended = ""
                for line in console.lines(from: max(lineCount, console.firstLineNumber)) {
                    appended += line
                    appended += "\n"
                }
                appended += console.partial
                storage.append(NSAttributedString(string: appended, attributes: Self.attributes))
            }
            storage.endEditing()
            self.runID = runID
            clearCount = console.clearCount
            firstLineNumber = console.firstLineNumber
            lineCount = console.lineCount
            partialLength = console.partial.utf16.count
            dropped = console.dropped
            if rebuild {
                following = true
            }
            if following {
                scrollToEnd(textView)
            }
        }

        /// Shows the end of the text. The end is laid out first, and the scroll is repeated once
        /// the layout has settled, so that the document has its final height.
        private func scrollToEnd(_ textView: NSTextView) {
            textView.scrollRangeToVisible(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
            textView.scrollToEndOfDocument(nil)
            DispatchQueue.main.async { [weak self, weak textView] in
                MainActor.assumeIsolated {
                    guard let self, self.following, let textView else { return }
                    textView.scrollToEndOfDocument(nil)
                }
            }
        }

        /// True while the view shows the end of the text.
        private static func isScrolledToEnd(_ scrollView: NSScrollView) -> Bool {
            guard let document = scrollView.documentView else { return true }
            let visible = scrollView.contentView.documentVisibleRect
            return visible.maxY >= document.bounds.maxY - 20
        }
    }
}
