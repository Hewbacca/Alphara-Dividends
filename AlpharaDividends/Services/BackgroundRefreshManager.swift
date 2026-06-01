import Foundation
import BackgroundTasks
import SwiftData

/// Registers, schedules, and handles the opportunistic background refresh.
///
/// NOTE: `BGAppRefreshTask` is scheduled by iOS at its discretion — it is best-effort,
/// not a guaranteed timer, and never runs while the app is force-quit. Foreground
/// pull-to-refresh remains the reliable path.
enum BackgroundRefreshManager {
    static let taskIdentifier = "com.alphara.dividends.refresh"

    private static var container: ModelContainer?

    /// Register the task handler. Must be called before the app finishes launching.
    static func register(container: ModelContainer) {
        self.container = container
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task)
        }
    }

    /// Ask iOS to run us again later. Call after launch and whenever entering background.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60) // ~4h
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule() // always queue the next run first

        guard let container else {
            task.setTaskCompleted(success: false)
            return
        }

        let work = Task { @MainActor in
            // Network-free: alert for anything paying today regardless of the Wi-Fi gate.
            await DividendSyncService.notifyPaydays(context: container.mainContext)

            // Respect the user's "Wi-Fi only" preference for unattended background runs.
            if AppSettings.backgroundWifiOnly, await !NetworkMonitor.isUnrestricted() {
                task.setTaskCompleted(success: true) // try again at the next opportunity
                return
            }

            // Uses the shared rate limiter (default) so foreground + background never
            // collectively exceed the free tier's request budget.
            let service = DividendSyncService(dataSource: PolygonClient())
            do {
                _ = try await service.syncAndNotify(context: container.mainContext)
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}
