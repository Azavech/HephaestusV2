// OWNER: ui-builds — the Builds section: the list pane with its header, the detail pane and the
// refreshes (docs/builds.md › Layout, › Refresh, › Empty and error states).
import AppKit
import HephaestusCore
import SwiftUI

/// The Builds section of the active project: the workflow runs and the releases of its GitHub
/// repository, a list pane and a detail pane (docs/builds.md). The view gets a new identity per
/// device and project, so that its model and its refresh loop start again.
struct BuildsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @State private var model: BuildsModel?
    @State private var listWidth: CGFloat = 320

    private var githubPage: String? {
        workspace.details[projectID]?.githubPage
    }

    var body: some View {
        Group {
            if let model {
                ListDetailSplit(listWidth: $listWidth) {
                    BuildsListPane(model: model)
                } detail: {
                    BuildsDetailPane(model: model, isLocal: workspace.isLocal)
                }
            } else {
                Color.clear
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: workspace.connectionGeneration) {
            let model: BuildsModel
            if let existing = self.model {
                // A reconnection runs the task again with the same model.
                model = existing
            } else {
                model = BuildsModel(window: window, workspace: workspace, projectID: projectID)
                model.sectionAppeared()
                self.model = model
            }
            // At once, then 30 s after the end of each refresh, while the section is shown
            // (docs/builds.md › Refresh). A refresh that ended meanwhile, Refresh for example,
            // moves the next one; the loop sleeps at least a second between two refreshes.
            while !Task.isCancelled {
                await model.refresh()
                repeat {
                    let remaining = model.nextAutomaticRefresh.timeIntervalSinceNow
                    try? await Task.sleep(for: .seconds(max(remaining, 1)))
                } while !Task.isCancelled && model.nextAutomaticRefresh.timeIntervalSinceNow > 0
            }
        }
        .onChange(of: githubPage) {
            // The section reads again when the project's GitHub page changes.
            guard let model else { return }
            Task { await model.refresh() }
        }
    }
}

// MARK: - List pane

/// The header with the segmented control and `Refresh`, then the list of the shown tab
/// (docs/builds.md › Layout).
private struct BuildsListPane: View {
    let model: BuildsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Builds", selection: Binding(get: { model.tab }, set: { model.selectTab($0) })) {
                Text("Workflow Runs").tag(BuildsTab.runs)
                Text("Releases").tag(BuildsTab.releases)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 4)
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .runs:
            if let error = model.runsError {
                BuildsMessageView(message: error)
            } else if let runs = model.runs {
                if runs.isEmpty {
                    BuildsMessageView(message: "No workflow runs yet.")
                } else {
                    BuildsRows(items: runs, id: \.id, selected: model.selectedRunID, select: { model.selectRun($0.id) }) { run in
                        BuildRunRow(run: run)
                    }
                }
            } else {
                BuildsSpinner()
            }
        case .releases:
            if let error = model.releasesError {
                BuildsMessageView(message: error)
            } else if let releases = model.releases {
                if releases.isEmpty {
                    BuildsMessageView(message: "No releases yet.")
                } else {
                    BuildsRows(items: releases, id: \.tag, selected: model.selectedReleaseTag,
                               select: { model.selectRelease($0.tag) }) { release in
                        BuildReleaseRow(release: release)
                    }
                }
            } else {
                BuildsSpinner()
            }
        }
    }
}

/// The rows of a list, each a button that selects it; the selected row is drawn in the accent
/// colour, as the sidebar's rows.
private struct BuildsRows<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    let selected: ID?
    let select: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: id) { item in
                    let isSelected = item[keyPath: id] == selected
                    Button {
                        select(item)
                    } label: {
                        row(item)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(6)
        }
    }
}

// MARK: - Detail pane

/// The details of the run or release selected in the shown tab (docs/builds.md › Run details,
/// › Release details).
private struct BuildsDetailPane: View {
    let model: BuildsModel
    let isLocal: Bool

    var body: some View {
        Group {
            switch model.tab {
            case .runs:
                if model.selectedRunID == nil {
                    BuildsMessageView(message: "Select a run")
                } else if let error = model.shownRunError {
                    BuildsMessageView(message: error)
                } else if let run = model.shownRunDetail {
                    ScrollView {
                        BuildRunDetailView(run: run, model: model)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    BuildsSpinner()
                }
            case .releases:
                if model.selectedReleaseTag == nil {
                    BuildsMessageView(message: "Select a release")
                } else if let error = model.shownReleaseError {
                    BuildsMessageView(message: error)
                } else if let release = model.shownReleaseDetail {
                    ScrollView {
                        BuildReleaseDetailView(release: release, listed: model.releases?.first { $0.tag == release.tag },
                                               model: model, isLocal: isLocal)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    BuildsSpinner()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - States

/// A text in place of a list or of the details (docs/builds.md › Empty and error states).
struct BuildsMessageView: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The spinner of a list or details that have not loaded yet.
struct BuildsSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
