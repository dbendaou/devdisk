import Foundation
import Testing
@testable import DevDiskCore

struct CleanupScanTests {
    @Test func knownCachesAppearBeforeTheRestOfTheWalk() async throws {
        let fs = BlockingFileSystem()
        await fs.addDirectory("/home", children: [".npm", "Desktop"])
        await fs.addDirectory("/home/.npm", children: ["cache.bin"])
        await fs.addFile("/home/.npm/cache.bin", bytes: 4_000, modified: nil)
        await fs.addDirectory("/home/Desktop", children: ["project"])
        await fs.blockListing("/home/Desktop")
        let scanner = CleanupScanner(fileSystem: fs, maxConcurrent: 4)
        let stream = scanner.events(root: "/home", byteFloor: 1, staleAfterDays: 0)
        let watcher = Task { () -> Bool in
            for try await event in stream {
                if case .suggestion(let suggestion) = event, suggestion.ruleID == "npm-cache" {
                    return true
                }
                if case .finished = event { return false }
            }
            return false
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            watcher.cancel()
        }
        let sawCache = (try? await watcher.value) ?? false
        timeout.cancel()
        await fs.unblock("/home/Desktop")
        #expect(sawCache)
    }

    @Test func walkSkipsLibraryAndDoesNotNeedEverySourceFile() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-90 * 86_400)
        let fs = BlockingFileSystem()
        await fs.addDirectory("/home", children: ["Library", "Projects"])
        await fs.addDirectory("/home/Library", children: ["Mail", "Caches"])
        await fs.addDirectory("/home/Library/Mail", children: ["huge.log"])
        await fs.addFile("/home/Library/Mail/huge.log", bytes: 9_000_000, modified: old)
        await fs.addDirectory("/home/Library/Caches", children: ["JetBrains"])
        await fs.addDirectory("/home/Library/Caches/JetBrains", children: ["blob"])
        await fs.addFile("/home/Library/Caches/JetBrains/blob", bytes: 8_000, modified: nil)
        await fs.addDirectory("/home/Projects", children: ["app"])
        await fs.addDirectory("/home/Projects/app", children: ["package.json", "node_modules", "debug.log"], modified: old)
        await fs.addFile("/home/Projects/app/package.json", bytes: 20, modified: old)
        await fs.addFile("/home/Projects/app/debug.log", bytes: 6_000_000, modified: old)
        await fs.addDirectory("/home/Projects/app/node_modules", children: ["pkg"])
        await fs.addDirectory("/home/Projects/app/node_modules/pkg", children: ["index.js"])
        await fs.addFile("/home/Projects/app/node_modules/pkg/index.js", bytes: 3_000, modified: old)

        let suggestions = try await collect(fs, now: now, days: 30)
        let ids = Set(suggestions.map(\.ruleID))
        #expect(ids.contains("cache-jetbrains"))
        #expect(ids.contains("node-modules"))
        #expect(ids.contains("project-logs"))
        #expect(!suggestions.contains { $0.paths.contains { $0.contains("/Library/Mail") } })
        let listed = await fs.listedPaths
        #expect(!listed.contains("/home/Library/Mail"))
        let modules = try #require(suggestions.first { $0.ruleID == "node-modules" })
        #expect(modules.items.first?.projectName == "app")
        #expect(modules.size >= 3_000)
        #expect(modules.effect == .removePermanently)
    }

    @Test func suppressedPathIsNotReportedAndAVanishedDirectoryDoesNotFailTheScan() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-90 * 86_400)
        let fs = BlockingFileSystem()
        await fs.addDirectory("/home", children: ["Projects", ".npm"])
        await fs.addDirectory("/home/.npm", children: ["a"])
        await fs.addFile("/home/.npm/a", bytes: 2_000, modified: nil)
        await fs.addDirectory("/home/Projects", children: ["app"])
        await fs.addDirectory("/home/Projects/app", children: ["package.json", "node_modules"], modified: old)
        await fs.addFile("/home/Projects/app/package.json", bytes: 10, modified: old)
        await fs.addDirectory("/home/Projects/app/node_modules", children: ["gone"])
        await fs.addFile("/home/Projects/app/node_modules/gone", bytes: 5_000, modified: old)
        await fs.vanishOnList("/home/Projects/app/node_modules")

        let suppressions = CleanupSuppressions()
        await suppressions.suppress(["/home/.npm"])
        let suggestions = try await collect(fs, now: now, days: 30, suppressions: suppressions)
        #expect(!suggestions.contains { $0.ruleID == "npm-cache" })
        #expect(suggestions.contains { $0.ruleID == "node-modules" })
    }

    @Test func removingASuggestionUpdatesTheRunningTotal() {
        let first = CleanupSuggestion(
            id: "a", ruleID: "node-modules", name: "Stale node_modules", summary: "deps",
            ecosystem: .javascript, safety: .safe,
            items: [CleanupPath(path: "/home/app/node_modules", bytes: 5_000, projectName: "app", lastModified: .distantPast)],
            headline: "one", actionDescription: "Delete 1 path permanently",
            effect: .removePermanently, countsTowardEstimate: true
        )
        let second = CleanupSuggestion(
            id: "b", ruleID: "cache-jetbrains", name: "JetBrains caches", summary: "ide",
            ecosystem: .editors, safety: .safe,
            items: [CleanupPath(path: "/home/Library/Caches/JetBrains", bytes: 9_000)],
            headline: "two", actionDescription: "Delete 1 path permanently",
            effect: .removePermanently, countsTowardEstimate: true
        )
        let report = CleanupReport.summarizing([first, second])
        #expect(report.estimatedReclaimableBytes == 14_000)
        let remaining = report.removing(id: "a")
        #expect(remaining.suggestions.map(\.id) == ["b"])
        #expect(remaining.estimatedReclaimableBytes == 9_000)
    }

    @Test func permanentDeleteIsTheDefaultAndReviewNeedsExtraConfirmation() async throws {
        let modules = try #require(CleanupCatalog.all.first { $0.id == "node-modules" })
        #expect(modules.effect == .removePermanently)
        let databases = CleanupCatalog.all.filter { $0.ecosystem == .databases }
        #expect(databases.allSatisfy { $0.safety == .review && $0.effect == .removePermanently })

        let suggestion = CleanupSuggestion(
            id: "db", ruleID: "postgres-data", name: "Postgres data directories", summary: "data",
            ecosystem: .databases, safety: .review,
            items: [CleanupPath(path: "/home/db", bytes: 100)],
            headline: "Postgres", actionDescription: "Delete 1 path permanently",
            effect: .removePermanently, countsTowardEstimate: true
        )
        let copy = ConfirmationBuilder.make(suggestion, dryRun: false)
        #expect(copy.confirmTitle == "Delete permanently")
        #expect(copy.detail.contains("can't be undone"))
        #expect(copy.requiresExtraAcknowledgement)

        let performer = RecordingPerformer()
        let record = try await CleanupExecutor(performer: performer).execute(suggestion, scanRoot: "/home", dryRun: false)
        #expect(performer.deleted == ["/home/db"])
        #expect(performer.trashed.isEmpty)
        #expect(record.message.contains("permanently"))

        _ = try await CleanupExecutor(performer: performer).execute(suggestion, scanRoot: "/home", dryRun: false, trashInstead: true)
        #expect(performer.trashed == ["/home/db"])
    }
}

private func collect(
    _ fs: BlockingFileSystem,
    now: Date,
    days: Int,
    suppressions: CleanupSuppressions = CleanupSuppressions()
) async throws -> [CleanupSuggestion] {
    let scanner = CleanupScanner(fileSystem: fs, maxConcurrent: 4)
    var found: [CleanupSuggestion] = []
    for try await event in scanner.events(root: "/home", now: now, byteFloor: 1, staleAfterDays: days, suppressions: suppressions) {
        if case .suggestion(let suggestion) = event {
            found.append(suggestion)
        }
    }
    return found
}

private actor BlockingFileSystem: FileSystemProbe {
    private var nodes: [String: EntryMetadata] = [:]
    private var children: [String: [String]] = [:]
    private var blocked: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var vanish: Set<String> = []
    private(set) var listedPaths: Set<String> = []

    func addDirectory(_ path: String, children names: [String], modified: Date? = nil) {
        nodes[path] = EntryMetadata(
            isDirectory: true, isSymlink: false, allocatedSize: 512, logicalSize: 512,
            device: 1, inode: UInt64(bitPattern: Int64(path.hashValue)), linkCount: 1, modified: modified
        )
        children[path] = names
    }

    func addFile(_ path: String, bytes: UInt64, modified: Date?) {
        nodes[path] = EntryMetadata(
            isDirectory: false, isSymlink: false, allocatedSize: bytes, logicalSize: bytes,
            device: 1, inode: UInt64(bitPattern: Int64(path.hashValue)), linkCount: 1, modified: modified
        )
    }

    func blockListing(_ path: String) {
        blocked.insert(path)
    }

    func unblock(_ path: String) {
        blocked.remove(path)
        let pending = waiters.removeValue(forKey: path) ?? []
        for waiter in pending { waiter.resume() }
    }

    func vanishOnList(_ path: String) {
        vanish.insert(path)
    }

    func entries(at path: String) async throws -> [String] {
        try await listing(at: path).map(\.name)
    }

    func listing(at path: String) async throws -> [ListedEntry] {
        if blocked.contains(path) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if blocked.contains(path) {
                    waiters[path, default: []].append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
        listedPaths.insert(path)
        if vanish.contains(path) {
            children[path] = []
        }
        guard let names = children[path] else { throw FileSystemError.notFound(path) }
        return names.map { name in
            let child = path == "/" ? "/\(name)" : path + "/" + name
            let kind: ListedKind = nodes[child]?.isDirectory == true ? .directory : (nodes[child] == nil ? .unknown : .file)
            return ListedEntry(name: name, kind: kind)
        }
    }

    func metadata(at path: String) async throws -> EntryMetadata {
        guard let meta = nodes[path] else { throw FileSystemError.notFound(path) }
        return meta
    }
}
