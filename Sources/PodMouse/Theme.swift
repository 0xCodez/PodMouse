import AppKit
import CoreText
import SwiftUI

/// The one rule of the look: the interface is ink on pearl, and all colour comes from the light.
enum Theme {
    /// The Manrope weights in the app bundle.
    static func registerFonts() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    /// The hues of the light, for controls that carry a little of it.
    static let aurora = [
        Color(.displayP3, red: 0.48, green: 0.36, blue: 1.0),
        Color(.displayP3, red: 0.18, green: 0.66, blue: 1.0),
        Color(.displayP3, red: 0.24, green: 0.94, blue: 0.78),
        Color(.displayP3, red: 1.0, green: 0.36, blue: 0.54),
        Color(.displayP3, red: 1.0, green: 0.7, blue: 0.28),
    ]

    static let spring = Animation.spring(response: 0.46, dampingFraction: 0.78)
    static let snap = Animation.spring(response: 0.26, dampingFraction: 0.72)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

extension Font {
    /// Manrope, which keeps its size when the system text size changes, like menu text does.
    static func pod(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Manrope-Bold"
        case .semibold: name = "Manrope-SemiBold"
        case .regular, .light, .thin, .ultraLight: name = "Manrope-Regular"
        default: name = "Manrope-Medium"
        }
        return .custom(name, fixedSize: size)
    }
}

/// A colour with a light and a dark value, resolved from SwiftUI's environment so that
/// snapshots of either appearance come out right.
struct Adaptive: ShapeStyle {
    let light: Color
    let dark: Color

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? dark : light
    }
}

extension ShapeStyle where Self == Adaptive {
    /// The window behind everything.
    static var surface: Adaptive { Adaptive(light: Color(red: 0.965, green: 0.965, blue: 0.975), dark: Color(red: 0.075, green: 0.075, blue: 0.09)) }
    /// A control or card resting on the surface.
    static var raised: Adaptive { Adaptive(light: .white, dark: Color(white: 1, opacity: 0.07)) }
    static var hairline: Adaptive { Adaptive(light: Color(white: 0, opacity: 0.07), dark: Color(white: 1, opacity: 0.1)) }
    static var ink: Adaptive { Adaptive(light: Color(red: 0.07, green: 0.07, blue: 0.1), dark: Color(white: 0.96)) }
    static var ink2: Adaptive { Adaptive(light: Color(red: 0.07, green: 0.07, blue: 0.1).opacity(0.58), dark: Color(white: 1, opacity: 0.6)) }
    static var ink3: Adaptive { Adaptive(light: Color(red: 0.07, green: 0.07, blue: 0.1).opacity(0.34), dark: Color(white: 1, opacity: 0.34)) }
}
