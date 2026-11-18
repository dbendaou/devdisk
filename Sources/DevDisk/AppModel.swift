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

@Observable
final class CardProgress {
    var activity: RowActivity?
}

struct CardDisplay: Equatable {
    var sizeText: String
    var lines: [String]
    var pathLabel: String
}

struct SafeBatchLine: Identifiable, Equatable {
    var id: String
    var title: String
    var message: String
    var success: Bool
}

enum SafeBatchStep: Equatable {
    case choose
    case running
    case summary
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
    var previewOnly = false {
        didSet { rebuildDisplay() }
    }
    /// When on, confirmed deletes go to Trash instead of being removed permanently.
    var movesToTrash = false {
        didSet { rebuildDisplay() }
    }
    var safetyFilter: SafetyFilter = .all {
        didSet { rebuildDisplay() }
    }
    var pending: PendingCleanup?
    var log = RemovalLog()
    var statusMessage: String?
    var displayedGroups: [CleanupGroup] = []
    var displayedCount = 0
    var safeBatchSuggestions: [CleanupSuggestion] = []
    var safeBatchBytes: UInt64 = 0
    var safeBatchTitle = ""
    var showingSafeBatch = false
    var safeBatchStep: SafeBatchStep = .choose
    var safeBatchLines: [SafeBatchLine] = []
    var safeBatchFreed: UInt64 = 0
    var mapScanning = false
    var placed: [LayoutRect] = []

    @ObservationIgnored private var cardProgress: [String: CardProgress] = [:]
    @ObservationIgnored private var cardDisplay: [String: CardDisplay] = [:]
    @ObservationIgnored private var cleanupStop = ScanStop()
    @ObservationIgnored private var mapStop = ScanStop()
    @ObservationIgnored private var batchStop: CancelFlag?
    @ObservationIgnored private var lastProgressUI = Date.distantPast
    @ObservationIgnored private var pendingProgress: ScanProgress?
    @ObservationIgnored private var progressFlush: Task<Void, Never>?
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
        let hidden = Set(report.suggestions.compactMap { suggestion -> String? in
            switch cardProgress[suggestion.id]?.activity {
            case .running, .finished(_, _, true):
                return suggestion.id
            default:
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
        cancelWork()
    }

    /// Stops the cleanup scan and the Explore map walk, and keeps whatever was already found.
    func cancelWork() {
        cleanupStop.stop()
        mapStop.stop()
        scanTask?.cancel()
        mapTask?.cancel()
        scanGeneration = UUID()
        mapGeneration = UUID()
        let wasScanning = phase == .scanning
        let wasMapping = mapScanning
        mapScanning = false
        progressFlush?.cancel()
        flushScanProgress()
        if wasScanning {
            phase = .ready
            let kept = report.suggestions.count
            statusMessage = kept == 0 ? "Stopped" : "Stopped. Kept \(kept) results found so far."
        } else if wasMapping {
            statusMessage = "Stopped"
        }
    }

    func progressStore(for id: String) -> CardProgress {
        if let existing = cardProgress[id] { return existing }
        let created = CardProgress()
        cardProgress[id] = created
        return created
    }

    func display(for id: String) -> CardDisplay {
        cardDisplay[id] ?? CardDisplay(sizeText: "", lines: [], pathLabel: "")
    }

    func startScan(root: URL) {
        cleanupStop.stop()
        scanTask?.cancel()
        cleanupStop = ScanStop()
        let stop = cleanupStop
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
        rebuildDisplay()
        if section == .log { section = .cleanup }
        var scanner = CleanupScanner(stop: stop)
        scanner.stop = stop
        scanTask = Task {
            let stream = scanner.events(
                root: path,
                settings: settings,
                suppressions: suppressed
            )
            do {
                for try await event in stream {
                    if Task.isCancelled || stop.isStopped { break }
                    switch event {
                    case .progress(let value):
                        publishScanProgress(value)
                    case .suggestion(let suggestion):
                        await adopt(suggestion, suppressions: suppressed)
                    case .finished:
                        flushScanProgress()
                        guard scanGeneration == generation else { return }
                        phase = .ready
                    }
                }
                if Task.isCancelled || stop.isStopped {
                    throw CancellationError()
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
        mapStop.stop()
        mapTask?.cancel()
        mapStop = ScanStop()
        let stop = mapStop
        let generation = UUID()
        mapGeneration = generation
        mapScanning = true
        let path = rootPath
        let scanner = DirectoryScanner(stop: stop)
        mapTask = Task {
            let stream = scanner.events(root: path)
            do {
                for try await event in stream {
                    if Task.isCancelled || stop.isStopped { break }
                    switch event {
                    case .progress:
                        break
                    case .snapshot(let partial), .finished(let partial):
                        guard mapGeneration == generation else { return }
                        adoptMap(partial)
                    }
                }
                if Task.isCancelled || stop.isStopped {
                    throw CancellationError()
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
        rebuildDisplay()
    }

    private func publishScanProgress(_ value: ScanProgress) {
        pendingProgress = value
        if Date().timeIntervalSince(lastProgressUI) >= 0.25 {
            flushScanProgress()
            return
        }
        guard progressFlush == nil else { return }
        progressFlush = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.progressFlush = nil
            self.flushScanProgress()
        }
    }

    private func flushScanProgress() {
        guard let pendingProgress else { return }
        progress = pendingProgress
        lastProgressUI = Date()
    }

    private func adopt(_ suggestion: CleanupSuggestion, suppressions: CleanupSuppressions) async {
        guard let path = suggestion.paths.first else { return }
        if isRemoved(path) { return }
        if await suppressions.isSuppressed(path) { return }
        guard !report.suggestions.contains(where: { $0.id == suggestion.id }) else { return }
        _ = progressStore(for: suggestion.id)
        report = CleanupReport.summarizing(report.suggestions + [suggestion])
        rebuildDisplay()
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
        let flag = CancelFlag()
        cancelFlags[suggestion.id] = flag
        Task {
            await self.runRemoval(suggestion, dryRun: dryRun, trashInstead: trashInstead, rootPath: rootPath, flag: flag, sharedStop: nil)
        }
    }

    func openSafeBatch() {
        guard !safeBatchSuggestions.isEmpty else { return }
        safeBatchStep = .choose
        safeBatchLines = []
        safeBatchFreed = 0
        showingSafeBatch = true
    }

    func runSafeBatch(excluding excluded: Set<String>) {
        let items = safeBatchSuggestions.filter { !excluded.contains($0.id) }
        guard !items.isEmpty, let rootPath else { return }
        safeBatchStep = .running
        safeBatchLines = []
        safeBatchFreed = 0
        let shared = CancelFlag()
        batchStop = shared
        let dryRun = previewOnly
        let trashInstead = movesToTrash
        let root = rootPath
        Task {
            var index = 0
            var running: [Task<Void, Never>] = []
            while index < items.count || !running.isEmpty {
                if shared.isCancelled && running.isEmpty { break }
                while running.count < 3, index < items.count, !shared.isCancelled {
                    let suggestion = items[index]
                    index += 1
                    let flag = CancelFlag()
                    self.cancelFlags[suggestion.id] = flag
                    running.append(Task {
                        await self.runRemoval(
                            suggestion,
                            dryRun: dryRun,
                            trashInstead: trashInstead,
                            rootPath: root,
                            flag: flag,
                            sharedStop: shared
                        )
                    })
                }
                if running.isEmpty { break }
                await running.removeFirst().value
            }
            self.batchStop = nil
            self.safeBatchStep = .summary
        }
    }

    func cancelSafeBatch() {
        batchStop?.cancel()
    }

    private func runRemoval(
        _ suggestion: CleanupSuggestion,
        dryRun: Bool,
        trashInstead: Bool,
        rootPath: String,
        flag: CancelFlag,
        sharedStop: CancelFlag?
    ) async {
        let verb = activityVerb(suggestion, dryRun: dryRun, trashInstead: trashInstead)
        progressStore(for: suggestion.id).activity = .running(verb: verb, freed: 0)
        if !dryRun {
            removedPrefixes.append(contentsOf: suggestion.paths)
            let held = suppressions
            let paths = suggestion.paths
            Task { await held.suppress(paths) }
        }
        let shared = sharedStop
        let performer: MacCleanupPerformer = {
            var performer = MacCleanupPerformer()
            performer.isCancelled = { flag.isCancelled || shared?.isCancelled == true }
            return performer
        }()
        let id = suggestion.id
        let (stream, continuation) = AsyncStream.makeStream(of: UInt64.self)
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
                    isCancelled: { flag.isCancelled || shared?.isCancelled == true }
                )
            }.value
        } catch {
            continuation.finish()
            await pump.value
            finish(suggestion, dryRun: dryRun, rootPath: rootPath, message: error.localizedDescription, success: false, bytes: 0)
            return
        }
        continuation.finish()
        await pump.value
        let message = cardMessage(record, trashInstead: trashInstead)
        finish(
            suggestion,
            dryRun: dryRun,
            rootPath: rootPath,
            message: message,
            success: record.succeeded,
            bytes: record.bytesFreed,
            logRecord: record
        )
        if showingSafeBatch {
            safeBatchLines.append(SafeBatchLine(id: suggestion.id, title: suggestion.headline, message: message, success: record.succeeded))
            if record.succeeded && !record.dryRun {
                safeBatchFreed += record.bytesFreed
            }
        }
    }

    func cancelRow(_ id: String) {
        cancelFlags[id]?.cancel()
    }

    private func noteFreed(_ id: String, _ bytes: UInt64) {
        guard case .running(let verb, _) = cardProgress[id]?.activity else { return }
        cardProgress[id]?.activity = .running(verb: verb, freed: bytes)
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
        progressStore(for: suggestion.id).activity = .finished(message: message, success: success, hideFromEstimate: hide)
        rebuildDisplay()
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

    private static let dayStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)

    private func rebuildDisplay() {
        let visible = report.suggestions.filter { suggestion in
            switch safetyFilter {
            case .all: break
            case .safe: if suggestion.safety != .safe { return false }
            case .review: if suggestion.safety != .review { return false }
            }
            return passesAge(suggestion)
        }
        displayedGroups = CleanupReport.groups(from: visible)
        displayedCount = visible.count
        var displays: [String: CardDisplay] = [:]
        for suggestion in visible {
            let sizeText = suggestion.estimateIsUpperBound
                ? "Up to \(ByteFormat.string(suggestion.size))"
                : ByteFormat.string(suggestion.size)
            let lines = suggestion.items.prefix(8).map { item -> String in
                let name = item.projectName ?? item.path
                let when = item.lastModified.map { $0.formatted(Self.dayStyle) }
                let size = ByteFormat.string(item.bytes)
                if let when { return "\(name)  \(when)  \(size)" }
                return "\(name)  \(size)"
            }
            let count = suggestion.paths.count
            displays[suggestion.id] = CardDisplay(
                sizeText: sizeText,
                lines: lines,
                pathLabel: "\(count) \(count == 1 ? "path" : "paths")"
            )
        }
        cardDisplay = displays
        let actionable = report.suggestions.filter { suggestion in
            guard suggestion.safety == .safe, passesAge(suggestion) else { return false }
            switch cardProgress[suggestion.id]?.activity {
            case .running, .finished(_, true, _):
                return false
            default:
                return true
            }
        }
        safeBatchSuggestions = actionable
        safeBatchBytes = actionable.reduce(0) { $0 + $1.size }
        let amount = ByteFormat.string(safeBatchBytes)
        if previewOnly {
            safeBatchTitle = "Preview all Safe · \(actionable.count) · \(amount)"
        } else if movesToTrash {
            safeBatchTitle = "Move all Safe to Trash · \(actionable.count) · \(amount)"
        } else {
            safeBatchTitle = "Delete all Safe · \(actionable.count) · \(amount)"
        }
    }

}
#endif
