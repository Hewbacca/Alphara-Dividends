import SwiftUI
import SwiftData

struct UpcomingDividendsView: View {
    @Environment(\.modelContext) private var context
    @Query private var events: [DividendEvent]
    @State private var errorMessage: String?
    @State private var isSyncing = false

    init() {
        let today = Calendar.current.startOfDay(for: .now)
        _events = Query(
            filter: #Predicate<DividendEvent> { $0.exDate >= today },
            sort: [SortDescriptor(\DividendEvent.exDate, order: .forward)]
        )
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
                    List(events) { event in
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
