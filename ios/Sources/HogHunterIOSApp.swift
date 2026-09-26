import SwiftUI

@main
struct HogHunterIOSApp: App {
    @State private var model = CompanionModel()

    var body: some Scene {
        WindowGroup {
            CompanionRootView(model: model)
                .preferredColorScheme(.light)
        }
    }
}
