import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The few places the Mac and iOS/iPadOS differ. Views stay shared and ask these instead.

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension EnvironmentValues {
    /// An iPhone, or an iPad window narrow enough to be laid out like one. Never on the Mac.
    var isCompactWidth: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }
}
