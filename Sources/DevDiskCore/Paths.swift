import Foundation

public enum Paths {
    /// Lexical cleanup only. This does not touch the filesystem and does not
    /// resolve symlinks. On macOS `URL.standardizedFileURL` would turn `/home`
    /// into `/System/Volumes/Data/home` and `/var` into `/private/var`, so a
    /// path the caller named would no longer match the directory we scan.
    public static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if parts.last != nil, parts.last != ".." {
                    parts.removeLast()
                } else if !absolute {
                    parts.append("..")
                }
                continue
            }
            parts.append(String(part))
        }
        if parts.isEmpty { return absolute ? "/" : "." }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : joined
    }

    public static func join(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/" + name }
        if directory.hasSuffix("/") { return directory + name }
        return directory + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" { return "/" }
        guard let slash = normalized.lastIndex(of: "/") else { return "/" }
        if slash == normalized.startIndex { return "/" }
        return String(normalized[..<slash])
    }

    public static func name(_ path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" { return "/" }
        guard let slash = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: slash)...])
    }

    /// `path` is equal to `root` or a descendant. Prefixes must end on a boundary,
    /// so `/Users/dev` does not contain `/Users/developer`.
    public static func isInside(_ path: String, root: String) -> Bool {
        let path = normalize(path)
        let root = normalize(root)
        return path == root || path.hasPrefix(root + "/")
    }

    public static func isStrictlyInside(_ path: String, root: String) -> Bool {
        let path = normalize(path)
        let root = normalize(root)
        return path.hasPrefix(root + "/")
    }

    public static func components(_ path: String) -> [String] {
        normalize(path).split(separator: "/").map(String.init)
    }

    public static func hasConsecutive(_ path: String, _ needle: [String]) -> Bool {
        let parts = components(path)
        guard needle.count <= parts.count, !needle.isEmpty else { return false }
        for index in 0...(parts.count - needle.count) {
            if Array(parts[index..<(index + needle.count)]) == needle {
                return true
            }
        }
        return false
    }
}
