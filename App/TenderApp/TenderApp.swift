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
                .font(.app(.body))
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Tender Dashboard", id: "dashboard") {
            DashboardView(model: model)
                .font(.app(.body))
                .frame(minWidth: 900, minHeight: 560)
        }

        Settings {
            SettingsView(model: model)
                .font(.app(.body))
        }
    }
}
