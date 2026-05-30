import SwiftUI
import SwiftData

struct UpcomingDividendsView: View {
    @Environment(\.modelContext) private var context
    @Query private var events: [DividendEvent]
    @State private var errorMessage: String?
    @State private var isSyncing = false

    init() {
        let today = Calendar.current.startOfDay(for: .now)
        // "Upcoming" = not yet paid: keep a dividend while its payment date (or, if
        // unknown, its ex-date) is today or later. This includes dividends that have
        // already gone ex-dividend but whose payment is still pending.
        _events = Query(
            filter: #Predicate<DividendEvent> { ($0.payDate ?? $0.exDate) >= today },
            sort: [SortDescriptor(\DividendEvent.payDate, order: .forward),
                   SortDescriptor(\DividendEvent.exDate, order: .forward)]
        )
    }

    /// Soonest upcoming event first, keyed by payment date (falling back to ex-date).
    private var sortedEvents: [DividendEvent] {
        events.sorted { ($0.payDate ?? $0.exDate) < ($1.payDate ?? $1.exDate) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if events.isEmpty {
                    ContentUnavailableView(
                        "No upcoming dividends",
                        systemImage: "calendar.badge.clock",
                        description: Text("Pull to refresh, or add tickers in the Watchlist tab.")
                    )
                } else {
                    List(sortedEvents) { event in
                        DividendRow(event: event)
                    }
                }
            }
            .navigationTitle("Upcoming")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isSyncing { ProgressView() }
                }
            }
            .refreshable { await runSync() }
            .alert("Sync failed", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func runSync() async {
        isSyncing = true
        defer { isSyncing = false }
        let service = DividendSyncService(dataSource: PolygonClient())
        do {
            try await service.syncAndNotify(context: context)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct DividendRow: View {
    let event: DividendEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(event.companyName).font(.headline)
                Spacer()
                Text(CurrencyFormat.string(event.cashAmount, currency: event.currency))
                    .font(.headline)
                    .monospacedDigit()
            }
            Text(event.ticker)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label(DateFormat.medium(event.exDate), systemImage: "calendar")
                if let pay = event.payDate {
                    Label(DateFormat.medium(pay), systemImage: "dollarsign.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
