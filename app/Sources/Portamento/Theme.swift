import AppKit
import SwiftUI

/// Every look-and-feel decision in one place, so the style can change here
/// instead of across the views. The native style leans on system colours,
/// materials and SF Symbols.
enum Theme {
    /// Portamento's accent (hue 359°, saturation 30 %), a touch lighter in dark mode for contrast.
    static let accent = Color(light: 0xA6595B, dark: 0xC18B8C)
    /// The rest of the palette: deep for dark fills, soft and pale for light ones.
    static let deep = Color(light: 0x271C1C, dark: 0x271C1C)
    static let soft = Color(light: 0xDDC5C6, dark: 0xDDC5C6)
    static let pale = Color(light: 0xF4F0F0, dark: 0xF4F0F0)
    /// What a game without artwork gets instead: the accent fading into deep.
    static let placeholder = LinearGradient(colors: [Color(light: 0xA6595B, dark: 0x8E4C4E), deep],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)

    static let tileWidth: CGFloat = 150
    static let tileAspect: CGFloat = 2 / 3
    static let tileCorner: CGFloat = 10
    static let gridSpacing: CGFloat = 20
    static let contentPadding: CGFloat = 24

    /// Human names for the values porta uses.
    static func wineName(_ wine: String) -> String {
        switch wine {
        case "cx": "Wine 11.0 (CrossOver)"
        case "staging": "Wine 11.21 Staging"
        case "gptk": "Wine 7.7 (D3DMetal)"
        default: wine
        }
    }

    static func gfxName(_ gfx: String) -> String {
        switch gfx {
        case "dxmt": "DXMT"
        case "dxvk": "DXVK"
        case "wined3d": "WineD3D"
        case "d3dmetal": "D3DMetal"
        default: gfx
        }
    }

    static func vulkanName(_ vulkan: String) -> String {
        switch vulkan {
        case "moltenvk": "MoltenVK"
        case "kosmickrisp": "KosmicKrisp"
        default: vulkan
        }
    }

    /// How a way of running a game reads in menus: "DXMT · Wine 11.0 (CrossOver) · steam-cx".
    static func variantName(_ item: LibraryItem) -> String {
        "\(gfxName(item.prefix.gfx)) · \(wineName(item.prefix.wine)) · \(item.prefix.name)"
    }

    /// The same, short enough for under a tile: "DXMT · Wine 11.0".
    static func shortVariantName(_ item: LibraryItem) -> String {
        let wine = ["cx": "Wine 11.0", "staging": "Wine 11.21", "gptk": "Wine 7.7"][item.prefix.wine] ?? item.prefix.wine
        return "\(gfxName(item.prefix.gfx)) · \(wine)"
    }

    /// "2 režimy", "5 režimů".
    static func modes(_ count: Int) -> String {
        "\(count) \((2...4).contains(count) ? "režimy" : "režimů")"
    }

    /// A prefix's default program is named after its file ("steam"); give it a capital.
    static func displayName(_ program: Program) -> String {
        program.kind == .default ? program.name.prefix(1).uppercased() + program.name.dropFirst() : program.name
    }

    static func symbol(for program: Program) -> String {
        if program.exe.lowercased().hasSuffix("\\steam.exe") { return "storefront" }
        switch program.kind {
        case .default, .custom: return "macwindow"
        case .steam: return "gamecontroller"
        }
    }
}

extension Color {
    /// A colour that follows the window's light or dark appearance.
    init(light: UInt32, dark: UInt32) {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        })
    }
}

/// A small capsule label, used for a prefix's Wine, backend and Vulkan driver.
struct Tag: View {
    var text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: .capsule)
    }
}
