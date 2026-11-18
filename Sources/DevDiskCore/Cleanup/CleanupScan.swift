import Foundation

public enum CleanupScanEvent: Sendable {
    case progress(ScanProgress)
    case suggestion(CleanupSuggestion)
    case finished
}

/// Paths the user has already deleted or chosen to remove. The scan skips them
/// and does not emit another card if it reaches the same place later.
public actor CleanupSuppressions {
    private var prefixes: [String] = []

    public init() {}

    public func release(_ paths: [String]) {
        let dropping = Set(paths.map(Paths.normalize))
        prefixes.removeAll { dropping.contains($0) }
    }

    public func suppress(_ paths: [String]) {
        for path in paths {
            let normalized = Paths.normalize(path)
            if !prefixes.contains(normalized) {
                prefixes.append(normalized)
            }
        }
    }

    public func isSuppressed(_ path: String) -> Bool {
        let path = Paths.normalize(path)
        for prefix in prefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return true
        }
        return false
    }
}

/// Live age threshold. The cleanup screen can change it while a scan is running.
public actor CleanupScanSettings {
    public var staleAfterDays: Int

    public init(staleAfterDays: Int) {
        self.staleAfterDays = max(0, staleAfterDays)
    }

    public func days() -> Int { staleAfterDays }

    public func update(days: Int) {
        staleAfterDays = max(0, days)
    }
}

/// Finds developer cleanup targets without building a full file tree.
///
/// Known cache paths are measured first. The walk lists directories and does not
/// stat every source file. Matched artefact folders (`node_modules`, `.git`,
/// `target`, `.build`, `.venv`, …) are not entered; a separate concurrent pass
/// sums their allocated size. Folders that cannot hold projects (`Library`,
/// photos, media) are skipped because those caches were already probed by path.
/// The Explore treemap stays on `DirectoryScanner`.
public struct CleanupScanner: Sendable {
    public var fileSystem: any FileSystemProbe
    public var maxConcurrent: Int
    public var stop: ScanStop

    public init(fileSystem: any FileSystemProbe = POSIXFileSystem(), maxConcurrent: Int = 32, stop: ScanStop = ScanStop()) {
        self.fileSystem = fileSystem
        self.maxConcurrent = max(1, maxConcurrent)
        self.stop = stop
    }

    public func events(
        root: String,
        rules: [RuleSpec] = CleanupCatalog.all,
        now: Date = Date(),
        byteFloor: UInt64? = nil,
        staleAfterDays: Int = CleanupCatalog.defaultStaleDays,
        settings: CleanupScanSettings? = nil,
        suppressions: CleanupSuppressions = CleanupSuppressions()
    ) -> AsyncThrowingStream<CleanupScanEvent, Error> {
        let root = Paths.normalize(root)
        let settings = settings ?? CleanupScanSettings(staleAfterDays: staleAfterDays)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let gate = DirectoryGate(limit: maxConcurrent)
                let meter = CleanupMeter(startedAt: now) { progress in
                    continuation.yield(CleanupScanEvent.progress(progress))
                }
                let claims = CleanupClaims()
                do {
                    try await withTaskCancellationHandler {
                    let rootMeta = try await fileSystem.metadata(at: root)
                    guard rootMeta.isDirectory else {
                        continuation.finish(throwing: FileSystemError.io(path: root, errno: 0))
                        return
                    }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            await self.probeKnownPaths(
                                root: root,
                                device: rootMeta.device,
                                rules: rules,
                                now: now,
                                byteFloor: byteFloor,
                                settings: settings,
                                suppressions: suppressions,
                                claims: claims,
                                gate: gate,
                                meter: meter,
                                yield: { continuation.yield(.suggestion($0)) }
                            )
                        }
                        group.addTask {
                            try await self.walk(
                                path: root,
                                root: root,
                                device: rootMeta.device,
                                rules: rules,
                                now: now,
                                byteFloor: byteFloor,
                                settings: settings,
                                suppressions: suppressions,
                                claims: claims,
                                gate: gate,
                                meter: meter,
                                yield: { continuation.yield(.suggestion($0)) }
                            )
                        }
                        try await group.waitForAll()
                    }
                    continuation.yield(.progress(await meter.snapshot(path: root)))
                    continuation.yield(.finished)
                    continuation.finish()
                    } onCancel: {
                        self.stop.stop()
                        Task { await gate.cancelAndDrain() }
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let stop = self.stop
            continuation.onTermination = { _ in
                stop.stop()
                task.cancel()
            }
        }
    }

    private func probeKnownPaths(
        root: String,
        device: UInt64,
        rules: [RuleSpec],
        now: Date,
        byteFloor: UInt64?,
        settings: CleanupScanSettings,
        suppressions: CleanupSuppressions,
        claims: CleanupClaims,
        gate: DirectoryGate,
        meter: CleanupMeter,
        yield: @escaping @Sendable (CleanupSuggestion) -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for rule in rules {
                guard case .relativeDirectories(let relatives) = rule.locator else { continue }
                for relative in relatives {
                    let path = Paths.join(root, relative)
                    group.addTask {
                        await self.measureDirectory(
                            rule: rule,
                            path: path,
                            projectName: nil,
                            modified: nil,
                            device: device,
                            root: root,
                            now: now,
                            byteFloor: byteFloor,
                            settings: settings,
                            suppressions: suppressions,
                            claims: claims,
                            gate: gate,
                            meter: meter,
                            yield: yield
                        )
                    }
                }
            }
        }
    }

    private func walk(
        path: String,
        root: String,
        device: UInt64,
        rules: [RuleSpec],
        now: Date,
        byteFloor: UInt64?,
        settings: CleanupScanSettings,
        suppressions: CleanupSuppressions,
        claims: CleanupClaims,
        gate: DirectoryGate,
        meter: CleanupMeter,
        yield: @escaping @Sendable (CleanupSuggestion) -> Void
    ) async throws {
        try stop.check()
        let suppressed = await suppressions.isSuppressed(path)
        let claimed = await claims.isClaimed(path)
        if suppressed || claimed { return }
        await meter.directory(path)
        let listed: [ListedEntry]
        do {
            listed = try await fileSystem.listing(at: path)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return
        }
        let parentModified = try? await fileSystem.metadata(at: path).modified
        let names = Set(listed.map(\.name))
        if await emitMarkedDirectory(
            path: path,
            names: names,
            modified: parentModified,
            device: device,
            root: root,
            rules: rules,
            now: now,
            byteFloor: byteFloor,
            settings: settings,
            suppressions: suppressions,
            claims: claims,
            gate: gate,
            meter: meter,
            yield: yield
        ) {
            return
        }
        for entry in listed {
            try stop.check()
            let child = Paths.join(path, entry.name)
            if await suppressions.isSuppressed(child) { continue }
            let kind = try await resolvedKind(entry, at: child)
            switch kind {
            case .directory:
                if skipDirectory(name: entry.name, path: child, root: root) { continue }
                if let suffixRule = suffixRule(for: child, rules: rules) {
                    let days = await settings.days()
                    if case .directoriesEndingWith(_, let age) = suffixRule.locator,
                       age == .olderThanThreshold && !ageMatches(parentModified, now: now, days: days) {
                        continue
                    }
                    let anchor = suffixRule.projectAnchor == .grandparent ? Paths.parent(path) : path
                    await measureDirectory(
                        rule: suffixRule,
                        path: child,
                        projectName: Paths.name(anchor),
                        modified: parentModified,
                        device: device,
                        root: root,
                        now: now,
                        byteFloor: byteFloor,
                        settings: settings,
                        suppressions: suppressions,
                        claims: claims,
                        gate: gate,
                        meter: meter,
                        yield: yield
                    )
                    continue
                }
                if pruneDirectory(name: entry.name, siblings: names) {
                    await matchPrunedDirectory(
                        name: entry.name,
                        path: child,
                        parentModified: parentModified,
                        siblings: names,
                        device: device,
                        root: root,
                        rules: rules,
                        now: now,
                        byteFloor: byteFloor,
                        settings: settings,
                        suppressions: suppressions,
                        claims: claims,
                        gate: gate,
                        meter: meter,
                        yield: yield
                    )
                    continue
                }
                try await walk(
                    path: child,
                    root: root,
                    device: device,
                    rules: rules,
                    now: now,
                    byteFloor: byteFloor,
                    settings: settings,
                    suppressions: suppressions,
                    claims: claims,
                    gate: gate,
                    meter: meter,
                    yield: yield
                )
            case .file:
                await matchFile(
                    name: entry.name,
                    path: child,
                    root: root,
                    now: now,
                    byteFloor: byteFloor,
                    settings: settings,
                    suppressions: suppressions,
                    claims: claims,
                    rules: rules,
                    meter: meter,
                    yield: yield
                )
            case .symlink, .other, .unknown:
                continue
            }
        }
    }

    private func emitMarkedDirectory(
        path: String,
        names: Set<String>,
        modified: Date?,
        device: UInt64,
        root: String,
        rules: [RuleSpec],
        now: Date,
        byteFloor: UInt64?,
        settings: CleanupScanSettings,
        suppressions: CleanupSuppressions,
        claims: CleanupClaims,
        gate: DirectoryGate,
        meter: CleanupMeter,
        yield: @escaping @Sendable (CleanupSuggestion) -> Void
    ) async -> Bool {
        let days = await settings.days()
        for rule in rules {
            guard case .directoriesContainingFile(let marker, let age) = rule.locator else { continue }
            guard names.contains(marker) else { continue }
            if age == .olderThanThreshold && !ageMatches(modified, now: now, days: days) { continue }
            await measureDirectory(
                rule: rule,
                path: path,
                projectName: Paths.name(Paths.parent(path)),
                modified: modified,
                device: device,
                root: root,
                now: now,
                byteFloor: byteFloor,
                settings: settings,
                suppressions: suppressions,
                claims: claims,
                gate: gate,
                meter: meter,
                yield: yield
            )
            return true
        }
        return false
    }

    private func matchPrunedDirectory(
        name: String,
        path: String,
        parentModified: Date?,
        siblings: Set<String>,
        device: UInt64,
        root: String,
        rules: [RuleSpec],
        now: Date,
        byteFloor: UInt64?,
        settings: CleanupScanSettings,
        suppressions: CleanupSuppressions,
        claims: CleanupClaims,
        gate: DirectoryGate,
        meter: CleanupMeter,
        yield: @escaping @Sendable (CleanupSuggestion) -> Void
    ) async {
        let days = await settings.days()
        for rule in rules {
            switch rule.locator {
            case .directoriesNamed(let names, let age, let sibling, let siblingExtension):
                guard names.contains(name) else { continue }
                if let sibling, !siblings.contains(sibling) { continue }
                if let siblingExtension, !siblings.contains(where: { FileKind.extensionOf($0) == siblingExtension }) { continue }
                if age == .olderThanThreshold && !ageMatches(parentModified, now: now, days: days) { continue }
                await measureDirectory(
                    rule: rule,
                    path: path,
                    projectName: Paths.name(Paths.parent(path)),
                    modified: parentModified,
                    device: device,
                    root: root,
                    now: now,
                    byteFloor: byteFloor,
                    settings: settings,
                    suppressions: suppressions,
                    claims: claims,
                    gate: gate,
                    meter: meter,
                    yield: yield
                )
                return
            case .directoriesEndingWith:
                continue
            default:
                continue
            }
        }
    }

    private func suffixRule(for path: String, rules: [RuleSpec]) -> RuleSpec? {
        for rule in rules {
            guard case .directoriesEndingWith(let suffix, _) = rule.locator else { continue }
            if path.hasSuffix("/" + suffix) { return rule }
        }
        return nil
    }

    private func matchFile(
        name: String,
        path: String,
        root: String,
        now: Date,
        byteFloor: UInt64?,
        settings: CleanupScanSettings,
        suppressions: CleanupSuppressions,
        claims: CleanupClaims,
        rules: [RuleSpec],
        meter: CleanupMeter,
        yield: @escaping @Sendable (CleanupSuggestion) -> Void
    ) async {
        let suppressed = await suppressions.isSuppressed(path)
        let claimed = await claims.isClaimed(path)
        if suppressed || claimed { return }
        let meta: EntryMetadata
        do {
            meta = try await fileSystem.metadata(at: path)
        } catch {
            return
        }
        await meter.file(bytes: meta.allocatedSize, path: path)
        let days = await settings.days()
        for rule in rules {
            guard case .files(_, let names, let extensions, let largerThan, let age) = rule.locator else { continue }
            let minimum = byteFloor ?? largerThan
            if meta.allocatedSize < minimum { continue }
            let ext = FileKind.extensionOf(name)
            let nameOK = !names.isEmpty && names.contains(name)
            let extOK = !extensions.isEmpty && extensions.contains(ext)
            let any = names.isEmpty && extensions.isEmpty
            guard any || nameOK || extOK else { continue }
            if age == .olderThanThreshold && !ageMatches(meta.modified, now: now, days: days) { continue }
            if PathSafety.violation(for: path, scanRoot: root) != nil { continue }
            guard await claims.claim(path) else { continue }
            let floor = byteFloor ?? rule.minimumBytes
            if meta.allocatedSize < floor { continue }
            let suggestion = makeSuggestion(
                rule: rule,
                path: path,
                bytes: meta.allocatedSize,
                projectName: Paths.name(Paths.parent(path)),
                modified: meta.modified,
                days: days
            )
            await meter.suggestion(bytes: suggestion.countsTowardEstimate ? suggestion.size : 0)
            yield(suggestion)
            return
        }
    }

    private func measureDirectory(
        rule: RuleSpec,
        path: String,
        projectName: String?,
        modified: Date?,
        device: UInt64,
        root: String,
        now: Date,
        byteFloor: UInt64?,
        settings: CleanupScanSettings,
        suppressions: CleanupSuppressions,
        claims: CleanupClaims,
        gate: DirectoryGate,
        meter: CleanupMeter,
        yield: @escaping @Sendable (CleanupSuggestion) -> Void
    ) async {
        if stop.isStopped || Task.isCancelled { return }
        if await suppressions.isSuppressed(path) { return }
        if PathSafety.violation(for: path, scanRoot: root) != nil { return }
        guard await claims.claim(path) else { return }
        let meta: EntryMetadata
        do {
            meta = try await fileSystem.metadata(at: path)
        } catch {
            return
        }
        guard meta.isDirectory, !meta.isSymlink else { return }
        if meta.device != device && device != 0 { return }
        let size = await DirectorySizer(fileSystem: fileSystem, gate: gate, meter: meter, stop: stop).allocatedSize(of: path, device: meta.device)
        if await suppressions.isSuppressed(path) { return }
        let floor = byteFloor ?? rule.minimumBytes
        guard size >= floor else { return }
        let days = await settings.days()
        let suggestion = makeSuggestion(
            rule: rule,
            path: path,
            bytes: size,
            projectName: projectName,
            modified: modified,
            days: days
        )
        await meter.suggestion(bytes: suggestion.countsTowardEstimate ? suggestion.size : 0)
        yield(suggestion)
    }

    private func resolvedKind(_ entry: ListedEntry, at path: String) async throws -> ListedKind {
        if entry.kind != .unknown { return entry.kind }
        do {
            let meta = try await fileSystem.metadata(at: path)
            if meta.isSymlink { return .symlink }
            return meta.isDirectory ? .directory : .file
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unknown
        }
    }

    private func skipDirectory(name: String, path: String, root: String) -> Bool {
        if name.hasSuffix(".photoslibrary") { return true }
        let relative = relativePath(path, root: root)
        let first = relative.split(separator: "/").first.map(String.init) ?? relative
        return CleanupScanner.skippedRootNames.contains(first)
    }

    private func pruneDirectory(name: String, siblings: Set<String>) -> Bool {
        if CleanupScanner.alwaysPruned.contains(name) { return true }
        if name == "target" && siblings.contains("Cargo.toml") { return true }
        if name == ".build" && siblings.contains("Package.swift") { return true }
        if name == "dist" && siblings.contains("package.json") { return true }
        if name == ".terraform" && siblings.contains(where: { FileKind.extensionOf($0) == "tf" }) { return true }
        if name == "cache" && siblings.isEmpty == false {
            // vendor/cache is detected by suffix in matchPrunedDirectory; pruning every cache is too broad.
        }
        return false
    }

    private func relativePath(_ path: String, root: String) -> String {
        let path = Paths.normalize(path)
        let root = Paths.normalize(root)
        guard path.hasPrefix(root + "/") else { return "" }
        return String(path.dropFirst(root.count + 1))
    }

    private func ageMatches(_ modified: Date?, now: Date, days: Int) -> Bool {
        guard let modified else { return days == 0 }
        return now.timeIntervalSince(modified) >= Double(days) * 86_400
    }

    private func makeSuggestion(
        rule: RuleSpec,
        path: String,
        bytes: UInt64,
        projectName: String?,
        modified: Date?,
        days: Int
    ) -> CleanupSuggestion {
        let item = CleanupPath(path: path, bytes: bytes, projectName: projectName, lastModified: modified)
        return CleanupSuggestion(
            id: "\(rule.id)\u{1f}\(path)",
            ruleID: rule.id,
            name: rule.name,
            summary: rule.summary,
            ecosystem: rule.ecosystem,
            safety: rule.safety,
            items: [item],
            headline: headline(name: rule.name, count: 1, size: bytes, phrasing: rule.phrasing, days: days),
            actionDescription: actionDescription(effect: rule.effect, count: 1),
            effect: rule.effect,
            countsTowardEstimate: rule.countsTowardEstimate,
            estimateIsUpperBound: rule.estimateIsUpperBound
        )
    }

    /// Top-level folders that do not contain source projects. Known caches inside
    /// `Library` are measured by their fixed paths before the walk.
    static let skippedRootNames: Set<String> = [
        "Library", "Pictures", "Movies", "Music", "Public", "Applications", ".Trash", ".Trashes",
    ]

    static let alwaysPruned: Set<String> = [
        "node_modules", ".git", ".venv", "venv", "__pycache__", "DerivedData",
        ".next", ".nuxt", ".turbo", ".parcel-cache", "Pods",
    ]
}

private struct DirectorySizer: Sendable {
    var fileSystem: any FileSystemProbe
    var gate: DirectoryGate
    var meter: CleanupMeter
    var stop: ScanStop

    func allocatedSize(of path: String, device: UInt64) async -> UInt64 {
        await size(path, device: device, isRoot: true)
    }

    private func size(_ path: String, device: UInt64, isRoot: Bool) async -> UInt64 {
        if stop.isStopped || Task.isCancelled { return 0 }
        let meta: EntryMetadata
        do {
            try await gate.acquire()
            do {
                meta = try await fileSystem.metadata(at: path)
                await gate.release()
            } catch {
                await gate.release()
                throw error
            }
        } catch is CancellationError {
            return 0
        } catch {
            return 0
        }
        if meta.isSymlink {
            await meter.file(bytes: meta.allocatedSize, path: path)
            return meta.allocatedSize
        }
        if !meta.isDirectory {
            await meter.file(bytes: meta.allocatedSize, path: path)
            return meta.allocatedSize
        }
        if !isRoot && meta.device != device {
            return meta.allocatedSize
        }
        let total = meta.allocatedSize
        let listed: [ListedEntry]
        do {
            listed = try await fileSystem.listing(at: path)
        } catch {
            return total
        }
        await meter.directory(path)
        var childSum: UInt64 = 0
        await withTaskGroup(of: UInt64.self) { group in
            for entry in listed {
                if stop.isStopped || Task.isCancelled {
                    group.cancelAll()
                    break
                }
                let child = Paths.join(path, entry.name)
                group.addTask {
                    await self.size(child, device: device, isRoot: false)
                }
            }
            for await part in group {
                childSum += part
            }
        }
        return total + childSum
    }
}

private actor CleanupClaims {
    private var prefixes: [String] = []

    func claim(_ path: String) -> Bool {
        let path = Paths.normalize(path)
        if isClaimed(path) { return false }
        prefixes.append(path)
        return true
    }

    func isClaimed(_ path: String) -> Bool {
        let path = Paths.normalize(path)
        for prefix in prefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return true
        }
        return false
    }
}

private actor CleanupMeter {
    private var files = 0
    private var directories = 0
    private var bytes: UInt64 = 0
    private var suggestions = 0
    private var reclaimable: UInt64 = 0
    private var currentPath = ""
    private let startedAt: Date
    private let yield: @Sendable (ScanProgress) -> Void

    init(startedAt: Date, yield: @escaping @Sendable (ScanProgress) -> Void) {
        self.startedAt = startedAt
        self.yield = yield
    }

    func directory(_ path: String) {
        directories += 1
        currentPath = path
        if directories % 8 == 0 { emit() }
    }

    func file(bytes added: UInt64, path: String) {
        files += 1
        bytes += added
        currentPath = path
        if files % 64 == 0 { emit() }
    }

    func suggestion(bytes added: UInt64) {
        suggestions += 1
        reclaimable += added
        emit()
    }

    func snapshot(path: String) -> ScanProgress {
        currentPath = path
        return progress()
    }

    private func emit() {
        yield(progress())
    }

    private func progress() -> ScanProgress {
        ScanProgress(
            visitedFiles: files,
            visitedDirectories: directories,
            allocatedBytes: bytes,
            currentPath: currentPath,
            suggestionsFound: suggestions,
            reclaimableBytes: reclaimable,
            startedAt: startedAt
        )
    }
}
