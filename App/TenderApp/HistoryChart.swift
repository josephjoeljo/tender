import Charts
import SwiftUI

/// A point a `HistoryChart` can draw: one per time.
protocol ChartSample: Identifiable {
    var date: Date { get }
}

extension NodeSample: ChartSample {}

/// How far back a history page shows. Up to 24 hours the head serves heartbeats and
/// minutes; beyond that, quarter hours (7 and 30 days) and hours (6 months).
enum HistoryWindow {
    static let all: [(label: String, seconds: Double)] = [
        ("5m", 300), ("15m", 900), ("1h", 3600), ("6h", 6 * 3600), ("24h", 86400),
        ("7d", 7 * 86400), ("30d", 30 * 86400), ("6mo", 182 * 86400),
    ]

    /// The windows the head keeps enough history for; all of them when it doesn't say.
    static func available(keepingDays days: Int?) -> [(label: String, seconds: Double)] {
        guard let days else { return all }
        let fitting = all.filter { $0.seconds <= Double(days) * 86400 }
        return fitting.isEmpty ? [all[0]] : fitting
    }
}

/// The segmented window picker of the node and process history pages. A saved window
/// longer than the head keeps falls back to the longest one it does.
struct HistoryWindowPicker: View {
    @Binding var window: Double
    let keepingDays: Int?
    /// Stretch across a narrow column, like the inspector, instead of sizing to the labels.
    var fillsWidth = false

    var body: some View {
        let windows = HistoryWindow.available(keepingDays: keepingDays)
        Picker("Window", selection: $window) {
            ForEach(windows, id: \.seconds) { Text($0.label).tag($0.seconds) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: !fillsWidth, vertical: false)
        .onAppear { clamp(to: windows) }
        .onChange(of: keepingDays) { clamp(to: HistoryWindow.available(keepingDays: keepingDays)) }
    }

    private func clamp(to windows: [(label: String, seconds: Double)]) {
        guard !windows.contains(where: { $0.seconds == window }), let longest = windows.last else { return }
        window = windows.last(where: { $0.seconds < window })?.seconds ?? longest.seconds
    }
}

/// One titled chart of a few series over a fixed time window, as node and process history show.
struct HistoryChart<Sample: ChartSample>: View {
    struct Series {
        let name: String
        let color: Color
        let value: KeyPath<Sample, Double?>

        init(_ name: String, _ color: Color, _ value: KeyPath<Sample, Double?>) {
            self.name = name
            self.color = color
            self.value = value
        }

        init(_ name: String, _ color: Color, _ value: KeyPath<Sample, Double>) {
            self.init(name, color, value.appending(path: \.optional))
        }
    }

    /// The whole window, so the time axis doesn't stretch while history is still building up.
    let span: ClosedRange<Date>
    let title: String
    let samples: [Sample]
    let series: [Series]
    let format: (Double) -> String
    var domain: ClosedRange<Double>?
    /// Counts change in steps, so don't draw slopes between them.
    var step = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                ForEach(series, id: \.name) { line in
                    HStack(spacing: 4) {
                        Circle().fill(line.color).frame(width: 6, height: 6)
                        Text(samples.last.flatMap { $0[keyPath: line.value] }.map(format) ?? StatFormat.dash)
                            .font(.callout)
                    }
                    .help(line.name)
                }
            }
            Chart {
                ForEach(series, id: \.name) { line in
                    ForEach(samples) { sample in
                        if let value = sample[keyPath: line.value] {
                            LineMark(x: .value("Time", sample.date), y: .value(line.name, value),
                                     series: .value("Series", line.name))
                                .foregroundStyle(line.color)
                                .interpolationMethod(step ? .stepEnd : .monotone)
                            if series.count == 1 {
                                AreaMark(x: .value("Time", sample.date), y: .value(line.name, value))
                                    .foregroundStyle(line.color.opacity(0.12))
                                    .interpolationMethod(step ? .stepEnd : .monotone)
                            }
                        }
                    }
                }
            }
            .chartXScale(domain: span)
            .chartYScale(domain: domain ?? autoDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: timeFormat).font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(value.as(Double.self).map(format) ?? "").font(.caption2) }
                }
            }
            .frame(height: 120)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)) }
    }

    /// Days once the window is longer than two, so a 30-day axis doesn't read as times of day.
    private var timeFormat: Date.FormatStyle {
        span.upperBound.timeIntervalSince(span.lowerBound) > 2 * 86400
            ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute()
    }

    /// From zero (or below, for clock skew), with headroom, so a flat line doesn't fill the chart.
    private var autoDomain: ClosedRange<Double> {
        let values = samples.flatMap { sample in series.compactMap { sample[keyPath: $0.value] } }
        let low = min(values.min() ?? 0, 0) * 1.2
        return low...max((values.max() ?? 0) * 1.2, low + 1)
    }
}

private extension Double {
    var optional: Double? { self }
}

