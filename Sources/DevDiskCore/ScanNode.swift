import Foundation

public struct ScanNode: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var path: String
    public var kind: FileKind
    /// Allocated bytes for this node, including descendants. Hard-link duplicates contribute 0.
    public var allocatedSize: UInt64
    public var logicalSize: UInt64
    public var modified: Date?
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var countsAsDuplicateHardLink: Bool
    public var isOtherVolume: Bool
    public var errorMessage: String?
    /// Listed, but its contents are not measured yet. The map draws this as a placeholder.
    public var isPartial: Bool
    public var children: [ScanNode]

    public init(
        id: Int,
        name: String,
        path: String,
        kind: FileKind,
        allocatedSize: UInt64,
        logicalSize: UInt64 = 0,
        modified: Date? = nil,
        isDirectory: Bool = false,
        isSymlink: Bool = false,
        countsAsDuplicateHardLink: Bool = false,
        isOtherVolume: Bool = false,
        errorMessage: String? = nil,
        isPartial: Bool = false,
        children: [ScanNode] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.modified = modified
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.countsAsDuplicateHardLink = countsAsDuplicateHardLink
        self.isOtherVolume = isOtherVolume
        self.errorMessage = errorMessage
        self.isPartial = isPartial
        self.children = children
    }

    /// `nil` marks a leaf for `OutlineGroup`.
    public var outlineChildren: [ScanNode]? {
        children.isEmpty ? nil : children
    }

    public func node(atPath target: String) -> ScanNode? {
        if path == target { return self }
        let prefix = path == "/" ? "/" : path + "/"
        guard target.hasPrefix(prefix) else { return nil }
        for child in children {
            if target == child.path || target.hasPrefix(child.path == "/" ? "/" : child.path + "/") {
                return child.node(atPath: target)
            }
        }
        return nil
    }

    public func node(id: Int) -> ScanNode? {
        if self.id == id { return self }
        for child in children {
            if let found = child.node(id: id) { return found }
        }
        return nil
    }

    /// Largest file kind inside this subtree, used when a directory is drawn as one cell.
    public func dominantFileKind() -> FileKind {
        if !isDirectory { return kind }
        var totals: [FileKind: UInt64] = [:]
        func walk(_ node: ScanNode) {
            if node.isDirectory {
                for child in node.children { walk(child) }
            } else if !node.isSymlink {
                totals[node.kind, default: 0] += node.allocatedSize
            }
        }
        walk(self)
        return totals.max { $0.value < $1.value }?.key ?? .folder
    }
}

public struct ScanStats: Sendable, Equatable, Hashable {
    public var fileCount: Int
    public var directoryCount: Int
    public var symlinkCount: Int
    public var hardLinkDuplicateCount: Int
    public var otherVolumeCount: Int
    public var errorCount: Int
    public var allocatedBytes: UInt64

    public init(
        fileCount: Int = 0,
        directoryCount: Int = 0,
        symlinkCount: Int = 0,
        hardLinkDuplicateCount: Int = 0,
        otherVolumeCount: Int = 0,
        errorCount: Int = 0,
        allocatedBytes: UInt64 = 0
    ) {
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.symlinkCount = symlinkCount
        self.hardLinkDuplicateCount = hardLinkDuplicateCount
        self.otherVolumeCount = otherVolumeCount
        self.errorCount = errorCount
        self.allocatedBytes = allocatedBytes
    }
}

public struct ScanTree: Sendable, Equatable, Hashable {
    public var root: ScanNode
    public var stats: ScanStats

    public init(root: ScanNode, stats: ScanStats) {
        self.root = root
        self.stats = stats
    }
}

public struct ScanProgress: Sendable, Equatable, Hashable {
    public var visitedFiles: Int
    public var visitedDirectories: Int
    public var allocatedBytes: UInt64
    public var currentPath: String
    public var errorCount: Int
    public var suggestionsFound: Int
    public var reclaimableBytes: UInt64
    public var startedAt: Date?

    public init(
        visitedFiles: Int = 0,
        visitedDirectories: Int = 0,
        allocatedBytes: UInt64 = 0,
        currentPath: String = "",
        errorCount: Int = 0,
        suggestionsFound: Int = 0,
        reclaimableBytes: UInt64 = 0,
        startedAt: Date? = nil
    ) {
        self.visitedFiles = visitedFiles
        self.visitedDirectories = visitedDirectories
        self.allocatedBytes = allocatedBytes
        self.currentPath = currentPath
        self.errorCount = errorCount
        self.suggestionsFound = suggestionsFound
        self.reclaimableBytes = reclaimableBytes
        self.startedAt = startedAt
    }
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    /// A throttled look at the tree so far. Directories that are listed but not
    /// measured yet are marked `isPartial`.
    case snapshot(ScanTree)
    case finished(ScanTree)
}

public struct ExtensionStatistic: Sendable, Equatable, Hashable, Identifiable {
    public var extensionName: String
    public var kind: FileKind
    public var count: Int
    public var allocatedSize: UInt64
    public var id: String { extensionName }

    public init(extensionName: String, kind: FileKind, count: Int, allocatedSize: UInt64) {
        self.extensionName = extensionName
        self.kind = kind
        self.count = count
        self.allocatedSize = allocatedSize
    }
}

public struct KindTotal: Sendable, Equatable, Hashable, Identifiable {
    public var kind: FileKind
    public var count: Int
    public var allocatedSize: UInt64
    public var id: String { kind.rawValue }

    public init(kind: FileKind, count: Int, allocatedSize: UInt64) {
        self.kind = kind
        self.count = count
        self.allocatedSize = allocatedSize
    }
}

public enum UsageSummary {
    public static func extensions(in root: ScanNode) -> [ExtensionStatistic] {
        var buckets: [String: (kind: FileKind, count: Int, size: UInt64)] = [:]
        walkFiles(root) { node in
            let ext = FileKind.extensionOf(node.name)
            let key = ext.isEmpty ? "(none)" : ext
            var bucket = buckets[key] ?? (node.kind, 0, 0)
            bucket.count += 1
            bucket.size += node.allocatedSize
            if bucket.kind == .other { bucket.kind = node.kind }
            buckets[key] = bucket
        }
        return buckets
            .map { ExtensionStatistic(extensionName: $0.key, kind: $0.value.kind, count: $0.value.count, allocatedSize: $0.value.size) }
            .sorted {
                if $0.allocatedSize != $1.allocatedSize { return $0.allocatedSize > $1.allocatedSize }
                return $0.extensionName < $1.extensionName
            }
    }

    public static func kinds(in root: ScanNode) -> [KindTotal] {
        var buckets: [FileKind: (count: Int, size: UInt64)] = [:]
        walkFiles(root) { node in
            var bucket = buckets[node.kind] ?? (0, 0)
            bucket.count += 1
            bucket.size += node.allocatedSize
            buckets[node.kind] = bucket
        }
        return buckets
            .map { KindTotal(kind: $0.key, count: $0.value.count, allocatedSize: $0.value.size) }
            .sorted {
                if $0.allocatedSize != $1.allocatedSize { return $0.allocatedSize > $1.allocatedSize }
                return $0.kind.label < $1.kind.label
            }
    }

    private static func walkFiles(_ node: ScanNode, visit: (ScanNode) -> Void) {
        if node.isDirectory {
            for child in node.children { walkFiles(child, visit: visit) }
            return
        }
        if node.isSymlink || node.countsAsDuplicateHardLink { return }
        visit(node)
    }
}

public enum OutlineOrder: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case size
    case name
    case kind
    case modified

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .size: "Size"
        case .name: "Name"
        case .kind: "Kind"
        case .modified: "Modified"
        }
    }

    public func sortedTree(_ root: ScanNode) -> ScanNode {
        var copy = root
        copy.children = sorted(root.children)
        return copy
    }

    public func sorted(_ nodes: [ScanNode]) -> [ScanNode] {
        nodes.map { node in
            var copy = node
            copy.children = sorted(node.children)
            return copy
        }
        .sorted(by: isOrderedBefore)
    }

    private func isOrderedBefore(_ lhs: ScanNode, _ rhs: ScanNode) -> Bool {
        switch self {
        case .size where lhs.allocatedSize != rhs.allocatedSize:
            return lhs.allocatedSize > rhs.allocatedSize
        case .kind where lhs.kind != rhs.kind:
            return lhs.kind.label < rhs.kind.label
        case .modified:
            let left = lhs.modified ?? .distantPast
            let right = rhs.modified ?? .distantPast
            if left != right { return left > right }
        default:
            break
        }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id < rhs.id
    }
}
