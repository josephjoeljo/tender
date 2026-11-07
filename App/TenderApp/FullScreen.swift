import AppKit
import SwiftUI

extension View {
    /// Lets the window go full screen from its green button or ⌃⌘F. SwiftUI only makes a
    /// menu bar app's (LSUIElement) windows full screen *auxiliary*, which zooms instead, and
    /// sets that again whenever the window's size limits change, so this puts back *primary* each time.
    func allowsFullScreen() -> some View {
        background(FullScreenCapable())
    }
}

private struct FullScreenCapable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowWatcher() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowWatcher: NSView {
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard let window else { return }
            Self.makePrimary(window)
            observation = window.observe(\.collectionBehavior) { window, _ in
                MainActor.assumeIsolated { Self.makePrimary(window) }
            }
        }

        /// One assignment, and only when it changes something: each one notifies the observer.
        private static func makePrimary(_ window: NSWindow) {
            var behavior = window.collectionBehavior
            behavior.subtract([.fullScreenAuxiliary, .fullScreenNone])
            behavior.insert(.fullScreenPrimary)
            if behavior != window.collectionBehavior { window.collectionBehavior = behavior }
        }
    }
}
