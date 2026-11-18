import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct EntryMetadata: Sendable, Equatable, Hashable {
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var allocatedSize: UInt64
    public var logicalSize: UInt64
    public var device: UInt64
    public var inode: UInt64
    public var linkCount: UInt64
    public var modified: Date?

    public init(
        isDirectory: Bool,
        isSymlink: Bool,
        allocatedSize: UInt64,
        logicalSize: UInt64,
        device: UInt64,
        inode: UInt64,
        linkCount: UInt64,
        modified: Date?
    ) {
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.device = device
        self.inode = inode
        self.linkCount = linkCount
        self.modified = modified
    }
}

public enum FileSystemError: Error, Sendable, Equatable {
    case permissionDenied(String)
    case notFound(String)
    case io(path: String, errno: Int32)

    public var message: String {
        switch self {
        case .permissionDenied(let path):
            "Permission denied: \(path)"
        case .notFound(let path):
            "Not found: \(path)"
        case .io(let path, let code):
            "Could not read \(path) (errno \(code))"
        }
    }
}

extension FileSystemError: LocalizedError {
    public var errorDescription: String? { message }
}

public enum ListedKind: Sendable, Equatable, Hashable {
    case directory
    case file
    case symlink
    case other
    case unknown
}

public struct ListedEntry: Sendable, Equatable, Hashable {
    public var name: String
    public var kind: ListedKind

    public init(name: String, kind: ListedKind) {
        self.name = name
        self.kind = kind
    }
}

public protocol FileSystemProbe: Sendable {
    func entries(at path: String) async throws -> [String]
    func listing(at path: String) async throws -> [ListedEntry]
    func metadata(at path: String) async throws -> EntryMetadata
}

/// POSIX `lstat` / `readdir` reader. Allocated size is `st_blocks * 512`.
/// Symlinks are not followed. Each call opens its own directory stream.
public struct POSIXFileSystem: FileSystemProbe {
    public init() {}

    public func entries(at path: String) async throws -> [String] {
        try await listing(at: path).map(\.name)
    }

    public func listing(at path: String) async throws -> [ListedEntry] {
        try Self.readListing(path)
    }

    public func metadata(at path: String) async throws -> EntryMetadata {
        try Self.readMetadata(path)
    }

    private static func readMetadata(_ path: String) throws -> EntryMetadata {
        var info = stat()
        let result = path.withCString { lstat($0, &info) }
        if result != 0 {
            throw mapErrno(errno, path: path)
        }
        let mode = info.st_mode
        let kind = mode & S_IFMT
        let isLink = kind == S_IFLNK
        let isDir = kind == S_IFDIR
        let blocks = info.st_blocks
        let allocated: UInt64 = blocks > 0 ? UInt64(blocks) * 512 : 0
        let logical: UInt64 = info.st_size > 0 ? UInt64(info.st_size) : 0
        return EntryMetadata(
            isDirectory: isDir,
            isSymlink: isLink,
            allocatedSize: allocated,
            logicalSize: logical,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            linkCount: UInt64(info.st_nlink),
            modified: modifiedDate(info)
        )
    }

    private static func readListing(_ path: String) throws -> [ListedEntry] {
        guard let dir = path.withCString({ opendir($0) }) else {
            throw mapErrno(errno, path: path)
        }
        defer { closedir(dir) }
        var entries: [ListedEntry] = []
        errno = 0
        while let entry = readdir(dir) {
            let name = entryName(entry)
            if name == "." || name == ".." { continue }
            entries.append(ListedEntry(name: name, kind: kind(of: entry.pointee.d_type)))
        }
        if errno != 0 {
            throw mapErrno(errno, path: path)
        }
        entries.sort { $0.name < $1.name }
        return entries
    }

    private static func kind(of type: UInt8) -> ListedKind {
        switch Int(type) {
        case DT_DIR: .directory
        case DT_REG: .file
        case DT_LNK: .symlink
        case DT_UNKNOWN: .unknown
        default: .other
        }
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1024) {
                String(cString: $0)
            }
        }
    }

    private static func modifiedDate(_ info: stat) -> Date {
        #if canImport(Darwin)
        let seconds = info.st_mtimespec.tv_sec
        let nanos = info.st_mtimespec.tv_nsec
        #else
        let seconds = info.st_mtim.tv_sec
        let nanos = info.st_mtim.tv_nsec
        #endif
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }

    private static func mapErrno(_ code: Int32, path: String) -> FileSystemError {
        switch code {
        case EACCES, EPERM:
            return .permissionDenied(path)
        case ENOENT:
            return .notFound(path)
        default:
            return .io(path: path, errno: code)
        }
    }
}
