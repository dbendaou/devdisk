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
///
/// Darwin and Glibc disagree on a few names. This file is the only libc user
/// in the library (no `rename`, `unlink`, `rmdir`, or `fts`):
/// - `opendir` returns `UnsafeMutablePointer<DIR>` on Darwin and `OpaquePointer` on Glibc.
/// - `dirent.d_name` is 1024 bytes on Darwin and 256 on Glibc.
/// - `DT_*` is `Int32` on Darwin and `Int` on Glibc. `d_type` is `UInt8` on both.
/// - mtime is `st_mtimespec` on Darwin and `st_mtim` on Glibc.
/// - `st_blocks` is `Int64` on Darwin and `Int` on Glibc; both count 512-byte units.
/// Deletion on macOS goes through `FileManager`, not these calls.
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
        var code: Int32 = 0
        let result = path.withCString { pointer -> Int32 in
            let rc = lstat(pointer, &info)
            if rc != 0 { code = errno }
            return rc
        }
        if result != 0 {
            throw mapErrno(code, path: path)
        }
        let kind = info.st_mode & S_IFMT
        let isLink = kind == S_IFLNK
        let isDir = kind == S_IFDIR
        let blocks = nonNegative(info.st_blocks)
        return EntryMetadata(
            isDirectory: isDir,
            isSymlink: isLink,
            allocatedSize: blocks * 512,
            logicalSize: nonNegative(info.st_size),
            device: nonNegative(info.st_dev),
            inode: nonNegative(info.st_ino),
            linkCount: nonNegative(info.st_nlink),
            modified: modifiedDate(info)
        )
    }

    /// `opendir`'s pointer type is not shared. The closure's return type is
    /// inferred so Darwin's `UnsafeMutablePointer<DIR>` and Glibc's `OpaquePointer` both fit.
    private static func readListing(_ path: String) throws -> [ListedEntry] {
        var openError: Int32 = 0
        let dir = path.withCString { pointer in
            let opened = opendir(pointer)
            if opened == nil { openError = errno }
            return opened
        }
        guard let dir else { throw mapErrno(openError, path: path) }
        defer { closedir(dir) }
        var entries: [ListedEntry] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                let code = errno
                if code != 0 { throw mapErrno(code, path: path) }
                break
            }
            let name = entryName(entry)
            if name == "." || name == ".." { continue }
            entries.append(ListedEntry(name: name, kind: kind(of: entry.pointee.d_type)))
        }
        entries.sort { $0.name < $1.name }
        return entries
    }

    private static func kind(of type: UInt8) -> ListedKind {
        switch Int(type) {
        case Int(DT_DIR): .directory
        case Int(DT_REG): .file
        case Int(DT_LNK): .symlink
        case Int(DT_UNKNOWN): .unknown
        default: .other
        }
    }

    /// `d_name` is 1024 bytes on Darwin and 256 on Glibc. Read the field's own
    /// bytes instead of rebinding it to a fixed capacity.
    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: entry.pointee.d_name) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
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

    /// Signed on Darwin (`Int32`/`Int64`) and sometimes unsigned on Glibc (`UInt64`).
    private static func nonNegative<T: BinaryInteger>(_ value: T) -> UInt64 {
        guard value > 0 else { return 0 }
        return UInt64(value)
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
