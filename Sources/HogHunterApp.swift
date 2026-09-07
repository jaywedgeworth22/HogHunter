import SwiftUI

@main
struct HogHunterApp: App {
    @StateObject private var store = HogStore()

    var body: some Scene {
        MenuBarExtra {
            HogHunterPanel()
                .environmentObject(store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "flame.fill")
                Text(store.menuBarLabel)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
