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

    /// Polygon free tier = 5 req/min, so space dividend calls ~12.5s apart.
    private static let throttleInterval: TimeInterval = 12.5

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
            let service = DividendSyncService(
                dataSource: PolygonClient(rateLimiter: RateLimiter(minInterval: throttleInterval))
            )
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
