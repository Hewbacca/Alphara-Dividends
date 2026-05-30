import SwiftUI
import SwiftData

@main
struct AlpharaDividendsApp: App {
    let container: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            container = try ModelContainer(for: TrackedCompany.self, DividendEvent.self)
        } catch {
            fatalError("Failed to create the SwiftData container: \(error)")
        }
        // Must be registered before launch completes.
        BackgroundRefreshManager.register(container: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task { await NotificationManager.requestAuthorization() }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                BackgroundRefreshManager.schedule()
            }
        }
    }
}
