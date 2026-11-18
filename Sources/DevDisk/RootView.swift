#if os(macOS)
import SwiftUI
import DevDiskCore

struct RootView: View {
    @Bindable var model: AppModel
    @State private var showSafety = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.tree == nil && model.phase != .scanning {
                idle
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                        .navigationTitle(model.section.title)
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
        .sheet(item: $model.pending) { pending in
            ConfirmationSheet(model: model, pending: pending)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { if case .failed = model.phase { return true } else { return false } },
                set: { if !$0, case .failed = model.phase { model.phase = model.tree == nil ? .idle : .ready } }
            ),
            presenting: failedMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var failedMessage: String? {
        if case .failed(let message) = model.phase { return message }
        return nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DevDisk")
                        .font(.title2.weight(.semibold))
                    Text(model.rootPath ?? "No folder scanned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Scan Home") { model.scanHome() }
                Button("Choose Folder…") { model.chooseFolder() }
                if model.phase == .scanning {
                    Button("Cancel") { model.cancelScan() }
                }
                Button {
                    showSafety = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Safety notes")
                .popover(isPresented: $showSafety, arrowEdge: .bottom) {
                    safetyNotes.padding(16).frame(width: 360)
                }
            }
            if let volume = model.volume {
                CapacityBar(fraction: volume.usedFraction)
                HStack(spacing: 18) {
                    metric("Total", ByteFormat.string(volume.totalBytes))
                    metric("Used", ByteFormat.string(volume.usedBytes))
                    metric("Free", ByteFormat.string(volume.availableBytes))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Estimated reclaimable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ByteFormat.string(model.liveReport.estimatedReclaimableBytes))
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(DevDiskTheme.reclaim)
                        Text("Safe \(ByteFormat.string(model.liveReport.safeBytes)) · Review \(ByteFormat.string(model.liveReport.reviewBytes))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if model.liveReport.upperBoundBytes > 0 {
                            Text("Includes up to \(ByteFormat.string(model.liveReport.upperBoundBytes)) from container prunes")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if model.phase == .scanning {
                ProgressView()
                    .progressViewStyle(.linear)
                HStack(spacing: 8) {
                    if let started = model.progress.startedAt {
                        Text(started, style: .timer)
                    }
                    Text("\(model.progress.visitedFiles.formatted()) files · \(ByteFormat.string(model.progress.allocatedBytes)) · \(model.progress.suggestionsFound) found · \(ByteFormat.string(model.liveReport.estimatedReclaimableBytes)) reclaimable · \(model.progress.currentPath)")
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let errors = model.tree?.stats.errorCount, errors > 0 {
                Text("\(errors) \(errors == 1 ? "folder" : "folders") could not be read. Their contents are missing from the map and will not be suggested for cleanup.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let status = model.statusMessage, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit().weight(.medium))
        }
    }

    private var sidebar: some View {
        List(selection: $model.section) {
            ForEach(AppSection.allCases) { section in
                sidebarRow(section).tag(section)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 196, ideal: 220, max: 280)
        .safeAreaInset(edge: .bottom) {
            if !model.volumeName.isEmpty {
                Text(model.volumeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .cleanup: CleanupScreen(model: model)
        case .explore: ExploreScreen(model: model)
        case .log: LogScreen(model: model)
        }
    }

    private var idle: some View {
        VStack(spacing: 18) {
            Image(systemName: "internaldrive")
                .font(.system(size: 48))
                .foregroundStyle(DevDiskTheme.reclaim)
            Text("Reclaim the space your toolchains leave behind")
                .font(.title2.weight(.semibold))
            Text("Scan your home folder. DevDisk groups node_modules, Xcode data, package caches, simulator images, and container disks by ecosystem, and tells you which ones are safe to remove.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            HStack {
                Button("Scan Home") { model.scanHome() }
                    .buttonStyle(.borderedProminent)
                Button("Choose Folder…") { model.chooseFolder() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    @ViewBuilder
    private func sidebarRow(_ section: AppSection) -> some View {
        if section == .cleanup, model.report.suggestions.count > 0 {
            Label(section.title, systemImage: section.symbol)
                .badge(model.report.suggestions.count)
        } else {
            Label(section.title, systemImage: section.symbol)
        }
    }

    private var safetyNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Safety").font(.headline)
            Text("Smart cleanup is the main screen. Explore is a treemap and file list for anything the rules do not name.")
            Text("The default action deletes files permanently. A switch can move them to Trash instead. brew, docker, podman, simctl, and git gc run only after you confirm them. Container disk images are never deleted; the card runs that tool's prune command.")
            Text("Nothing outside the scanned folder is touched. System folders, Keychains, Mail, and Photos libraries are refused.")
            Text("Safe means the bytes are regenerable. Review means the folder may hold data you still want. Databases are always Review.")
        }
        .font(.callout)
    }
}

struct ConfirmationSheet: View {
    @Bindable var model: AppModel
    var pending: PendingCleanup
    @State private var acknowledged = false

    private var copy: ConfirmationCopy {
        ConfirmationBuilder.make(pending.suggestion, dryRun: pending.dryRun, trashInstead: pending.movesToTrash)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(copy.title).font(.title3.weight(.semibold))
                Spacer()
                SafetyBadge(level: copy.safety)
            }
            Text(copy.detail)
            Text(ByteFormat.string(copy.totalBytes))
                .font(.title2.monospacedDigit().weight(.semibold))
            Text(pending.suggestion.actionDescription)
                .font(.callout.monospaced())
            Text("\(copy.paths.count) paths")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(copy.paths, id: \.self) { path in
                        Text(path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 320)
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            if copy.requiresExtraAcknowledgement {
                Toggle(
                    pending.movesToTrash
                        ? "This may contain data I still need. Move it to Trash anyway."
                        : "This may contain data I still need. Delete it permanently anyway.",
                    isOn: $acknowledged
                )
            }
            HStack {
                Button("Cancel") { model.pending = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy.confirmTitle) {
                    model.performPending()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(copy.requiresExtraAcknowledgement && !acknowledged)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

enum ExplorePane: String, CaseIterable, Identifiable {
    case map
    case files
    case kinds

    var id: String { rawValue }
    var title: String {
        switch self {
        case .map: "Map"
        case .files: "Files"
        case .kinds: "Kinds"
        }
    }
}

struct ExploreScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Explore", selection: $model.explorePane) {
                ForEach(ExplorePane.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .onAppear { model.ensureMap() }
            .onChange(of: model.section) { _, section in
                if section == .explore { model.ensureMap() }
            }
            .onChange(of: model.rootPath) { _, _ in
                if model.section == .explore { model.ensureMap() }
            }
            if model.mapScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring folders. Blocks grow as each directory finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel map") { model.cancelMap() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else if model.tree == nil {
                HStack {
                    Text("The map walks every file. It can run while cleanup is scanning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Build map") { model.scanExplore() }
                        .disabled(model.rootPath == nil)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            switch model.explorePane {
            case .map: TreemapScreen(model: model)
            case .files: FilesScreen(model: model)
            case .kinds: KindsScreen(model: model)
            }
        }
    }
}
#endif
