import AppKit
import SwiftUI

extension Font {
    /// The app's typeface at a text style's size, so it still scales with the user's text size.
    /// Berkeley Mono if it's installed, licensed or trial; it's never bundled. Otherwise the
    /// system font, with monospaced digits so stats still line up.
    static func app(_ style: Font.TextStyle) -> Font {
        guard let name = berkeleyMono else { return .system(style).monospacedDigit() }
        let font = Font.custom(name, size: style.pointSize, relativeTo: style)
        return style == .headline ? font.weight(.semibold) : font
    }

    /// For the few places that need an exact size, like row badges.
    static func app(size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        guard let name = berkeleyMono else { return .system(size: size).monospacedDigit() }
        return .custom(name, size: size, relativeTo: style)
    }

    private static let berkeleyMono = ["BerkeleyMono-Regular", "BerkeleyMonoTrial-Regular"]
        .first { NSFont(name: $0, size: 12) != nil }
}

private extension Font.TextStyle {
    /// macOS's default sizes for each style.
    var pointSize: CGFloat {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }
}
