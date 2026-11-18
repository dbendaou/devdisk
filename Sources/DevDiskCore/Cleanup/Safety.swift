import Foundation

public enum SafetyLevel: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Regenerable cache or build output.
    case safe
    /// May contain data the user still wants: databases, disk images, app data, archives.
    case review

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        }
    }

    public var detail: String {
        switch self {
        case .safe: "Regenerable cache or build output."
        case .review: "May contain data such as databases, disk images, or app files."
        }
    }
}

public enum SafetyViolation: Error, Sendable, Equatable {
    case outsideRoot(String)
    case protected(String)
    case isScanRoot(String)
    case commandNotAllowed(String)
    case notTrashChild(String)
    case emptySelection

    public var message: String {
        switch self {
        case .outsideRoot(let path):
            "Refusing \(path): it is outside the scanned folder."
        case .protected(let path):
            "Refusing \(path): system folders, Keychains, Mail, and Photos libraries are never touched."
        case .isScanRoot(let path):
            "Refusing to delete the scanned folder itself (\(path))."
        case .commandNotAllowed(let executable):
            "Refusing to run \(executable): it is not in the command allow list."
        case .notTrashChild(let path):
            "Refusing \(path): emptying Trash only deletes items already inside a .Trash folder."
        case .emptySelection:
            "Nothing to clean."
        }
    }
}

extension SafetyViolation: LocalizedError {
    public var errorDescription: String? { message }
}

public enum CommandAllowlist {
    /// Bare executable names. Paths are rejected so a rule cannot point at a binary outside PATH.
    public static let executables: Set<String> = [
        "brew", "docker", "xcrun", "pnpm", "npm", "yarn", "bun", "orb", "orbctl", "colima", "podman", "git",
    ]

    public static func isAllowed(_ executable: String) -> Bool {
        !executable.isEmpty && !executable.contains("/") && !executable.contains("..") && executables.contains(executable)
    }
}

public enum PathSafety {
    /// Prefixes that are never deletion targets, even when they sit inside the scan root
    /// (for example a scan of `/`). `/private` itself is not banned: on macOS `/tmp` lives there.
    public static let systemPrefixes: [String] = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/Library",
        "/etc",
        "/dev",
        "/opt",
        "/Applications",
        "/private/etc",
        "/private/var",
    ]

    public static func isProtected(_ path: String) -> Bool {
        let path = Paths.normalize(path)
        for prefix in systemPrefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return true
        }
        let parts = Paths.components(path)
        if parts.contains(where: { $0.hasSuffix(".photoslibrary") }) { return true }
        if Paths.hasConsecutive(path, ["Library", "Keychains"]) { return true }
        if Paths.hasConsecutive(path, ["Library", "Mail"]) { return true }
        if parts.contains("com.apple.mail") || parts.contains("com.apple.photos") || parts.contains("com.apple.Photos") {
            return true
        }
        return false
    }

    /// A path we are willing to delete or hand to a tool. The scan root itself is refused.
    public static func violation(for path: String, scanRoot: String) -> SafetyViolation? {
        let path = Paths.normalize(path)
        let root = Paths.normalize(scanRoot)
        if path.isEmpty {
            return .outsideRoot(path)
        }
        if path == root {
            return .isScanRoot(path)
        }
        if !Paths.isStrictlyInside(path, root: root) {
            return .outsideRoot(path)
        }
        if isProtected(path) {
            return .protected(path)
        }
        return nil
    }

    public static func containsProtected(_ node: ScanNode) -> Bool {
        if isProtected(node.path) { return true }
        for child in node.children where containsProtected(child) {
            return true
        }
        return false
    }
}
