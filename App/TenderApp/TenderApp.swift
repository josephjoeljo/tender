import SwiftUI

@main
struct TenderApp: App {
    @State private var model = ClusterModel()

    var body: some Scene {
        MenuBarExtra("Tender", systemImage: model.health.symbol) {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Tender Dashboard", id: "dashboard") {
            DashboardView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
