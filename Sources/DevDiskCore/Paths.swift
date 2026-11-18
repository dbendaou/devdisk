import Foundation

public enum Paths {
    public static func normalize(_ path: String) -> String {
        var text = URL(fileURLWithPath: path).standardizedFileURL.path
        if text.count > 1, text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    public static func join(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/" + name }
        if directory.hasSuffix("/") { return directory + name }
        return directory + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" { return "/" }
        let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    public static func name(_ path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" { return "/" }
        return URL(fileURLWithPath: normalized).lastPathComponent
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
