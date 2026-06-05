import Foundation
import BackgroundTasks
import SwiftData
import os

/// Registers, schedules, and handles background refresh tasks.
///
/// Two task types are used:
/// - `BGAppRefreshTask` (≈30s): opportunistic, quick pass over the stalest tickers.
/// - `BGProcessingTask` (minutes): thorough pass that can cover 10+ tickers at 13s spacing.
///
/// Both call the same `syncAndNotify`; iOS decides when each runs. The processing task
/// is preferred on Wi-Fi/power, while the app-refresh fires more frequently.
enum BackgroundRefreshManager {
    static let refreshIdentifier    = "com.alphara.dividends.refresh"
    static let processingIdentifier = "com.alphara.dividends.processing"

    private static let logger = Logger(subsystem: "com.alphara.dividends", category: "background")
    private static var container: ModelContainer?

    /// Register both task handlers. Must be called before the app finishes launching.
    static func register(container: ModelContainer) {
        self.container = container

        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handleRefresh(task)
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handleProcessing(task)
        }
    }

    /// Submit both task requests. Call after launch and on entering background.
    static func scheduleAll() {
        scheduleRefresh()
        scheduleProcessing()
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Failed to schedule app-refresh task: \(error)")
        }
    }

    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Failed to schedule processing task: \(error)")
        }
    }

    private static func handleRefresh(_ task: BGAppRefreshTask) {
        logger.info("BGAppRefreshTask started")
        scheduleRefresh()
        runSync(label: "app-refresh", completing: { success in task.setTaskCompleted(success: success) }) { work in
            task.expirationHandler = { work.cancel() }
        }
    }

    private static func handleProcessing(_ task: BGProcessingTask) {
        logger.info("BGProcessingTask started")
        scheduleProcessing()
        runSync(label: "processing", completing: { success in task.setTaskCompleted(success: success) }) { work in
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Shared sync body used by both task types.
    private static func runSync(
        label: String,
        completing: @escaping (Bool) -> Void,
        registerExpiration: (Task<Void, Never>) -> Void
    ) {
        guard let container else {
            logger.error("[\(label)] No container — aborting")
            completing(false)
            return
        }

        let work = Task { @MainActor in
            // Network-free: alert for anything paying today regardless of the Wi-Fi gate.
            await DividendSyncService.notifyPaydays(context: container.mainContext)

            // Respect the user's "Wi-Fi only" preference for unattended background runs.
            if AppSettings.backgroundWifiOnly {
                let ok = await NetworkMonitor.isUnrestricted()
                if !ok {
                    logger.info("[\(label)] Wi-Fi gate blocked sync (cellular/hotspot path)")
                    completing(true) // try again at the next opportunity
                    return
                }
            }

            logger.info("[\(label)] Starting dividend sync")
            let service = DividendSyncService(dataSource: PolygonClient())
            do {
                let newEvents = try await service.syncAndNotify(context: container.mainContext)
                logger.info("[\(label)] Sync complete — \(newEvents.count) new event(s)")
                completing(true)
            } catch is CancellationError {
                logger.info("[\(label)] Sync cancelled by expiration handler")
                completing(false)
            } catch {
                logger.error("[\(label)] Sync failed: \(error)")
                completing(false)
            }
        }

        registerExpiration(work)
    }
}
