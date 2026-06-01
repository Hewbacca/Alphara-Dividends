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
                .task {
                    WatchlistBackup.shared.configure(context: container.mainContext)
                    await NotificationManager.requestAuthorization()
                    await DividendSyncService.notifyPaydays(context: container.mainContext)
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                BackgroundRefreshManager.schedule()
            case .active:
                // Cheap, network-free: catch any dividend paying today when the app opens.
                Task { await DividendSyncService.notifyPaydays(context: container.mainContext) }
            default:
                break
            }
        }
    }
}
