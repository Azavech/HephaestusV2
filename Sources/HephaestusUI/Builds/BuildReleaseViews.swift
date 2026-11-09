// OWNER: ui-builds — the rows and the details of releases, with the downloads of their assets
// (docs/builds.md › Release list, › Release details, › Downloads).
import AppKit
import HephaestusCore
import SwiftUI

/// The badge of a release: `Latest` in green for the repository's latest release, otherwise
/// `Pre-release` in orange for a pre-release, otherwise none (docs/builds.md › Release list).
struct ReleaseBadge: View {
    let isLatest: Bool
    let isPrerelease: Bool

    var body: some View {
        if let (text, color) = Self.badge(isLatest: isLatest, isPrerelease: isPrerelease) {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.15)))
                .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
        }
    }

    /// The text and colour of the badge; nil without badge.
    static func badge(isLatest: Bool, isPrerelease: Bool) -> (String, Color)? {
        if isLatest { return ("Latest", .green) }
        if isPrerelease { return ("Pre-release", .orange) }
        return nil
    }
}

/// The name, left out when empty, and the date of a release: publication, else creation.
private func releaseSubtitle(name: String, publishedAt: Date?, createdAt: Date) -> String {
    let date = BuildFormat.date(publishedAt ?? createdAt)
    return name.isEmpty ? date : "\(name) · \(date)"
}

/// A row of the Releases list: the tag and the badge, then the name and the date
/// (docs/builds.md › Release list).
struct BuildReleaseRow: View {
    let release: GitHubRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(release.tag)
                    .lineLimit(1)
                    .truncationMode(.tail)
                ReleaseBadge(isLatest: release.isLatest, isPrerelease: release.isPrerelease)
            }
            Text(releaseSubtitle(name: release.name, publishedAt: release.publishedAt, createdAt: release.createdAt))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}

/// The details of a release: the tag with the badge of its row, the name and the date, the notes
/// as Markdown and the assets with their sizes and `Download` (docs/builds.md › Release details).
struct BuildReleaseDetailView: View {
    let release: ReleaseDetail
    /// The release's row of the list, which tells whether it is the latest; nil when it is no
    /// longer listed.
    let listed: GitHubRelease?
    let model: BuildsModel
    /// Remote windows have no `Download` and no `Show in Finder`.
    let isLocal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(release.tag)
                        .font(.title2.bold())
                    ReleaseBadge(isLatest: listed?.isLatest ?? false, isPrerelease: listed?.isPrerelease ?? false)
                }
                Text(releaseSubtitle(name: release.name, publishedAt: release.publishedAt, createdAt: release.createdAt))
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            if !release.notes.isEmpty {
                // The shared renderer with the markers of every Markdown view: the ▶ of a sound
                // marker plays the sound of the project, other links do nothing, project images
                // show as blocked and web images load (docs/builds.md › Release details).
                MarkdownView(markdown: release.notes)
                    .markdownMarkers(projectID: model.projectID, workspace: model.workspace, window: model.window)
            }
            if !release.assets.isEmpty {
                assets
            }
        }
    }

    private var assets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Assets")
                .font(.headline)
            ForEach(release.assets, id: \.name) { asset in
                HStack(spacing: 8) {
                    Text(asset.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if isLocal {
                        downloadButton(asset)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func downloadButton(_ asset: ReleaseAsset) -> some View {
        switch model.downloads[DownloadKey(tag: release.tag, asset: asset.name)] {
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case .saved(let path):
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case nil:
            Button("Download") {
                Task { await model.download(tag: release.tag, asset: asset.name) }
            }
            .disabled(!model.workspace.isConnected)
        }
    }
}
