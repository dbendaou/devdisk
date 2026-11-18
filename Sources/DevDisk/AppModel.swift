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
    var id: String { suggestion.id + (dryRun ? "#preview" : "#run") }
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
    var safetyFilter: SafetyFilter = .all
    var pending: PendingCleanup?
    var log = RemovalLog()
    var statusMessage: String?
    var isActing = false

    @ObservationIgnored private var scanTask: Task<Void, Never>?

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
        switch safetyFilter {
        case .all: report.suggestions
        case .safe: report.suggestions.filter { $0.safety == .safe }
        case .review: report.suggestions.filter { $0.safety == .review }
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
        let path = root.standardizedFileURL.path
        phase = .scanning
        progress = ScanProgress(currentPath: path)
        statusMessage = nil
        let scanner = DirectoryScanner()
        scanTask = Task {
            let stream = scanner.events(root: path)
            do {
                for try await event in stream {
                    switch event {
                    case .progress(let value):
                        progress = value
                    case .finished(let finished):
                        tree = finished
                        report = CleanupEngine().evaluate(root: finished.root, staleAfterDays: staleAfterDays)
                        volume = VolumeProbe.stats(at: path)
                        volumeName = MacActions.volumeName(path)
                        rootPath = path
                        zoomPath = path
                        selectedID = finished.root.id
                        phase = .ready
                        if section == .log { section = .cleanup }
                    }
                }
            } catch is CancellationError {
                if tree == nil {
                    phase = .idle
                } else if phase == .scanning {
                    phase = .ready
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func setStaleDays(_ days: Int) {
        staleAfterDays = min(3650, max(0, days))
        guard let tree else { return }
        report = CleanupEngine().evaluate(root: tree.root, staleAfterDays: staleAfterDays)
    }

    func ask(_ suggestion: CleanupSuggestion, dryRun: Bool) {
        pending = PendingCleanup(suggestion: suggestion, dryRun: dryRun || previewOnly)
    }

    func performPending() async {
        guard let pending, let rootPath else { return }
        isActing = true
        defer { isActing = false }
        let suggestion = pending.suggestion
        let dryRun = pending.dryRun
        let performer = MacCleanupPerformer()
        do {
            let record = try await Task.detached {
                try CleanupExecutor(performer: performer).execute(
                    suggestion,
                    scanRoot: rootPath,
                    dryRun: dryRun
                )
            }.value
            log.records.insert(record, at: 0)
            try? RemovalLogStore.save(log)
            self.pending = nil
            if record.succeeded && !record.dryRun {
                statusMessage = record.message + " Scan again to refresh the map."
            } else {
                statusMessage = record.message
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
#endif
