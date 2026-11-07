#if os(macOS)
import AppKit
import SwiftUI
import TenderClient

/// The menu bar item: a named meter per node, or a plain symbol when there's nothing
/// to meter. Past a few nodes, an unlabelled dot per node takes less room.
struct MenuBarLabel: View {
    let model: ClusterModel
    /// Set by previews, to draw for a given menu bar. The real item follows the system.
    var appearance: NSAppearance? = nil

    var body: some View {
        let meters = NodeMeter.meters(nodes: model.nodes, processes: model.processes,
                                      clusterName: model.activeConnectionName)
        switch model.health {
        case .healthy where !meters.isEmpty, 
                .degraded where !meters.isEmpty:
            Image(nsImage: NodeMeterImage.make(meters, appearance: appearance))
                .accessibilityLabel(model.health.summary)
        default:
            Image(systemName: model.health.symbol)
                .accessibilityLabel(model.health.summary)
        }
    }
}

/// Drawn as an image, because a menu bar label can't lay out custom views.
enum NodeMeterImage {
    private static let height: CGFloat = 22
    private static let capsule = NSSize(width: 26, height: 7.5)
    private static let gap: CGFloat = 8
    private static let crownSize = NSSize(width: 10, height: 8)
    private static let crownGap: CGFloat = 2
    private static let headColor = NSColor.systemYellow

    static func font(size: CGFloat = 9) -> NSFont {
        .systemFont(ofSize: size)
    }

    private static func color(_ level: NodeMeter.Level) -> NSColor {
        switch level {
        case .healthy: .systemGreen
        case .degraded: .systemOrange
        case .down: .systemRed
        }
    }

    static func make(_ meters: [NodeMeter], appearance: NSAppearance? = nil) -> NSImage {
        meters.count > NodeMeter.maxMetersShown ? dots(meters) : labelled(meters, appearance: appearance)
    }

    /// Not a template image, so that colour survives. Text and outlines use label colours,
    /// resolved at draw time, so that they follow a light or dark menu bar.
    private static func labelled(_ meters: [NodeMeter], appearance: NSAppearance?) -> NSImage {
        let font = font()
        let crownWidth = crownSize.width + crownGap
        let widths = meters.map {
            let label = ($0.label as NSString).size(withAttributes: [.font: font]).width
            return max(label + ($0.isHead ? crownWidth : 0), capsule.width)
        }
        let width = widths.reduce(0, +) + gap * CGFloat(max(meters.count - 1, 0))
        let crownSymbol = NSImage(systemSymbolName: "crown.fill", accessibilityDescription: "Head node")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [headColor])))
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            let draw = {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
                var x: CGFloat = 0
                for (meter, slot) in zip(meters, widths) {
                    let size = (meter.label as NSString).size(withAttributes: attributes)
                    let content = size.width + (meter.isHead ? crownWidth : 0)
                    var textX = x + (slot - content) / 2
                    if meter.isHead {
                        crownSymbol?.draw(in: NSRect(x: textX, y: 11.5, width: crownSize.width, height: crownSize.height))
                        textX += crownWidth
                    }
                    (meter.label as NSString).draw(at: NSPoint(x: textX, y: 10.5), withAttributes: attributes)
                    // The meter is as wide as the name above it.
                    let frame = NSRect(x: x, y: 2, width: slot, height: capsule.height)
                    NSColor.tertiaryLabelColor.setStroke()
                    let outline = NSBezierPath(roundedRect: frame, xRadius: 2.5, yRadius: 2.5)
                    outline.lineWidth = 0.75
                    outline.stroke()
                    color(meter.level).setFill()
                    let inner = frame.insetBy(dx: 1.25, dy: 1.25)
                    let fill = NSRect(x: inner.minX, y: inner.minY, width: inner.width * meter.fraction, height: inner.height)
                    NSBezierPath(roundedRect: fill, xRadius: 1.25, yRadius: 1.25).fill()
                    x += slot + gap
                }
            }
            if let appearance {
                appearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func dots(_ meters: [NodeMeter]) -> NSImage {
        let size: CGFloat = 8
        let spacing: CGFloat = 4
        let width = CGFloat(meters.count) * (size + spacing) - spacing
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (index, meter) in meters.enumerated() {
                color(meter.level).setFill()
                let dot = NSBezierPath(ovalIn: NSRect(x: CGFloat(index) * (size + spacing), y: (height - size) / 2, width: size, height: size).insetBy(dx: 0.75, dy: 0.75))
                dot.fill()
                if meter.isHead {
                    headColor.setStroke()
                    dot.lineWidth = 1.5
                    dot.stroke()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

#if DEBUG
/// The label on a stand-in menu bar, in both appearances.
private struct MenuBarLabelPreviewBar: View {
    let model: ClusterModel
    let dark: Bool

    var body: some View {
        MenuBarLabel(model: model, appearance: NSAppearance(named: dark ? .darkAqua : .aqua))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(dark ? Color(white: 0.13) : Color(white: 0.88))
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

private struct MenuBarLabelPreviews: View {
    private let rows: [(String, ClusterModel)] = [
        ("Healthy", .previewHealthy), ("Degraded", .previewDegraded),
        ("More than 4 nodes", .previewMany), ("Not configured", .previewNotConfigured),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).font(.caption).foregroundStyle(.secondary)
                    MenuBarLabelPreviewBar(model: row.1, dark: true)
                    MenuBarLabelPreviewBar(model: row.1, dark: false)
                }
            }
        }
        .padding()
    }
}

#Preview("Menu bar label") { MenuBarLabelPreviews() }
#endif
#endif
