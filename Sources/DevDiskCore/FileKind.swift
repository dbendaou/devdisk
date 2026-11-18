import Foundation

public struct RGBColor: Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Coarse file kind used to colour the treemap and the kind breakdown.
/// Classification is by extension so it works without macOS Uniform Type Identifiers.
public enum FileKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case folder
    case image
    case video
    case audio
    case archive
    case diskImage
    case document
    case code
    case database
    case font
    case executable
    case other

    public var label: String {
        switch self {
        case .folder: "Folder"
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .archive: "Archive"
        case .diskImage: "Disk image"
        case .document: "Document"
        case .code: "Code"
        case .database: "Database"
        case .font: "Font"
        case .executable: "Executable"
        case .other: "Other"
        }
    }

    public var tint: RGBColor {
        switch self {
        case .folder: RGBColor(red: 0.45, green: 0.48, blue: 0.52)
        case .image: RGBColor(red: 0.30, green: 0.55, blue: 1.00)
        case .video: RGBColor(red: 0.48, green: 0.36, blue: 1.00)
        case .audio: RGBColor(red: 0.89, green: 0.36, blue: 0.54)
        case .archive: RGBColor(red: 0.89, green: 0.64, blue: 0.24)
        case .diskImage: RGBColor(red: 0.82, green: 0.42, blue: 0.17)
        case .document: RGBColor(red: 0.23, green: 0.66, blue: 0.54)
        case .code: RGBColor(red: 0.36, green: 0.75, blue: 0.42)
        case .database: RGBColor(red: 0.77, green: 0.36, blue: 0.36)
        case .font: RGBColor(red: 0.56, green: 0.42, blue: 0.75)
        case .executable: RGBColor(red: 0.31, green: 0.42, blue: 0.48)
        case .other: RGBColor(red: 0.55, green: 0.58, blue: 0.63)
        }
    }

    public static func classify(name: String) -> FileKind {
        let ext = extensionOf(name)
        if ext.isEmpty { return .other }
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if archiveExtensions.contains(ext) { return .archive }
        if diskImageExtensions.contains(ext) { return .diskImage }
        if databaseExtensions.contains(ext) { return .database }
        if documentExtensions.contains(ext) { return .document }
        if codeExtensions.contains(ext) { return .code }
        if fontExtensions.contains(ext) { return .font }
        if executableExtensions.contains(ext) { return .executable }
        return .other
    }

    public static func extensionOf(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        let ext = name[name.index(after: dot)...]
        if ext.isEmpty || ext.contains("/") { return "" }
        return ext.lowercased()
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "ico", "avif",
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "webm", "m4v", "mpeg", "mpg",
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "aac", "flac", "m4a", "ogg", "aiff", "aif",
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "zst",
    ]
    private static let diskImageExtensions: Set<String> = [
        "dmg", "iso", "pkg", "sparseimage", "cdr",
    ]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "rtf", "md", "pages", "numbers", "key", "csv",
    ]
    private static let codeExtensions: Set<String> = [
        "swift", "py", "js", "ts", "tsx", "jsx", "json", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp",
        "m", "mm", "cs", "php", "html", "css", "scss", "sh", "toml", "yaml", "yml", "lock", "gradle", "xml",
    ]
    private static let databaseExtensions: Set<String> = [
        "sqlite", "sqlite3", "db", "rdb", "aof", "sqlitedb",
    ]
    private static let fontExtensions: Set<String> = [
        "ttf", "otf", "woff", "woff2", "ttc",
    ]
    private static let executableExtensions: Set<String> = [
        "so", "dylib", "dll", "exe", "bin",
    ]
}
