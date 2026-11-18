import Foundation
import Testing
@testable import DevDiskCore

struct ScannerTests {
    @Test func allocatedSizeIgnoresSparseHoles() async throws {
        let root = try makeTemp()
        defer { remove(root) }
        let sparse = root.appendingPathComponent("sparse.bin")
        try Data().write(to: sparse)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 5_000_000)
        try handle.close()
        let small = root.appendingPathComponent("small.txt")
        let payload = Data("hello world this is a small file".utf8)
        try payload.write(to: small)

        let tree = try await DirectoryScanner().scan(root: root.path)
        let sparseNode = try #require(tree.root.node(atPath: sparse.path))
        let smallNode = try #require(tree.root.node(atPath: small.path))
        #expect(sparseNode.logicalSize == 5_000_000)
        #expect(sparseNode.allocatedSize < sparseNode.logicalSize)
        #expect(smallNode.logicalSize == UInt64(payload.count))
        #expect(smallNode.allocatedSize > 0)
        #expect(smallNode.allocatedSize % 512 == 0)
        #expect(smallNode.allocatedSize >= UInt64(payload.count) || smallNode.allocatedSize == 4096)
    }

    @Test func symlinksAreNotFollowed() async throws {
        let root = try makeTemp()
        defer { remove(root) }
        let outside = try makeTemp()
        defer { remove(outside) }
        let big = outside.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 200_000).write(to: big)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.bin"),
            withDestinationURL: big
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linkdir"),
            withDestinationURL: outside
        )

        let tree = try await DirectoryScanner().scan(root: root.path)
        let link = try #require(tree.root.children.first { $0.name == "link.bin" })
        let linkdir = try #require(tree.root.children.first { $0.name == "linkdir" })
        #expect(link.isSymlink)
        #expect(linkdir.isSymlink)
        #expect(linkdir.children.isEmpty)
        #expect(tree.root.allocatedSize < 100_000)
        #expect(tree.stats.symlinkCount == 2)
    }

    @Test func hardLinksAreCountedOnceOnTheFirstPath() async throws {
        let root = try makeTemp()
        defer { remove(root) }
        let original = root.appendingPathComponent("a.bin")
        let alias = root.appendingPathComponent("b.bin")
        try Data(repeating: 3, count: 50_000).write(to: original)
        try FileManager.default.linkItem(at: original, to: alias)

        let tree = try await DirectoryScanner().scan(root: root.path)
        let first = try #require(tree.root.node(atPath: original.path))
        let second = try #require(tree.root.node(atPath: alias.path))
        #expect(first.allocatedSize > 0)
        #expect(second.allocatedSize == 0)
        #expect(second.countsAsDuplicateHardLink)
        #expect(!first.countsAsDuplicateHardLink)
        #expect(tree.stats.hardLinkDuplicateCount == 1)
        #expect(tree.root.allocatedSize < first.allocatedSize * 2)
    }

    @Test func permissionErrorsAreRecorded() async throws {
        let root = try makeTemp()
        defer { remove(root) }
        let secret = root.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: secret.appendingPathComponent("note.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secret.path) }

        let tree = try await DirectoryScanner().scan(root: root.path)
        let node = try #require(tree.root.node(atPath: secret.path))
        #expect(node.errorMessage?.contains("Permission") == true)
        #expect(node.children.isEmpty)
        #expect(tree.stats.errorCount >= 1)
    }

    @Test func missingRootThrows() async {
        let missing = "/tmp/devdisk-missing-\(UUID().uuidString)"
        do {
            _ = try await DirectoryScanner().scan(root: missing)
            Issue.record("Expected the missing root to throw")
        } catch let error as FileSystemError {
            if case .notFound = error {} else { Issue.record("Unexpected \(error)") }
        } catch {
            Issue.record("Unexpected \(error)")
        }
    }

    @Test func concurrentScansAgree() async throws {
        let root = try makeTemp()
        defer { remove(root) }
        for index in 0..<12 {
            let dir = root.appendingPathComponent("dir-\(index)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<4 {
                try Data(repeating: UInt8(file), count: 1024).write(to: dir.appendingPathComponent("f-\(file).dat"))
            }
        }
        let serial = try await DirectoryScanner(maxConcurrentDirectories: 1).scan(root: root.path)
        let parallel = try await DirectoryScanner(maxConcurrentDirectories: 8).scan(root: root.path)
        #expect(serial.root.allocatedSize == parallel.root.allocatedSize)
        #expect(serial.stats.fileCount == parallel.stats.fileCount)
        #expect(Set(paths(serial.root)) == Set(paths(parallel.root)))
    }

    @Test func doesNotEnterAnotherVolume() async throws {
        let other = "/vol/other"
        var fs = MemoryFileSystem(nodes: [
            "/vol": meta(directory: true, device: 1, allocated: 4096),
            other: meta(directory: true, device: 2, allocated: 4096),
            "/vol/other/huge.bin": meta(directory: false, device: 2, allocated: 9_000_000),
            "/vol/local.bin": meta(directory: false, device: 1, allocated: 1000),
        ], children: [
            "/vol": ["other", "local.bin"],
            other: ["huge.bin"],
        ])
        fs.forbidEntries.insert(other)
        let tree = try await DirectoryScanner(fileSystem: fs, maxConcurrentDirectories: 2).scan(root: "/vol")
        let mount = try #require(tree.root.node(atPath: other))
        #expect(mount.isOtherVolume)
        #expect(mount.children.isEmpty)
        #expect(tree.root.allocatedSize == 4096 + 4096 + 1000)
        #expect(tree.stats.otherVolumeCount == 1)
    }

    @Test func cancellationStopsTheWalk() async throws {
        let fs = MemoryFileSystem(nodes: [
            "/hang": meta(directory: true, device: 1, allocated: 4096),
        ], children: [
            "/hang": ["a"],
        ], hangEntries: true)
        let scanner = DirectoryScanner(fileSystem: fs, maxConcurrentDirectories: 2)
        let task = Task { try await scanner.scan(root: "/hang") }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected \(error)")
        }
    }

    @Test func progressReportsFiles() async throws {
        let root = try makeTemp()
        defer { remove(root) }
        for index in 0..<5 {
            try Data("x".utf8).write(to: root.appendingPathComponent("f\(index).txt"))
        }
        let box = ProgressBox()
        _ = try await DirectoryScanner().scan(root: root.path) { progress in
            box.record(progress)
        }
        #expect(box.maximumFiles >= 5)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    var maximumFiles: Int {
        lock.lock()
        defer { lock.unlock() }
        return files
    }

    func record(_ progress: ScanProgress) {
        lock.lock()
        files = max(files, progress.visitedFiles)
        lock.unlock()
    }
}

struct MemoryFileSystem: FileSystemProbe {
    var nodes: [String: EntryMetadata]
    var children: [String: [String]]
    var forbidEntries: Set<String> = []
    var hangEntries = false

    func entries(at path: String) async throws -> [String] {
        if hangEntries {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw CancellationError()
        }
        if forbidEntries.contains(path) {
            throw FileSystemError.io(path: path, errno: 1)
        }
        guard let names = children[path] else { throw FileSystemError.notFound(path) }
        return names.sorted()
    }

    func listing(at path: String) async throws -> [ListedEntry] {
        let names = try await entries(at: path)
        return names.map { name in
            let child = path == "/" ? "/\(name)" : path + "/" + name
            guard let meta = nodes[child] else { return ListedEntry(name: name, kind: .unknown) }
            let kind: ListedKind = meta.isSymlink ? .symlink : (meta.isDirectory ? .directory : .file)
            return ListedEntry(name: name, kind: kind)
        }
    }

    func metadata(at path: String) async throws -> EntryMetadata {
        guard let meta = nodes[path] else { throw FileSystemError.notFound(path) }
        return meta
    }
}

private func meta(directory: Bool, device: UInt64, allocated: UInt64) -> EntryMetadata {
    EntryMetadata(
        isDirectory: directory,
        isSymlink: false,
        allocatedSize: allocated,
        logicalSize: allocated,
        device: device,
        inode: UInt64.random(in: 1...UInt64.max),
        linkCount: 1,
        modified: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func paths(_ node: ScanNode) -> [String] {
    [node.path] + node.children.flatMap(paths)
}

private func makeTemp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("devdisk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
