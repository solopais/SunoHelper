import SwiftUI

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xff) / 255
        let g = Double((rgb >> 8) & 0xff) / 255
        let b = Double(rgb & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xff) / 255
        let g = CGFloat((rgb >> 8) & 0xff) / 255
        let b = CGFloat(rgb & 0xff) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

enum AppTheme {
    // 品牌色：珊瑚橙 -> 品红
    static let accent = Color(hex: "#FF6B3D")
    static let accent2 = Color(hex: "#FF2E63")
    static let bg = Color(hex: "#0E0E12")
    static let surface = Color(hex: "#1A1A20")
    static let surface2 = Color(hex: "#25252E")
    static let text = Color(hex: "#F2F2F5")
    static let textSecondary = Color(hex: "#9A9AA5")
    static let success = Color(hex: "#34C759")
    static let error = Color(hex: "#FF453A")

    static let bgUI = UIColor(hex: "#0E0E12")
    static let surfaceUI = UIColor(hex: "#1A1A20")
    static let textUI = UIColor(hex: "#F2F2F5")
    static let textSecondaryUI = UIColor(hex: "#9A9AA5")

    static func gradient() -> LinearGradient {
        LinearGradient(
            colors: [accent, accent2],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
