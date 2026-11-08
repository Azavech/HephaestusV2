// OWNER: ui-chats — the composer (docs/chats.md › Composer, › Context indicator, › Skill
// completion).
import HephaestusCore
import SwiftUI

/// The composer of a chat, or of a draft chat; unsent text of an existing chat lives in
/// `DeviceWorkspace.drafts`, that of a draft in its view.
///
/// ```
/// [☑ DEMO-12 ×] [image.png ×] [build.log ×]  linked and attachment chips
/// Message Claude…                                 text, 1–10 lines
/// (paperclip)  Opus 5.5 ▾   Effort: High ▾   Context: Auto ▾   Ask Every Time ▾   ◔ 98% left   ■  ↑
/// ```
struct ComposerView: View {
    @Bindable var model: ChatViewModel
    @State private var skillList = SkillCompletionList()

    var body: some View {
        let workspace = model.workspace
        VStack(alignment: .leading, spacing: 6) {
            ClaudeStatusBanner(workspace: workspace)
            VStack(alignment: .leading, spacing: 6) {
                let attachments = model.composer.attachments
                let linkedItems = model.linkedItems
                if !attachments.isEmpty || !linkedItems.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(linkedItems) { item in
                                ComposerLinkedItemChip(item: item) {
                                    model.unlink(item)
                                }
                            }
                            ForEach(Array(attachments.enumerated()), id: \.offset) { index, upload in
                                ComposerAttachmentChip(upload: upload) {
                                    model.removeAttachment(at: index)
                                }
                            }
                        }
                    }
                }
                ChatTextEditor(
                    text: Binding(get: { model.composer.text }, set: { model.composer.text = $0 }),
                    placeholder: workspace.isConnected ? "Message Claude…" : "Not connected to \(workspace.deviceName)",
                    isEditable: workspace.isConnected,
                    minLines: 1,
                    maxLines: 10,
                    isComposer: true,
                    focusRequest: model.composerFocusRequest,
                    onSend: { model.send() },
                    onEscape: { model.stop() },
                    onPasteFiles: { model.addFiles($0) },
                    onPasteImage: { model.addPastedImage($0) },
                    skillList: skillList,
                    skills: model.completionSkills
                )
                // The skill list, just above the text field at its left edge.
                .overlay(alignment: .topLeading) {
                    if skillList.isShown {
                        ComposerSkillList(list: skillList)
                            .offset(y: -(ComposerSkillList.height(rows: skillList.rows.count) + 4))
                    }
                }
                .zIndex(1)
                controls
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            // The border is drawn under the content, so that the skill list covers it.
            .background {
                RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor))
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25))
            }
            .disabled(!workspace.isConnected)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    /// The controls row stays on one line: when the Model, Effort, Context and Permissions menus do
    /// not fit, one `slider.horizontal.3` menu replaces them, followed by the red `Allow All` capsule
    /// while that mode is selected, and the context indicator keeps only its ring.
    private var controls: some View {
        let menus = ChatSettingsMenus(settings: model.settings, models: model.workspace.models) { model.changeSettings($0) }
        return ViewThatFits(in: .horizontal) {
            controlsRow(indicatorShowsText: true) {
                ChatModelMenuButton(menus: menus)
                ChatEffortMenuButton(menus: menus)
                ChatContextMenuButton(menus: menus)
                ChatPermissionsMenuButton(menus: menus)
            }
            controlsRow(indicatorShowsText: false) {
                ChatCombinedSettingsMenuButton(menus: menus)
                if menus.settings.permissionMode == .bypassPermissions {
                    ChatPermissionsMenuButton(menus: menus)
                }
            }
        }
    }

    private func controlsRow<Menus: View>(indicatorShowsText: Bool, @ViewBuilder menus: () -> Menus) -> some View {
        HStack(spacing: 8) {
            Button {
                model.chooseFiles()
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Attach")
            menus()
            Spacer(minLength: 8)
            if let usage = model.meta?.contextUsage {
                ComposerContextIndicator(usage: usage, compactions: model.transcriptState?.compactionCount ?? 0,
                                         compacting: model.meta?.compactingSince != nil, showsText: indicatorShowsText)
            }
            if model.state.isChatRunning, model.chatID != nil {
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop")
            }
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.borderless)
            .disabled(!model.canSend)
            .accessibilityLabel("Send")
        }
        .font(.callout)
    }
}

/// What the context indicator shows for a context usage (docs/chats.md › Context indicator).
struct ContextIndicatorPresentation: Equatable {
    enum Level: Equatable {
        /// `<n>` 20 or more: green.
        case normal
        /// `<n>` under 20: orange.
        case warning
        /// `<n>` under 10: red.
        case critical
    }

    /// `<n>`: the percentage left before compaction.
    let percentLeft: Int
    /// The used part of `window` − `buffer`, to which the ring is filled.
    let fraction: Double
    let level: Level
    /// `<used> of <window> tokens used · <left> left before compaction`, followed after the chat's
    /// first compaction by the line of `compactionsLine`.
    let tooltip: String

    /// nil, and no indicator, when `bufferTokens` is not below `windowTokens`. `compactions` is the
    /// number of compaction lines in the chat's transcript.
    init?(usage: ContextUsage, compactions: Int = 0) {
        guard let percentLeft = usage.percentLeft, let fraction = usage.usedFraction else { return nil }
        self.percentLeft = percentLeft
        self.fraction = min(max(fraction, 0), 1)
        level = Self.level(percentLeft: percentLeft)
        tooltip = [usage.tooltip, Self.compactionsLine(compactions)].compactMap { $0 }.joined(separator: "\n")
    }

    /// `Compacted once`, `Compacted <n> times`; nil before the first compaction.
    static func compactionsLine(_ compactions: Int) -> String? {
        switch compactions {
        case ..<1: return nil
        case 1: return "Compacted once"
        default: return "Compacted \(compactions) times"
        }
    }

    /// The ring's opacity `elapsed` seconds into a compaction: from 1 down to 0.3 and back, 1 s per
    /// cycle.
    static func compactingOpacity(elapsed: TimeInterval) -> Double {
        let low = 0.3
        return low + (1 - low) * (1 + cos(2 * Double.pi * elapsed)) / 2
    }

    /// `<n>% left`.
    var text: String { "\(percentLeft)% left" }

    static func level(percentLeft: Int) -> Level {
        if percentLeft < 10 { return .critical }
        if percentLeft < 20 { return .warning }
        return .normal
    }

    var color: Color {
        switch level {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// The context indicator of the controls row: the ring followed by `<n>% left`, which the folded
/// row hides; the tooltip, also the accessibility label, gives the numbers and the number of
/// compactions. The ring fades while a compaction runs.
struct ComposerContextIndicator: View {
    let usage: ContextUsage
    let compactions: Int
    let compacting: Bool
    let showsText: Bool

    var body: some View {
        if let presentation = ContextIndicatorPresentation(usage: usage, compactions: compactions) {
            HStack(spacing: 5) {
                ring(presentation)
                if showsText {
                    Text(presentation.text)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .help(presentation.tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.tooltip)
            .preference(key: ContextIndicatorTextShown.self, value: showsText)
        }
    }

    @ViewBuilder private func ring(_ presentation: ContextIndicatorPresentation) -> some View {
        let ring = UsageRing(fraction: presentation.fraction, color: presentation.color)
        if compacting {
            CompactingRing(ring: ring)
        } else {
            ring
        }
    }
}

/// The ring during a compaction: its opacity follows `compactingOpacity` from the moment the view
/// appears.
private struct CompactingRing: View {
    let ring: UsageRing
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            ring.opacity(ContextIndicatorPresentation.compactingOpacity(elapsed: context.date.timeIntervalSince(start)))
        }
    }
}

/// Whether the context indicator of the shown controls row has its `<n>% left`: false once the
/// row folds its menus; nil without an indicator.
struct ContextIndicatorTextShown: PreferenceKey {
    static let defaultValue: Bool? = nil

    static func reduce(value: inout Bool?, nextValue: () -> Bool?) {
        value = nextValue() ?? value
    }
}

/// The skill list of the composer (docs/chats.md › Skill completion): one row per matching skill,
/// its name then its description on one line, the selected row in the accent color; at most
/// `visibleRows` rows, then it scrolls.
struct ComposerSkillList: View {
    let list: SkillCompletionList
    static let rowHeight: CGFloat = 22
    static let visibleRows = 8
    static let maxWidth: CGFloat = 420
    static let padding: CGFloat = 4

    /// The height of the list showing `rows` rows.
    static func height(rows: Int) -> CGFloat {
        CGFloat(min(rows, visibleRows)) * rowHeight + 2 * padding
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(list.rows.enumerated()), id: \.element.name) { index, skill in
                        row(skill, selected: index == list.selection) { list.choose(index) }
                    }
                }
            }
            .scrollIndicators(list.rows.count > Self.visibleRows ? .automatic : .never)
            .frame(height: CGFloat(min(list.rows.count, Self.visibleRows)) * Self.rowHeight)
            .onChange(of: list.selection) { _, selection in
                guard list.rows.indices.contains(selection) else { return }
                proxy.scrollTo(list.rows[selection].name)
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .frame(height: Self.height(rows: list.rows.count))
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)).shadow(radius: 3, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func row(_ skill: SkillSummary, selected: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Text(skill.name)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .layoutPriority(1)
                Text(skill.description)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(skill.name)
        .accessibilityLabel("Skill \(skill.name)")
    }
}

/// A linked item chip (docs/chats.md › Linked items): the symbol of the item's sidebar section,
/// its short name and an unlink button; the tooltip is the item's text.
struct ComposerLinkedItemChip: View {
    let item: LinkedItem
    let unlink: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.ref.section.symbol)
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            Button(action: unlink) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Unlink \(item.name)")
        }
        .font(.caption)
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        .help(item.text)
    }
}

/// Above the composer: `Checking the Claude CLI…` with a small spinner while `checking` is true;
/// when the CLI is unavailable, a banner with the error (docs/chats.md › Composer).
struct ClaudeStatusBanner: View {
    let workspace: DeviceWorkspace
    @Environment(AppModel.self) private var app

    var body: some View {
        if let status = workspace.claudeStatus {
            if status.checking {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Checking the Claude CLI…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 4)
            } else if !status.available {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if workspace.isLocal {
                        Text(status.error ?? "")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open Settings") {
                            app.openSettings(tab: .general)
                        }
                    } else {
                        Text("Claude CLI is not available on \(workspace.deviceName): \(status.error ?? "")")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.callout)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
        }
    }
}
