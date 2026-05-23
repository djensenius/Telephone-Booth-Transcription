//
//  Theme.swift
//  Telephone-Booth-Transcription
//
//  Catppuccin Latte (light) / Mocha (dark) palette, plus macOS 26 Liquid
//  Glass helpers, mirroring the styling used by sibling apps (FluxHaus,
//  Rhizome, gt3pro). visionOS is intentionally not addressed here — this
//  is a macOS-only app.
//

import SwiftUI
import AppKit

/// Project-wide design tokens — colours, fonts, spacing, radii.
public enum Theme {

    // MARK: - Catppuccin palettes

    private enum CatppuccinLatte {
        static let rosewater = Color(hex: "dc8a78")
        static let flamingo = Color(hex: "dd7878")
        static let pink = Color(hex: "ea76cb")
        static let mauve = Color(hex: "8839ef")
        static let red = Color(hex: "d20f39")
        static let maroon = Color(hex: "e64553")
        static let peach = Color(hex: "fe640b")
        static let yellow = Color(hex: "df8e1d")
        static let green = Color(hex: "40a02b")
        static let teal = Color(hex: "179299")
        static let sky = Color(hex: "04a5e5")
        static let sapphire = Color(hex: "209fb5")
        static let blue = Color(hex: "1e66f5")
        static let lavender = Color(hex: "7287fd")
        static let text = Color(hex: "4c4f69")
        static let subtext1 = Color(hex: "5c5f77")
        static let subtext0 = Color(hex: "6c6f85")
        static let overlay2 = Color(hex: "7c7f93")
        static let overlay1 = Color(hex: "8c8fa1")
        static let overlay0 = Color(hex: "9ca0b0")
        static let surface2 = Color(hex: "acb0be")
        static let surface1 = Color(hex: "bcc0cc")
        static let surface0 = Color(hex: "ccd0da")
        static let base = Color(hex: "eff1f5")
        static let mantle = Color(hex: "e6e9ef")
        static let crust = Color(hex: "dce0e8")
    }

    private enum CatppuccinMocha {
        static let rosewater = Color(hex: "f5e0dc")
        static let flamingo = Color(hex: "f2cdcd")
        static let pink = Color(hex: "f5c2e7")
        static let mauve = Color(hex: "cba6f7")
        static let red = Color(hex: "f38ba8")
        static let maroon = Color(hex: "eba0ac")
        static let peach = Color(hex: "fab387")
        static let yellow = Color(hex: "f9e2af")
        static let green = Color(hex: "a6e3a1")
        static let teal = Color(hex: "94e2d5")
        static let sky = Color(hex: "89dceb")
        static let sapphire = Color(hex: "74c7ec")
        static let blue = Color(hex: "89b4fa")
        static let lavender = Color(hex: "b4befe")
        static let text = Color(hex: "cdd6f4")
        static let subtext1 = Color(hex: "bac2de")
        static let subtext0 = Color(hex: "a6adc8")
        static let overlay2 = Color(hex: "9399b2")
        static let overlay1 = Color(hex: "7f849c")
        static let overlay0 = Color(hex: "6c7086")
        static let surface2 = Color(hex: "585b70")
        static let surface1 = Color(hex: "45475a")
        static let surface0 = Color(hex: "313244")
        static let base = Color(hex: "1e1e2e")
        static let mantle = Color(hex: "181825")
        static let crust = Color(hex: "11111b")
    }

    private static func dynamic(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
    }

    // MARK: - Semantic colours

    public enum Colors {
        public static let accent = dynamic(light: CatppuccinLatte.peach, dark: CatppuccinMocha.peach)
        public static let primary = dynamic(light: CatppuccinLatte.mauve, dark: CatppuccinMocha.mauve)
        public static let secondary = dynamic(light: CatppuccinLatte.teal, dark: CatppuccinMocha.teal)

        public static let background = dynamic(light: CatppuccinLatte.base, dark: CatppuccinMocha.base)
        public static let secondaryBackground = dynamic(
            light: CatppuccinLatte.mantle,
            dark: CatppuccinMocha.mantle
        )
        public static let tertiaryBackground = dynamic(
            light: CatppuccinLatte.surface0,
            dark: CatppuccinMocha.surface0
        )

        public static let textPrimary = dynamic(light: CatppuccinLatte.text, dark: CatppuccinMocha.text)
        // Asymmetric on purpose: Latte's `subtext0` over a translucent Liquid
        // Glass card was visually marginal (~4:1 contrast), so light mode
        // uses the slightly darker `subtext1`. Mocha keeps `subtext0` since
        // dark-mode contrast on the same glass surface is already strong.
        public static let textSecondary = dynamic(
            light: CatppuccinLatte.subtext1,
            dark: CatppuccinMocha.subtext0
        )

        /// Always-dark foreground for use on the accent (peach) background.
        /// Peach in both Latte (#fe640b) and Mocha (#fab387) is bright enough
        /// that a fixed dark text reads with strong contrast in both modes.
        public static let onAccent = Color(hex: "11111b")

        public static let error = dynamic(light: CatppuccinLatte.red, dark: CatppuccinMocha.red)
        public static let warning = dynamic(light: CatppuccinLatte.yellow, dark: CatppuccinMocha.yellow)
        public static let success = dynamic(light: CatppuccinLatte.green, dark: CatppuccinMocha.green)
        public static let info = dynamic(light: CatppuccinLatte.blue, dark: CatppuccinMocha.blue)
    }

    // MARK: - Fonts

    public enum Fonts {
        public static func header4XL() -> Font { .system(size: 36, weight: .bold, design: .serif) }
        public static func headerXL() -> Font { .system(size: 22, weight: .bold, design: .serif) }
        public static func headerLarge() -> Font { .system(size: 17, weight: .semibold, design: .serif) }

        public static let bodyLarge = Font.system(size: 15)
        public static let bodyMedium = Font.system(size: 13)
        public static let bodySmall = Font.system(size: 12)
        public static let caption = Font.caption
    }

    // MARK: - Spacing & radii

    public enum Spacing {
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let extraLarge: CGFloat = 20
    }

    public static let cornerRadius: CGFloat = 12
}

// MARK: - Color(hex:) bootstrap

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let alpha, red, green, blue: UInt64
        switch hex.count {
        case 3:
            (alpha, red, green, blue) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (alpha, red, green, blue) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (alpha, red, green, blue) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (alpha, red, green, blue) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

// MARK: - Liquid Glass card

/// Wraps content in a macOS 26 Liquid Glass surface tinted with the Catppuccin
/// secondary background. Falls back gracefully on builds compiled against
/// older SDKs (the project targets macOS 26 so the fallback only matters at
/// build-time on hosts without the new SDK).
public struct GlassCard: ViewModifier {
    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(Theme.Spacing.large)
                .glassEffect(
                    .regular.tint(Theme.Colors.secondaryBackground.opacity(0.55)),
                    in: .rect(cornerRadius: Theme.cornerRadius)
                )
        } else {
            content
                .padding(Theme.Spacing.large)
                .background(Theme.Colors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
    }
}

public extension View {
    /// Apply a Liquid Glass card surface tinted with Catppuccin.
    func glassCard() -> some View { modifier(GlassCard()) }
}

// MARK: - Window background

/// A Catppuccin-tinted gradient that serves as the app's window background.
/// Subtle and low-contrast so foreground glass surfaces read crisply.
public struct ThemedWindowBackground: View {
    public init() {}
    public var body: some View {
        LinearGradient(
            colors: [
                Theme.Colors.background,
                Theme.Colors.secondaryBackground
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - Button styles

/// Primary Catppuccin button: peach accent fill, mantle text, scales on press.
public struct TBTPrimaryButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.bodyMedium.weight(.medium))
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.small)
            .background(Theme.Colors.accent)
            .foregroundStyle(Theme.Colors.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Secondary glass button — translucent Liquid Glass surface with Catppuccin
/// text. Use for non-destructive secondary actions in toolbars and forms.
public struct TBTGlassButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(Theme.Fonts.bodyMedium)
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)

        return Group {
            if #available(macOS 26.0, *) {
                label.glassEffect(
                    .regular,
                    in: .rect(cornerRadius: Theme.cornerRadius)
                )
            } else {
                label
                    .background(Theme.Colors.tertiaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
        }
        .opacity(configuration.isPressed ? 0.7 : 1.0)
        .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
        .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == TBTPrimaryButtonStyle {
    static var tbtPrimary: TBTPrimaryButtonStyle { TBTPrimaryButtonStyle() }
}

public extension ButtonStyle where Self == TBTGlassButtonStyle {
    static var tbtGlass: TBTGlassButtonStyle { TBTGlassButtonStyle() }
}
