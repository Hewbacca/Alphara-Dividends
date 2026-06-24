import Foundation
import SwiftData

/// The App Group shared between the app and its widget extension. Both processes open the
/// same SwiftData store from this container so the widget sees live data.
enum AppGroup {
    static let id = "group.com.alphara.dividends"
}

/// Builds the shared `ModelContainer` backed by a store inside the App Group container,
/// so the widget extension (a separate process) can read the same data the app writes.
enum SharedModelContainer {
    /// Filename of the shared store inside the App Group container.
    private static let storeName = "Dividends.store"
    /// SQLite sidecar suffixes that must travel with the main store file.
    private static let sidecarSuffixes = ["", "-wal", "-shm"]

    /// Create (or open) the shared container, migrating a pre-App-Group store on first run.
    static func make() throws -> ModelContainer {
        let url = sharedStoreURL()
        migrateLegacyStoreIfNeeded(to: url)
        let config = ModelConfiguration(url: url)
        return try ModelContainer(for: TrackedCompany.self, DividendEvent.self, configurations: config)
    }

    /// URL of the shared store inside the App Group container.
    private static func sharedStoreURL() -> URL {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id) else {
            // Misconfigured App Group entitlement — fall back to the app's own Application
            // Support dir so the app still runs (the widget just won't see data).
            return URL.applicationSupportDirectory.appending(path: storeName)
        }
        return dir.appending(path: storeName)
    }

    /// One-time copy of the original default-location SwiftData store into the App Group,
    /// so existing users keep their dividends/watchlist when the store relocates. Idempotent:
    /// runs only when the destination is absent and a legacy store exists.
    private static func migrateLegacyStoreIfNeeded(to destination: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }

        let legacy = URL.applicationSupportDirectory.appending(path: "default.store")
        guard fm.fileExists(atPath: legacy.path) else { return }

        // The "-wal"/"-shm" suffixes aren't real path extensions, so build the names by string.
        let destDir = destination.deletingLastPathComponent()
        for suffix in sidecarSuffixes {
            let from = URL.applicationSupportDirectory.appending(path: "default.store\(suffix)")
            let to = destDir.appending(path: "\(storeName)\(suffix)")
            if fm.fileExists(atPath: from.path) {
                try? fm.copyItem(at: from, to: to)
            }
        }
    }
}
