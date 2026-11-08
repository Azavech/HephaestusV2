// OWNER: ui-builds — the rows and the details of workflow runs (docs/builds.md › Run list,
// › Run details).
import HephaestusCore
import SwiftUI

/// A row of the Workflow Runs list: the status icon, the title, the workflow name and branch,
/// then the start time and duration (docs/builds.md › Run list).
struct BuildRunRow: View {
    let run: WorkflowRun

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            BuildStatusIcon(kind: BuildStatusKind(status: run.status, conclusion: run.conclusion))
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(run.workflowName.isEmpty ? run.branch : "\(run.workflowName) · \(run.branch)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    Text(BuildFormat.date(BuildFormat.start(of: run)) + " · ")
                    BuildDurationText(isCounting: run.status != "completed") { now in
                        BuildFormat.runDuration(run, now: now)
                    }
                }
                .lineLimit(1)
                .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}

/// The details of a run: its title and buttons, its fields, then its jobs with their steps
/// (docs/builds.md › Run details).
struct BuildRunDetailView: View {
    let run: WorkflowRun
    let model: BuildsModel

    private var isCompleted: Bool { run.status == "completed" }

    private var hasFailedJob: Bool {
        (run.jobs ?? []).contains { BuildFormat.failed($0.conclusion) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(run.title)
                .font(.title2.bold())
                .textSelection(.enabled)
            buttons
            fields
            jobs
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if isCompleted {
                Button("Re-run All Jobs") {
                    Task { await model.rerun(run.id, failedOnly: false) }
                }
                if hasFailedJob {
                    Button("Re-run Failed Jobs") {
                        Task { await model.rerun(run.id, failedOnly: true) }
                    }
                }
            } else {
                Button("Cancel Run") {
                    Task { await model.cancel(run.id) }
                }
            }
        }
        .disabled(model.isRunningAction || !model.workspace.isConnected)
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            field("Workflow") { Text(run.workflowName) }
            field("Branch") { Text(run.branch) }
            field("Commit") {
                Text(String(run.commit.prefix(7)))
                    .font(.system(.body, design: .monospaced))
            }
            field("Event") { Text(run.event) }
            field("Status") {
                HStack(spacing: 6) {
                    BuildStatusIcon(kind: BuildStatusKind(status: run.status, conclusion: run.conclusion))
                    Text(BuildFormat.statusText(status: run.status, conclusion: run.conclusion))
                }
            }
            field("Duration") {
                BuildDurationText(isCounting: !isCompleted) { now in
                    BuildFormat.runDuration(run, now: now)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func field(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
        }
    }

    private var jobs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Jobs")
                .font(.headline)
            ForEach(run.jobs ?? [], id: \.id) { job in
                VStack(alignment: .leading, spacing: 4) {
                    itemRow(name: job.name, status: job.status, conclusion: job.conclusion,
                            startedAt: job.startedAt, completedAt: job.completedAt)
                        .font(.body.weight(.medium))
                    ForEach(job.steps, id: \.number) { step in
                        itemRow(name: step.name, status: step.status, conclusion: step.conclusion,
                                startedAt: step.startedAt, completedAt: step.completedAt)
                            .padding(.leading, 24)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// A job or a step: its status icon, its name and its duration.
    private func itemRow(name: String, status: String, conclusion: String?, startedAt: Date?, completedAt: Date?) -> some View {
        HStack(spacing: 8) {
            BuildStatusIcon(kind: BuildStatusKind(status: status, conclusion: conclusion))
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            BuildDurationText(isCounting: status != "completed" && startedAt != nil) { now in
                BuildFormat.itemDuration(status: status, startedAt: startedAt, completedAt: completedAt, now: now)
            }
            .foregroundStyle(.secondary)
        }
    }
}
