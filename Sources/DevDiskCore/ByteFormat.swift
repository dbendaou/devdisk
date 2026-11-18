import Foundation

/// Decimal byte strings, matching Finder: 18.4 GB, 16 GB, 900 MB.
public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        if bytes < 1000 {
            return "\(bytes) B"
        }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = "B"
        for name in units {
            value /= 1000
            unit = name
            if value < 1000 { break }
        }
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(value.rounded())) \(unit)"
        }
        return String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, unit)
    }
}
