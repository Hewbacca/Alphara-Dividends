import Foundation
import SwiftData

/// Mirrors the watchlist to iCloud's key-value store so it survives app deletion /
/// reinstall (and appears on the user's other devices).
///
/// SwiftData already persists locally across app *updates*; this adds durability across
/// *reinstalls*, where the local store is wiped. The watchlist is tiny (ticker + name per
/// entry), so the 1 MB key-value-store limit is never a concern.
///
/// Reconciliation is a union: on launch we import any iCloud-backed tickers missing
/// locally, then push the local list back up. Deletions update iCloud immediately so a
/// removed ticker doesn't reappear on the same device.
@MainActor
final class WatchlistBackup {
    static let shared = WatchlistBackup()

    private let key = "watchlist.v1"
    private let store = NSUbiquitousKeyValueStore.default
    private weak var context: ModelContext?
    private var observer: NSObjectProtocol?

    private init() {}

    /// Wire up on launch: start observing iCloud changes, import remote entries, back up local.
    func configure(context: ModelContext) {
        self.context = context

        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in self?.restoreMissing() }
            }
        }

        store.synchronize()
        restoreMissing()  // reinstall / new-device case
        backupCurrent()   // ensure iCloud reflects what's here now
    }

    /// Replace the iCloud-stored watchlist with the current local one.
    func backupCurrent() {
        guard let context else { return }
        let companies = (try? context.fetch(FetchDescriptor<TrackedCompany>())) ?? []
        let payload = companies.map { ["t": $0.ticker, "n": $0.name] }
        store.set(payload, forKey: key)
        store.synchronize()
    }

    /// Insert any iCloud-backed tickers that aren't present locally.
    @discardableResult
    func restoreMissing() -> Int {
        guard let context else { return 0 }
        guard let payload = store.array(forKey: key) as? [[String: String]] else { return 0 }

        let existing = Set(
            ((try? context.fetch(FetchDescriptor<TrackedCompany>())) ?? [])
                .map { $0.ticker.uppercased() }
        )

        var restored = 0
        for entry in payload {
            guard let ticker = entry["t"]?.uppercased(), !ticker.isEmpty,
                  !existing.contains(ticker) else { continue }
            context.insert(TrackedCompany(ticker: ticker, name: entry["n"] ?? ticker))
            restored += 1
        }
        if restored > 0 { try? context.save() }
        return restored
    }
}
