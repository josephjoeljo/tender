import AppKit
import SwiftUI

@main
struct TenderApp: App {
    @State private var model: ClusterModel

    init() {
        #if DEBUG
        // Shows sample data, with no head: TENDER_APP_PREVIEW=healthy|degraded|many
        switch ProcessInfo.processInfo.environment["TENDER_APP_PREVIEW"] {
        case "healthy": _model = State(initialValue: .previewHealthy)
        case "degraded": _model = State(initialValue: .previewDegraded)
        case "many": _model = State(initialValue: .previewMany)
        default: _model = State(initialValue: ClusterModel())
        }
        #else
        _model = State(initialValue: ClusterModel())
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
                .font(.body)
        } label: {
            MenuBarLabel(model: model)
                #if DEBUG
                .modifier(OpenDashboardAtLaunch(model: model))
                #endif
        }
        .menuBarExtraStyle(.window)

        Window("Tender Dashboard", id: "dashboard") {
            DashboardView(model: model)
                .font(.body)
                .frame(minWidth: 900, minHeight: 560)
                // Lets the desktop show through, so the glass sidebar has something to refract.
                .containerBackground(.thinMaterial, for: .window)
        }

        // A process broken out of the dashboard. Opening the same one again brings its window forward.
        WindowGroup("Process", id: "process", for: ProcessRef.self) { $ref in
            ProcessWindow(model: model, ref: ref)
                .font(.body)
        }
        .defaultSize(width: 520, height: 680)

        Settings {
            SettingsView(model: model)
                .font(.body)
        }
    }
}

#if DEBUG
/// TENDER_APP_OPEN=nodes|processes|logs|releases|settings opens the dashboard on that page at
/// launch, so a build can be looked at without clicking through the menu bar; `process` pops
/// out the first process instead.
/// TENDER_APP_APPEARANCE=dark|light overrides the system appearance.
private struct OpenDashboardAtLaunch: ViewModifier {
    let model: ClusterModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            switch ProcessInfo.processInfo.environment["TENDER_APP_APPEARANCE"] {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
            if DashboardView.Section.atLaunch != nil { openWindow(id: "dashboard") }
            if ProcessInfo.processInfo.environment["TENDER_APP_OPEN"] == "process", let first = model.processes.first {
                openWindow(id: "process", value: ProcessRef(first))
            }
        }
    }
}
#endif
