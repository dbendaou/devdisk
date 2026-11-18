#if os(macOS)
import SwiftUI
import DevDiskCore

extension FileKind {
    var color: Color {
        Color(red: tint.red, green: tint.green, blue: tint.blue)
    }
}

enum DevDiskTheme {
    static let safe = Color(red: 0.12, green: 0.55, blue: 0.42)
    static let review = Color(red: 0.80, green: 0.46, blue: 0.12)
    static let reclaim = Color(red: 0.11, green: 0.52, blue: 0.48)
    static let ink = Color(red: 0.16, green: 0.20, blue: 0.24)

    static func safety(_ level: SafetyLevel) -> Color {
        level == .safe ? safe : review
    }
}

struct SafetyBadge: View {
    var level: SafetyLevel

    var body: some View {
        Text(level.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DevDiskTheme.safety(level).opacity(0.16), in: Capsule())
            .foregroundStyle(DevDiskTheme.safety(level))
    }
}

struct CapacityBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [DevDiskTheme.ink, DevDiskTheme.reclaim],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 10)
        .accessibilityLabel("Volume usage")
    }
}
#endif
