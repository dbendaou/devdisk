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

enum RowActivity: Equatable {
    case running(verb: String, freed: UInt64)
    case finished(message: String, success: Bool, hideFromEstimate: Bool)

    var caption: String {
        switch self {
        case .running(let verb, let freed):
            freed > 0 ? "\(verb) \(ByteFormat.string(freed)) freed" : verb
        case .finished(let message, _, _):
            message
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
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
    var rowActivity: [String: RowActivity] = [:]
    var mapScanning = false
    var placed: [LayoutRect] = []

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = UUID()
    @ObservationIgnored private var mapTask: Task<Void, Never>?
    @ObservationIgnored private var mapGeneration = UUID()
    @ObservationIgnored private var cancelFlags: [String: CancelFlag] = [:]
    @ObservationIgnored private var layoutGeneration = 0
    @ObservationIgnored private var mapCanvas = (width: 0.0, height: 0.0)
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

    /// Suggestions that are still to do. A running or finished delete is no longer reclaimable.
    var liveReport: CleanupReport {
        let hidden = Set(rowActivity.compactMap { id, activity -> String? in
            switch activity {
            case .running:
                return id
            case .finished(_, _, true):
                return id
            case .finished(_, _, false):
                return nil
            }
        })
        return CleanupReport.summarizing(
            report.suggestions.filter { !hidden.contains($0.id) },
            skippedProtected: report.skippedProtected
        )
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

    /// Full per-file walk for the Explore treemap. It runs beside a cleanup scan.
    func scanExplore() {
        guard let rootPath else { return }
        mapTask?.cancel()
        let generation = UUID()
        mapGeneration = generation
        mapScanning = true
        let path = rootPath
        let scanner = DirectoryScanner()
        mapTask = Task {
            let stream = scanner.events(root: path)
            do {
                for try await event in stream {
                    switch event {
                    case .progress:
                        break
                    case .snapshot(let partial), .finished(let partial):
                        guard mapGeneration == generation else { return }
                        adoptMap(partial)
                    }
                }
                guard mapGeneration == generation else { return }
                mapScanning = false
            } catch is CancellationError {
                guard mapGeneration == generation else { return }
                mapScanning = false
            } catch {
                guard mapGeneration == generation else { return }
                mapScanning = false
                statusMessage = error.localizedDescription
            }
        }
    }

    func ensureMap() {
        guard rootPath != nil, tree == nil, mapTask == nil else { return }
        scanExplore()
    }

    func cancelMap() {
        mapTask?.cancel()
        mapTask = nil
        mapScanning = false
    }

    func noteMapSize(width: Double, height: Double) {
        guard abs(width - mapCanvas.width) > 1 || abs(height - mapCanvas.height) > 1 else { return }
        mapCanvas = (width, height)
        relayout()
    }

    func relayout() {
        guard let node = zoomNode, mapCanvas.width > 2, mapCanvas.height > 2 else {
            placed = []
            return
        }
        layoutGeneration += 1
        let generation = layoutGeneration
        let snapshot = node
        let frame = TreemapFrame(x: 0, y: 0, width: mapCanvas.width, height: mapCanvas.height)
        Task.detached {
            let rects = SquarifiedTreemap.layout(node: snapshot, in: frame)
            await MainActor.run {
                guard generation == self.layoutGeneration else { return }
                self.placed = rects
            }
        }
    }

    private func adoptMap(_ tree: ScanTree) {
        let hadTree = self.tree != nil
        self.tree = tree
        if !hadTree || zoomPath == nil {
            zoomPath = tree.root.path
        }
        if selectedID == nil {
            selectedID = tree.root.id
        }
        relayout()
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
        let verb = activityVerb(suggestion, dryRun: dryRun, trashInstead: trashInstead)
        rowActivity[suggestion.id] = .running(verb: verb, freed: 0)
        if !dryRun {
            removedPrefixes.append(contentsOf: suggestion.paths)
            let held = suppressions
            let paths = suggestion.paths
            Task { await held.suppress(paths) }
        }
        let flag = CancelFlag()
        cancelFlags[suggestion.id] = flag
        // Build the performer before the detached task. A mutable local captured
        // by Task.detached is a sending capture of main-actor state.
        let performer: MacCleanupPerformer = {
            var performer = MacCleanupPerformer()
            performer.isCancelled = { flag.isCancelled }
            return performer
        }()
        let id = suggestion.id
        let (stream, continuation) = AsyncStream.makeStream(of: UInt64.self)
        Task {
            let pump = Task { @MainActor in
                for await bytes in stream {
                    self.noteFreed(id, bytes)
                }
            }
            let record: RemovalRecord
            do {
                record = try await Task.detached {
                    try await CleanupExecutor(performer: performer, fileSystem: POSIXFileSystem()).execute(
                        suggestion,
                        scanRoot: rootPath,
                        dryRun: dryRun,
                        trashInstead: trashInstead,
                        progress: { continuation.yield($0.bytesFreed) },
                        isCancelled: { flag.isCancelled }
                    )
                }.value
            } catch {
                continuation.finish()
                await pump.value
                self.finish(suggestion, dryRun: dryRun, rootPath: rootPath, message: error.localizedDescription, success: false, bytes: 0)
                return
            }
            continuation.finish()
            await pump.value
            let message = cardMessage(record, trashInstead: trashInstead)
            self.finish(
                suggestion,
                dryRun: dryRun,
                rootPath: rootPath,
                message: message,
                success: record.succeeded,
                bytes: record.bytesFreed,
                logRecord: record
            )
        }
    }

    func cancelRow(_ id: String) {
        cancelFlags[id]?.cancel()
    }

    private func noteFreed(_ id: String, _ bytes: UInt64) {
        guard case .running(let verb, _) = rowActivity[id] else { return }
        rowActivity[id] = .running(verb: verb, freed: bytes)
    }

    private func finish(
        _ suggestion: CleanupSuggestion,
        dryRun: Bool,
        rootPath: String,
        message: String,
        success: Bool,
        bytes: UInt64,
        logRecord: RemovalRecord? = nil
    ) {
        if let logRecord {
            log.records.insert(logRecord, at: 0)
            try? RemovalLogStore.save(log)
        }
        let hide = success && !dryRun
        rowActivity[suggestion.id] = .finished(message: message, success: success, hideFromEstimate: hide)
        cancelFlags[suggestion.id] = nil
        if success && !dryRun {
            volume = VolumeProbe.stats(at: rootPath)
        } else if !dryRun {
            forgetRemoved(suggestion.paths)
            let held = suppressions
            Task { await held.release(suggestion.paths) }
        }
        statusMessage = message
        _ = bytes
    }

    private func activityVerb(_ suggestion: CleanupSuggestion, dryRun: Bool, trashInstead: Bool) -> String {
        if dryRun { return "Previewing…" }
        switch suggestion.effect {
        case .command, .commandForEach:
            return "Running…"
        case .removePermanently where trashInstead, .moveToTrash:
            return "Moving to Trash…"
        default:
            return "Deleting…"
        }
    }

    private func cardMessage(_ record: RemovalRecord, trashInstead: Bool) -> String {
        if record.succeeded && !record.dryRun && !trashInstead && record.bytesFreed > 0 && !record.message.hasPrefix("Finished") && !record.message.hasPrefix("Ran ") {
            return "Freed \(ByteFormat.string(record.bytesFreed))"
        }
        if record.succeeded && !record.dryRun && trashInstead {
            return "Moved \(ByteFormat.string(record.bytesFreed)) to Trash"
        }
        return record.message
    }

    private func forgetRemoved(_ paths: [String]) {
        let dropped = Set(paths)
        removedPrefixes.removeAll { dropped.contains($0) }
    }

}
#endif
