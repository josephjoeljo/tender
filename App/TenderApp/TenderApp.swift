import SwiftUI

@main
struct TenderApp: App {
    var body: some Scene {
        MenuBarExtra("Tender", systemImage: "leaf") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Window("Tender Dashboard", id: "dashboard") {
            DashboardView()
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
