import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct VolumeStats: Sendable, Equatable, Hashable {
    public var totalBytes: UInt64
    /// Bytes occupied, including space reserved for the superuser.
    public var usedBytes: UInt64
    /// Free bytes including reserved space.
    public var freeBytes: UInt64
    /// Bytes an unprivileged process can still write. This is the "free" figure Finder shows.
    public var availableBytes: UInt64

    public init(totalBytes: UInt64, usedBytes: UInt64, freeBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.availableBytes = availableBytes
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }
}

public enum VolumeProbe {
    public static func stats(at path: String) -> VolumeStats? {
        var info = statvfs()
        let result = path.withCString { statvfs($0, &info) }
        guard result == 0 else { return nil }
        let fragment = info.f_frsize > 0 ? u64(info.f_frsize) : u64(info.f_bsize)
        guard fragment > 0 else { return nil }
        let total = u64(info.f_blocks) * fragment
        let free = u64(info.f_bfree) * fragment
        let available = u64(info.f_bavail) * fragment
        let used = total >= free ? total - free : 0
        return VolumeStats(totalBytes: total, usedBytes: used, freeBytes: free, availableBytes: available)
    }
}

private func u64<T: BinaryInteger>(_ value: T) -> UInt64 {
    UInt64(value)
}
