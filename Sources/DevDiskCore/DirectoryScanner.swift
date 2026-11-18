import Foundation

/// Concurrent, cancellable directory walk.
///
/// Allocated size comes from the probe (`st_blocks * 512` on the POSIX probe), not the logical length.
/// Symlinks are recorded and not followed. A second hard link to the same inode contributes no bytes;
/// the lexicographically smallest path keeps the size. Directories on a different device than the
/// scan root are not entered.
public struct DirectoryScanner: Sendable {
    public var fileSystem: any FileSystemProbe
    public var maxConcurrentDirectories: Int

    public init(fileSystem: any FileSystemProbe = POSIXFileSystem(), maxConcurrentDirectories: Int = 16) {
        self.fileSystem = fileSystem
        self.maxConcurrentDirectories = max(1, maxConcurrentDirectories)
    }

    public func scan(
        root: String,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanTree {
        let root = Paths.normalize(root)
        let gate = DirectoryGate(limit: maxConcurrentDirectories)
        let meter = ScanMeter(handler: progress)
        let ledger = InodeLedger()
        return try await withTaskCancellationHandler {
            let raw = try await scanDirectory(
                path: root,
                name: Paths.name(root),
                rootDevice: nil,
                gate: gate,
                meter: meter,
                ledger: ledger
            )
            let tree = finalize(raw)
            await meter.emit()
            return tree
        } onCancel: {
            Task { await gate.cancelAndDrain() }
        }
    }

    /// Progress events followed by the finished tree. Cancelling the consuming task cancels the scan.
    public func events(root: String) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let tree = try await self.scan(root: root) { value in
                        continuation.yield(.progress(value))
                    }
                    continuation.yield(.finished(tree))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func scanDirectory(
        path: String,
        name: String,
        rootDevice: UInt64?,
        gate: DirectoryGate,
        meter: ScanMeter,
        ledger: InodeLedger
    ) async throws -> RawNode {
        try Task.checkCancellation()
        try await gate.acquire()
        let inspected: Inspected
        do {
            inspected = try await inspect(
                path: path,
                name: name,
                rootDevice: rootDevice,
                meter: meter,
                ledger: ledger
            )
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }

        switch inspected {
        case .finished(let node):
            return node
        case .directory(var node, let subdirs, let device):
            try await withThrowingTaskGroup(of: RawNode.self) { group in
                for sub in subdirs {
                    group.addTask {
                        try await scanDirectory(
                            path: sub.path,
                            name: sub.name,
                            rootDevice: device,
                            gate: gate,
                            meter: meter,
                            ledger: ledger
                        )
                    }
                }
                for try await child in group {
                    node.children.append(child)
                }
            }
            return node
        }
    }

    private func inspect(
        path: String,
        name: String,
        rootDevice: UInt64?,
        meter: ScanMeter,
        ledger: InodeLedger
    ) async throws -> Inspected {
        let meta: EntryMetadata
        do {
            meta = try await fileSystem.metadata(at: path)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if rootDevice == nil {
                throw error
            }
            await meter.error(path: path)
            return .finished(RawNode(
                name: name,
                path: path,
                ownAllocated: 0,
                ownLogical: 0,
                pendingLink: nil,
                modified: nil,
                isDirectory: true,
                isSymlink: false,
                isOtherVolume: false,
                errorMessage: (error as? FileSystemError)?.message ?? String(describing: error),
                children: []
            ))
        }

        if meta.isSymlink {
            await meter.file(bytes: meta.allocatedSize, path: path)
            return .finished(RawNode(
                name: name,
                path: path,
                ownAllocated: meta.allocatedSize,
                ownLogical: meta.logicalSize,
                pendingLink: nil,
                modified: meta.modified,
                isDirectory: false,
                isSymlink: true,
                isOtherVolume: false,
                errorMessage: nil,
                children: []
            ))
        }

        if !meta.isDirectory {
            let key = InodeKey(device: meta.device, inode: meta.inode)
            let pending: PendingLink?
            let own: UInt64
            let logical: UInt64
            if meta.linkCount > 1 {
                pending = PendingLink(device: meta.device, inode: meta.inode, allocated: meta.allocatedSize, logical: meta.logicalSize)
                let first = await ledger.insert(key)
                own = 0
                logical = 0
                if first {
                    await meter.file(bytes: meta.allocatedSize, path: path)
                } else {
                    await meter.file(bytes: 0, path: path)
                }
            } else {
                pending = nil
                own = meta.allocatedSize
                logical = meta.logicalSize
                await meter.file(bytes: own, path: path)
            }
            return .finished(RawNode(
                name: name,
                path: path,
                ownAllocated: own,
                ownLogical: logical,
                pendingLink: pending,
                modified: meta.modified,
                isDirectory: false,
                isSymlink: false,
                isOtherVolume: false,
                errorMessage: nil,
                children: []
            ))
        }

        let device = rootDevice ?? meta.device
        if let rootDevice, meta.device != rootDevice {
            await meter.directory(path: path, otherVolume: true)
            await meter.add(bytes: meta.allocatedSize)
            return .finished(RawNode(
                name: name,
                path: path,
                ownAllocated: meta.allocatedSize,
                ownLogical: meta.logicalSize,
                pendingLink: nil,
                modified: meta.modified,
                isDirectory: true,
                isSymlink: false,
                isOtherVolume: true,
                errorMessage: nil,
                children: []
            ))
        }

        let names: [String]
        do {
            names = try await fileSystem.entries(at: path)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await meter.directory(path: path, otherVolume: false)
            await meter.add(bytes: meta.allocatedSize)
            await meter.error(path: path)
            return .finished(RawNode(
                name: name,
                path: path,
                ownAllocated: meta.allocatedSize,
                ownLogical: meta.logicalSize,
                pendingLink: nil,
                modified: meta.modified,
                isDirectory: true,
                isSymlink: false,
                isOtherVolume: false,
                errorMessage: (error as? FileSystemError)?.message ?? String(describing: error),
                children: []
            ))
        }

        await meter.directory(path: path, otherVolume: false)
        await meter.add(bytes: meta.allocatedSize)

        var files: [RawNode] = []
        var subdirs: [(name: String, path: String)] = []
        for childName in names {
            try Task.checkCancellation()
            let childPath = Paths.join(path, childName)
            let childMeta: EntryMetadata
            do {
                childMeta = try await fileSystem.metadata(at: childPath)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await meter.error(path: childPath)
                files.append(RawNode(
                    name: childName,
                    path: childPath,
                    ownAllocated: 0,
                    ownLogical: 0,
                    pendingLink: nil,
                    modified: nil,
                    isDirectory: false,
                    isSymlink: false,
                    isOtherVolume: false,
                    errorMessage: (error as? FileSystemError)?.message ?? String(describing: error),
                    children: []
                ))
                continue
            }

            if childMeta.isSymlink || !childMeta.isDirectory || childMeta.device != device {
                let node = try await leafOrMount(
                    name: childName,
                    path: childPath,
                    meta: childMeta,
                    device: device,
                    meter: meter,
                    ledger: ledger
                )
                files.append(node)
            } else {
                subdirs.append((childName, childPath))
            }
        }

        let directory = RawNode(
            name: name,
            path: path,
            ownAllocated: meta.allocatedSize,
            ownLogical: meta.logicalSize,
            pendingLink: nil,
            modified: meta.modified,
            isDirectory: true,
            isSymlink: false,
            isOtherVolume: false,
            errorMessage: nil,
            children: files
        )
        return .directory(directory, subdirs, device)
    }

    private func leafOrMount(
        name: String,
        path: String,
        meta: EntryMetadata,
        device: UInt64,
        meter: ScanMeter,
        ledger: InodeLedger
    ) async throws -> RawNode {
        if meta.isSymlink {
            await meter.file(bytes: meta.allocatedSize, path: path)
            return RawNode(
                name: name,
                path: path,
                ownAllocated: meta.allocatedSize,
                ownLogical: meta.logicalSize,
                pendingLink: nil,
                modified: meta.modified,
                isDirectory: false,
                isSymlink: true,
                isOtherVolume: false,
                errorMessage: nil,
                children: []
            )
        }
        if meta.isDirectory && meta.device != device {
            await meter.directory(path: path, otherVolume: true)
            await meter.add(bytes: meta.allocatedSize)
            return RawNode(
                name: name,
                path: path,
                ownAllocated: meta.allocatedSize,
                ownLogical: meta.logicalSize,
                pendingLink: nil,
                modified: meta.modified,
                isDirectory: true,
                isSymlink: false,
                isOtherVolume: true,
                errorMessage: nil,
                children: []
            )
        }
        let pending: PendingLink?
        let own: UInt64
        let logical: UInt64
        if meta.linkCount > 1 {
            pending = PendingLink(device: meta.device, inode: meta.inode, allocated: meta.allocatedSize, logical: meta.logicalSize)
            let first = await ledger.insert(InodeKey(device: meta.device, inode: meta.inode))
            own = 0
            logical = 0
            await meter.file(bytes: first ? meta.allocatedSize : 0, path: path)
        } else {
            pending = nil
            own = meta.allocatedSize
            logical = meta.logicalSize
            await meter.file(bytes: own, path: path)
        }
        return RawNode(
            name: name,
            path: path,
            ownAllocated: own,
            ownLogical: logical,
            pendingLink: pending,
            modified: meta.modified,
            isDirectory: false,
            isSymlink: false,
            isOtherVolume: false,
            errorMessage: nil,
            children: []
        )
    }
}

private struct InodeKey: Sendable, Hashable {
    var device: UInt64
    var inode: UInt64
}

private struct PendingLink: Sendable {
    var device: UInt64
    var inode: UInt64
    var allocated: UInt64
    var logical: UInt64
}

private struct RawNode {
    var name: String
    var path: String
    var ownAllocated: UInt64
    var ownLogical: UInt64
    var pendingLink: PendingLink?
    var modified: Date?
    var isDirectory: Bool
    var isSymlink: Bool
    var isOtherVolume: Bool
    var errorMessage: String?
    var children: [RawNode]
    var totalAllocated: UInt64 = 0
    var totalLogical: UInt64 = 0
    var duplicate = false
}

private enum Inspected {
    case finished(RawNode)
    case directory(RawNode, [(name: String, path: String)], UInt64)
}

private actor InodeLedger {
    private var seen: Set<InodeKey> = []

    func insert(_ key: InodeKey) -> Bool {
        seen.insert(key).inserted
    }
}

actor DirectoryGate {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var cancelled = false

    init(limit: Int) {
        permits = max(1, limit)
    }

    func acquire() async throws {
        if cancelled || Task.isCancelled {
            throw CancellationError()
        }
        if permits > 0 {
            permits -= 1
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append(continuation)
            }
        }
        if cancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    func release() {
        if cancelled { return }
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
            return
        }
        permits += 1
    }

    func cancelAndDrain() {
        cancelled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: CancellationError())
        }
    }
}

private actor ScanMeter {
    private var files = 0
    private var directories = 0
    private var bytes: UInt64 = 0
    private var errors = 0
    private var path = ""
    private let handler: (@Sendable (ScanProgress) -> Void)?

    init(handler: (@Sendable (ScanProgress) -> Void)?) {
        self.handler = handler
    }

    func file(bytes added: UInt64, path: String) {
        files += 1
        bytes += added
        self.path = path
        if files % 64 == 0 { emitLocked() }
    }

    func directory(path: String, otherVolume: Bool) {
        directories += 1
        self.path = path
        if otherVolume || directories % 8 == 0 { emitLocked() }
    }

    func add(bytes added: UInt64) {
        bytes += added
    }

    func error(path: String) {
        errors += 1
        self.path = path
        emitLocked()
    }

    func emit() {
        emitLocked()
    }

    private func emitLocked() {
        handler?(ScanProgress(
            visitedFiles: files,
            visitedDirectories: directories,
            allocatedBytes: bytes,
            currentPath: path,
            errorCount: errors
        ))
    }
}

private func finalize(_ root: RawNode) -> ScanTree {
    var root = root
    let winners = linkWinners(root)
    _ = fold(&root, winners: winners)
    var nextID = 1
    let node = assign(&root, next: &nextID)
    return ScanTree(root: node, stats: stats(of: node))
}

private func linkWinners(_ node: RawNode) -> [InodeKey: String] {
    var best: [InodeKey: (path: String, allocated: UInt64)] = [:]
    func walk(_ node: RawNode) {
        if let link = node.pendingLink {
            let key = InodeKey(device: link.device, inode: link.inode)
            if let existing = best[key] {
                if node.path < existing.path {
                    best[key] = (node.path, link.allocated)
                }
            } else {
                best[key] = (node.path, link.allocated)
            }
        }
        for child in node.children { walk(child) }
    }
    walk(node)
    return best.mapValues(\.path)
}

private func fold(_ node: inout RawNode, winners: [InodeKey: String]) -> (UInt64, UInt64) {
    if let link = node.pendingLink {
        let key = InodeKey(device: link.device, inode: link.inode)
        if winners[key] == node.path {
            node.ownAllocated = link.allocated
            node.ownLogical = link.logical
            node.duplicate = false
        } else {
            node.ownAllocated = 0
            node.ownLogical = 0
            node.duplicate = true
        }
    }
    var allocated = node.ownAllocated
    var logical = node.ownLogical
    for index in node.children.indices {
        let child = fold(&node.children[index], winners: winners)
        allocated += child.0
        logical += child.1
    }
    node.totalAllocated = allocated
    node.totalLogical = logical
    node.children.sort { lhs, rhs in
        if lhs.totalAllocated != rhs.totalAllocated { return lhs.totalAllocated > rhs.totalAllocated }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.path < rhs.path
    }
    return (allocated, logical)
}

private func assign(_ node: inout RawNode, next: inout Int) -> ScanNode {
    let id = next
    next += 1
    let children = node.children.indices.map { index in
        assign(&node.children[index], next: &next)
    }
    let kind: FileKind = node.isDirectory ? .folder : FileKind.classify(name: node.name)
    return ScanNode(
        id: id,
        name: node.name,
        path: node.path,
        kind: kind,
        allocatedSize: node.totalAllocated,
        logicalSize: node.totalLogical,
        modified: node.modified,
        isDirectory: node.isDirectory,
        isSymlink: node.isSymlink,
        countsAsDuplicateHardLink: node.duplicate,
        isOtherVolume: node.isOtherVolume,
        errorMessage: node.errorMessage,
        children: children
    )
}

private func stats(of node: ScanNode) -> ScanStats {
    var stats = ScanStats(allocatedBytes: node.allocatedSize)
    func walk(_ node: ScanNode) {
        if let _ = node.errorMessage { stats.errorCount += 1 }
        if node.isOtherVolume { stats.otherVolumeCount += 1 }
        if node.isDirectory {
            stats.directoryCount += 1
            for child in node.children { walk(child) }
            return
        }
        stats.fileCount += 1
        if node.isSymlink { stats.symlinkCount += 1 }
        if node.countsAsDuplicateHardLink { stats.hardLinkDuplicateCount += 1 }
    }
    walk(node)
    return stats
}
