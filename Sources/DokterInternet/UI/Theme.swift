import AppKit
import NetCore
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

enum Theme {
    static let canvas = Color.dynamic(0xF5F6F8, 0x0E0F12)
    static let sidebar = Color.dynamic(0xECEEF2, 0x141519)
    static let card = Color.dynamic(0xFFFFFF, 0x17181C)
    static let cardSunken = Color.dynamic(0xF0F1F4, 0x111215)
    static let border = Color.dynamic(0xE3E5EA, 0x26282E)

    static let text = Color.dynamic(0x16181D, 0xF2F3F5)
    static let textSecondary = Color.dynamic(0x5F6470, 0xA2A6B0)
    static let textTertiary = Color.dynamic(0x9AA0AB, 0x646873)

    static let accent = Color.dynamic(0x2F5BEA, 0x6E8FFF)
    static let accentSoft = Color.dynamic(0xE8EEFF, 0x1C2440)
    static let upload = Color.dynamic(0x8B3FE0, 0xB384FF)

    static let good = Color.dynamic(0x16A34A, 0x4ADE80)
    static let fair = Color.dynamic(0xD97706, 0xFBBF24)
    static let poor = Color.dynamic(0xDC2626, 0xF87171)
    static let neutral = Color.dynamic(0x9AA0AB, 0x646873)

    static func color(_ h: Health) -> Color {
        switch h {
        case .good: return good
        case .fair: return fair
        case .poor: return poor
        case .unknown: return neutral
        }
    }
}
