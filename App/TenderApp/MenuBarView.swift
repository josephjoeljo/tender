import SwiftUI
import TenderCore

/// Quick glance: cluster health and recent problems. Data comes from the head
/// via TenderClient (milestone 2); placeholders for now.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("No head connected", systemImage: "circle.dashed")
                .font(.headline)
            Text("Nodes and processes will show here once tenderd is running.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Open dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 300)
    }
}
