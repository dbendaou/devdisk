#if os(macOS)
import Foundation
import Observation
import DevDiskCore

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case cleanup
    case explore
    case log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanup: "Smart cleanup"
        case .explore: "Explore"
        case .log: "Log"
        }
    }

    var symbol: String {
        switch self {
        case .cleanup: "sparkles"
        case .explore: "square.grid.3x3"
        case .log: "clock.arrow.circlepath"
        }
    }
}

enum SafetyFilter: String, CaseIterable, Identifiable {
    case all
    case safe
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .safe: "Safe"
        case .review: "Review"
        }
    }
}

enum ScanPhase: Equatable {
    case idle
    case scanning
    case ready
    case failed(String)
}

struct PendingCleanup: Identifiable {
    var suggestion: CleanupSuggestion
    var dryRun: Bool
    var movesToTrash: Bool
    var id: String { suggestion.id + (dryRun ? "#preview" : movesToTrash ? "#trash" : "#delete") }
}

@MainActor
@Observable
final class AppModel {
    var section: AppSection = .cleanup
    var explorePane: ExplorePane = .map
    var staleAfterDays = CleanupCatalog.defaultStaleDays
    var phase: ScanPhase = .idle
    var rootPath: String?
    var volumeName = ""
    var volume: VolumeStats?
    var tree: ScanTree?
    var report = CleanupReport(
        suggestions: [],
        estimatedReclaimableBytes: 0,
        safeBytes: 0,
        reviewBytes: 0,
        skippedProtected: []
    )
    var progress = ScanProgress()
    var selectedID: Int?
    var zoomPath: String?
    var sortOrder: OutlineOrder = .size
    var previewOnly = false
    /// When on, confirmed deletes go to Trash instead of being removed permanently.
    var movesToTrash = false
    var safetyFilter: SafetyFilter = .all
    var pending: PendingCleanup?
    var log = RemovalLog()
    var statusMessage: String?
    var isActing = false

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = UUID()
    @ObservationIgnored private var activeDeletes = 0
    /// Paths confirmed for removal. Checked on the main actor so a suggestion
    /// cannot reappear in the gap before the scanner's suppression actor updates.
    @ObservationIgnored private var removedPrefixes: [String] = []
    @ObservationIgnored private var suppressions = CleanupSuppressions()
    @ObservationIgnored private var scanSettings = CleanupScanSettings(staleAfterDays: CleanupCatalog.defaultStaleDays)

    var sortedRoot: ScanNode? {
        guard let root = tree?.root else { return nil }
        return sortOrder.sortedTree(root)
    }

    var zoomNode: ScanNode? {
        guard let root = tree?.root else { return nil }
        guard let zoomPath else { return root }
        return root.node(atPath: zoomPath) ?? root
    }

    var selectedNode: ScanNode? {
        guard let selectedID, let root = tree?.root else { return nil }
        return root.node(id: selectedID)
    }

    var filteredSuggestions: [CleanupSuggestion] {
        report.suggestions.filter { suggestion in
            switch safetyFilter {
            case .all: break
            case .safe: if suggestion.safety != .safe { return false }
            case .review: if suggestion.safety != .review { return false }
            }
            return passesAge(suggestion)
        }
    }

    init() {
        log = RemovalLogStore.load()
    }

    func scanHome() {
        startScan(root: FileManager.default.homeDirectoryForCurrentUser)
    }

    func chooseFolder() {
        guard let url = MacActions.chooseFolder() else { return }
        startScan(root: url)
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func startScan(root: URL) {
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        let path = Paths.normalize(root.path)
        let settings = CleanupScanSettings(staleAfterDays: staleAfterDays)
        let suppressed = CleanupSuppressions()
        let carried = removedPrefixes
        scanSettings = settings
        suppressions = suppressed
        if !carried.isEmpty {
            Task { await suppressed.suppress(carried) }
        }
        phase = .scanning
        rootPath = path
        volume = VolumeProbe.stats(at: path)
        volumeName = MacActions.volumeName(path)
        report = CleanupReport.summarizing([])
        progress = ScanProgress(currentPath: path, startedAt: Date())
        statusMessage = nil
        if section == .log { section = .cleanup }
        let scanner = CleanupScanner()
        scanTask = Task {
            let stream = scanner.events(
                root: path,
                settings: settings,
                suppressions: suppressed
            )
            do {
                for try await event in stream {
                    switch event {
                    case .progress(let value):
                        progress = value
                    case .suggestion(let suggestion):
                        await adopt(suggestion, suppressions: suppressed)
                    case .finished:
                        guard scanGeneration == generation else { return }
                        phase = .ready
                    }
                }
            } catch is CancellationError {
                guard scanGeneration == generation else { return }
                phase = report.suggestions.isEmpty ? .idle : .ready
                if !report.suggestions.isEmpty {
                    statusMessage = "Scan stopped. Kept \(report.suggestions.count) results found so far."
                }
            } catch {
                guard scanGeneration == generation else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Full per-file walk used only for the Explore treemap.
    func scanExplore() {
        guard let rootPath else { return }
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        let path = rootPath
        phase = .scanning
        let scanner = DirectoryScanner()
        scanTask = Task {
            let stream = scanner.events(root: path)
            do {
                for try await event in stream {
                    switch event {
                    case .progress(let value):
                        progress = value
                    case .finished(let finished):
                        guard scanGeneration == generation else { return }
                        tree = finished
                        zoomPath = path
                        selectedID = finished.root.id
                        phase = .ready
                        section = .explore
                    }
                }
            } catch is CancellationError {
                guard scanGeneration == generation else { return }
                phase = .ready
            } catch {
                guard scanGeneration == generation else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func setStaleDays(_ days: Int) {
        staleAfterDays = min(3650, max(0, days))
        let settings = scanSettings
        let value = staleAfterDays
        Task { await settings.update(days: value) }
    }

    private func adopt(_ suggestion: CleanupSuggestion, suppressions: CleanupSuppressions) async {
        guard let path = suggestion.paths.first else { return }
        if isRemoved(path) { return }
        if await suppressions.isSuppressed(path) { return }
        guard !report.suggestions.contains(where: { $0.id == suggestion.id }) else { return }
        report = CleanupReport.summarizing(report.suggestions + [suggestion])
    }

    private func isRemoved(_ path: String) -> Bool {
        let path = Paths.normalize(path)
        return removedPrefixes.contains { prefix in
            let prefix = Paths.normalize(prefix)
            return path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private func passesAge(_ suggestion: CleanupSuggestion) -> Bool {
        guard let date = suggestion.items.compactMap(\.lastModified).max() else { return true }
        if staleAfterDays == 0 { return true }
        return Date().timeIntervalSince(date) >= Double(staleAfterDays) * 86_400
    }

    func ask(_ suggestion: CleanupSuggestion, dryRun: Bool) {
        pending = PendingCleanup(
            suggestion: suggestion,
            dryRun: dryRun || previewOnly,
            movesToTrash: movesToTrash
        )
    }

    func performPending() {
        guard let pending, let rootPath else { return }
        let suggestion = pending.suggestion
        let dryRun = pending.dryRun
        let trashInstead = pending.movesToTrash
        self.pending = nil
        if !dryRun {
            report = report.removing(id: suggestion.id)
            removedPrefixes.append(contentsOf: suggestion.paths)
            let held = suppressions
            let paths = suggestion.paths
            Task { await held.suppress(paths) }
        }
        activeDeletes += 1
        isActing = true
        let performer = MacCleanupPerformer()
        Task {
            defer {
                activeDeletes -= 1
                isActing = activeDeletes > 0
            }
            do {
                let record = try await Task.detached {
                    try CleanupExecutor(performer: performer).execute(
                        suggestion,
                        scanRoot: rootPath,
                        dryRun: dryRun,
                        trashInstead: trashInstead
                    )
                }.value
                log.records.insert(record, at: 0)
                try? RemovalLogStore.save(log)
                if record.succeeded && !record.dryRun {
                    report = report.removing(id: suggestion.id)
                    forgetRemoved(suggestion.paths)
                    volume = VolumeProbe.stats(at: rootPath)
                    statusMessage = record.message
                } else if !record.succeeded && !dryRun {
                    forgetRemoved(suggestion.paths)
                    restore(suggestion)
                    statusMessage = record.message
                } else {
                    statusMessage = record.message
                }
            } catch {
                if !dryRun {
                    forgetRemoved(suggestion.paths)
                    restore(suggestion)
                }
                statusMessage = error.localizedDescription
            }
        }
    }

    private func forgetRemoved(_ paths: [String]) {
        let dropped = Set(paths)
        removedPrefixes.removeAll { dropped.contains($0) }
    }

    private func restore(_ suggestion: CleanupSuggestion) {
        guard !report.suggestions.contains(where: { $0.id == suggestion.id }) else { return }
        report = CleanupReport.summarizing(report.suggestions + [suggestion])
    }
}
#endif
