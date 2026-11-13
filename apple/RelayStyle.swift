import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Only deliberate interface changes animate. Audio telemetry never drives motion.
enum RelayMotion {
    static var keyboardInteraction: Bool {
        #if os(macOS)
        return NSApp.currentEvent?.type == .keyDown || NSApp.currentEvent?.type == .keyUp
        #else
        return false
        #endif
    }
    static var allowsSpatialMotion: Bool {
        #if os(macOS)
        return false
        #else
        return !UIAccessibility.isReduceMotionEnabled
        #endif
    }
    static func feedback(reduced: Bool, pressed: Bool = false) -> Animation? {
        #if os(macOS)
        return .linear(duration: 0.08)
        #else
        return keyboardInteraction ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: reduced ? 0.1 : pressed ? 0.1 : 0.16)
        #endif
    }
    static var navigation: Animation? {
        #if os(macOS)
        return nil
        #else
        return keyboardInteraction ? nil : allowsSpatialMotion ? .spring(response: 0.65, dampingFraction: 0.82) : .linear(duration: 0.12)
        #endif
    }
}

private struct RelayButtonFeedback: ViewModifier {
    let pressed: Bool
    var scales = true
    var radius: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius).fill(.white.opacity(enabled && hovered && !pressed ? 0.10 : 0)).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(RelayPalette.blue.opacity(enabled && focused ? 0.85 : 0), lineWidth: 2).allowsHitTesting(false))
            .opacity(enabled ? (pressed ? 0.88 : 1) : 0.45)
            .scaleEffect(pressed && enabled && scales && !reduced && !focused && !RelayMotion.keyboardInteraction ? 0.97 : 1)
            .animation(focused ? nil : RelayMotion.feedback(reduced: reduced, pressed: pressed), value: pressed)
            .animation(RelayMotion.feedback(reduced: reduced), value: hovered)
            .onHover { hovered = $0 }
    }
}

struct RelayControlButtonStyle: ButtonStyle {
    var scales = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .modifier(RelayButtonFeedback(pressed: configuration.isPressed, scales: scales))
    }
}

enum RelayPalette {
    static let ink = Color(red: 0.098, green: 0.098, blue: 0.098)
    static let secondary = Color(white: 0.38)
    static let accent = Color(white: 0.1)
    // Compatibility names used by the existing views and route picker.
    static let blue = Color(white: 0.15)
    static let deep = ink
    static let ice = Color(white: 0.96)
    static let paper = Color(red: 0.985, green: 0.985, blue: 0.98)
    static let sand = Color.white.opacity(0.46)
    static let line = ink.opacity(0.10)
}

enum RelayTypography {
    private static let registered: Void = {
        for name in ["ChakraPetch-Regular", "ChakraPetch-SemiBold"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()
    static func display(_ size: CGFloat, strong: Bool = false) -> Font {
        _ = registered
        return .system(size: size, weight: strong ? .bold : .semibold)
    }
}

struct RelayBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduced
    var body: some View {
        Color(white: 0.97).ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct FrostSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduced
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(RelayPalette.paper))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(RelayPalette.line, lineWidth: 1))
    }
}

extension View {
    func frost(_ radius: CGFloat = 18) -> some View { modifier(FrostSurface(radius: radius)) }
}

struct RelayPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body, design: .default).weight(.semibold))
            .foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RelayPalette.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .modifier(RelayButtonFeedback(pressed: configuration.isPressed, radius: 14))
    }
}

struct RelayQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body).weight(.medium)).foregroundStyle(RelayPalette.ink)
            .padding(.horizontal, 18).padding(.vertical, 13)
            .frame(minHeight: 44)
            .frost(12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .modifier(RelayButtonFeedback(pressed: configuration.isPressed))
    }
}

struct RelayBrand: View {
    var body: some View {
        HStack(spacing: 8) {
            PairItMark().frame(width: 26, height: 26)
            Text("PairIt").font(.system(size: 18, weight: .semibold)).tracking(-0.5)
        }.foregroundStyle(RelayPalette.ink)
    }
}

struct HeadphoneEmblem: View {
    var size: CGFloat = 108
    var body: some View {
        ZStack {
            Circle().fill(RelayPalette.accent.opacity(0.12)).frame(width: size * 1.22, height: size * 1.22)
            Circle().fill(RelayPalette.accent).frame(width: size, height: size)
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1).frame(width: size - 6, height: size - 6)
            HStack(spacing: size * 0.045) {
                ForEach(Array([0.16, 0.29, 0.48, 0.30, 0.60, 0.40, 0.22, 0.34, 0.14].enumerated()), id: \.offset) { _, height in
                    Capsule().fill(.white).frame(width: size * 0.035, height: size * height)
                }
            }
        }.frame(width: size * 1.3, height: size * 1.3).accessibilityHidden(true)
    }
}

struct RelayStatusPill: View {
    let title: String
    var active = false
    var busy = false
    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(active ? Color(red: 0.12, green: 0.58, blue: 0.48) : RelayPalette.blue.opacity(0.6)).frame(width: 6, height: 6).opacity(busy ? 0 : 1)
                if busy { ProgressView().controlSize(.mini).scaleEffect(0.7).accessibilityHidden(true) }
            }.frame(width: 10, height: 10)
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.6)
        }.foregroundStyle(RelayPalette.secondary).padding(.vertical, 6)
    }
}

struct RelaySettingRow: View {
    let icon: String
    let title: String
    var detail: String = ""
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(RelayPalette.blue)
                    .frame(width: 28, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(.body).weight(.medium)).foregroundStyle(RelayPalette.ink)
                    if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(RelayPalette.secondary) }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(RelayPalette.secondary)
            }.contentShape(Rectangle()).padding(.vertical, 12)
        }.buttonStyle(RelayControlButtonStyle(scales: false))
    }
}

/// Original headphones mark, shared by compact app headers.
struct PairItMark: View {
    var tint: Color = RelayPalette.ink
    var body: some View {
        Image(systemName: "headphones").resizable().scaledToFit().foregroundStyle(tint).accessibilityHidden(true)
    }
}
