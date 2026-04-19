#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Adaptive colour tokens used across the app's view modules.
///
/// Every surface in the app is painted from this palette. The tokens
/// resolve to the system's native semantic colours on each platform so
/// a single asset (no ``Assets.xcassets`` required at the package
/// layer) adapts automatically to light, dark, and increased-contrast
/// appearances, and to the user's tint selection. Hardcoded
/// ``Color.black`` / ``Color.white`` / ``Color(white:)`` literals are
/// forbidden in view code — every background, border, and foreground
/// goes through one of these tokens so the light/dark branching is
/// driven entirely by system preferences.
///
/// On Linux SPM (where neither UIKit nor AppKit is available) the
/// tokens fall back to ``Color.clear`` / ``Color.primary`` / etc., so
/// the library compiles and the pure-logic tests run without a Darwin
/// host. Views using the tokens are themselves ``canImport(SwiftUI)``-
/// gated, so the fallback colour path is effectively unreachable on a
/// shipping build.
public enum SemanticColor {
    /// Full-bleed page background. Resolves to `systemBackground` on
    /// iOS, `windowBackgroundColor` on macOS.
    public static var background: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        .clear
        #endif
    }

    /// Grouped section background — one shade off the page. Resolves
    /// to `secondarySystemBackground` on iOS, `underPageBackgroundColor`
    /// on macOS.
    public static var groupedBackground: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .secondarySystemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .underPageBackgroundColor)
        #else
        .clear
        #endif
    }

    /// Elevated card or row fill. One shade above the grouped
    /// background — a row on a list sits here.
    public static var surface: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .tertiarySystemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        .clear
        #endif
    }

    /// Elevated fill shown inside a surface — input fields, pill
    /// buttons sitting on a card. Resolves to
    /// `quaternarySystemFill` on iOS.
    public static var elevatedFill: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .quaternarySystemFill)
        #elseif canImport(AppKit)
        Color(nsColor: .controlColor)
        #else
        .clear
        #endif
    }

    /// Hairline separator / border.
    public static var separator: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .separator)
        #elseif canImport(AppKit)
        Color(nsColor: .separatorColor)
        #else
        .primary.opacity(0.2)
        #endif
    }

    /// Primary text — maps to `Color.primary`, which is already
    /// adaptive. Re-exposed here so every view reaches for
    /// ``SemanticColor`` consistently instead of mixing
    /// ``Color.primary`` and ``SemanticColor`` literals.
    public static var textPrimary: Color { .primary }

    /// Secondary text — subtitles, captions, metadata.
    public static var textSecondary: Color { .secondary }

    /// Tertiary text — disabled labels, tertiary metadata.
    public static var textTertiary: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .tertiaryLabel)
        #elseif canImport(AppKit)
        Color(nsColor: .tertiaryLabelColor)
        #else
        .secondary
        #endif
    }

    /// Brand accent — same as `Color.accentColor` but surfaced here so
    /// views don't reach for one token from the system and others from
    /// ``SemanticColor``.
    public static var accent: Color { .accentColor }

    /// Destructive / error tint. Resolves to the system's red
    /// semantic colour.
    public static var destructive: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .systemRed)
        #elseif canImport(AppKit)
        Color(nsColor: .systemRed)
        #else
        .red
        #endif
    }

    /// Warning tint. Resolves to the system's orange semantic colour.
    public static var warning: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .systemOrange)
        #elseif canImport(AppKit)
        Color(nsColor: .systemOrange)
        #else
        .orange
        #endif
    }

    /// Success tint. Resolves to the system's green semantic colour.
    public static var success: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .systemGreen)
        #elseif canImport(AppKit)
        Color(nsColor: .systemGreen)
        #else
        .green
        #endif
    }

    /// Fill used for the Apple sign-in button on every appearance.
    /// Per Apple HIG the button MAY be black in both light and dark,
    /// which is what we use — a single visual identity avoids the
    /// asset-catalog machinery that would otherwise be required to
    /// ship both variants.
    public static var appleButtonBackground: Color {
        .black
    }

    /// Foreground for the Apple sign-in button. Always white against
    /// the always-black fill.
    public static var appleButtonForeground: Color {
        .white
    }

    /// Fill for the Google sign-in button. Per Google's Identity
    /// guidelines the button uses a white surface with a grey outline
    /// on light backgrounds, and a dark grey surface on dark
    /// backgrounds. Mapping to `systemGray6` gives both appearances
    /// automatically without an asset-catalog entry.
    public static var googleButtonBackground: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .systemGray6)
        #elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        .clear
        #endif
    }

    /// Foreground for the Google sign-in button — adaptive label
    /// colour so the "G" and label read correctly on every
    /// appearance.
    public static var googleButtonForeground: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .label)
        #elseif canImport(AppKit)
        Color(nsColor: .labelColor)
        #else
        .primary
        #endif
    }
}
#endif
