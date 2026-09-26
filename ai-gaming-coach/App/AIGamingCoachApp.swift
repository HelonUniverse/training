import SwiftUI

@main
struct AIGamingCoachApp: App {
    @State private var model = CoachModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.activate()
            default: model.deactivate()
            }
        }
    }
}
