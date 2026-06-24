import SwiftUI
import SwiftData

@main
struct AlpharaDividendsApp: App {
    let container: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            container = try SharedModelContainer.make()
        } catch {
            fatalError("Failed to create the SwiftData container: \(error)")
        }
        // Must be registered before launch completes.
        BackgroundRefreshManager.register(container: container)
        BackgroundRefreshManager.scheduleAll()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    WatchlistBackup.shared.configure(context: container.mainContext)
                    await NotificationManager.requestAuthorization()
                    await DividendSyncService.reschedulePaydayNotifications(context: container.mainContext)
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                BackgroundRefreshManager.scheduleAll()
            case .active:
                // Reschedule pre-scheduled alerts and fire an immediate banner if today's
                // 8:30 am slot already passed (e.g. app opened later in the day).
                Task { await DividendSyncService.reschedulePaydayNotifications(context: container.mainContext) }
            default:
                break
            }
        }
    }
}
