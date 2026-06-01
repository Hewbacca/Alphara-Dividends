import SwiftUI
import SwiftData

struct UpcomingDividendsView: View {
    @Environment(\.modelContext) private var context
    @Query private var events: [DividendEvent]
    @State private var errorMessage: String?
    @State private var isSyncing = false

    init() {
        let today = DateUtil.startOfTodayUTC()
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

    /// Row highlight: green when it pays today, blue when it goes ex-dividend today.
    /// (Payment-day takes precedence if both somehow fall today.)
    private func rowBackground(for event: DividendEvent) -> Color? {
        if let pay = event.payDate, DateUtil.isTodayUTC(pay) { return .green.opacity(0.18) }
        if DateUtil.isTodayUTC(event.exDate) { return .blue.opacity(0.18) }
        return nil
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
                            .listRowBackground(rowBackground(for: event))
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
            HStack(alignment: .firstTextBaseline) {
                Text(event.companyName).font(.headline)
                Spacer()
                if let symbol = changeSymbol {
                    Image(systemName: symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(changeColor)
                }
                Text(CurrencyFormat.string(event.cashAmount, currency: event.currency))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(changeColor)
            }
            HStack(spacing: 6) {
                Text(event.ticker)
                if let caption = changeCaption {
                    Text("·")
                    Text(caption)
                }
            }
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

    private var changeColor: Color {
        switch event.change {
        case .increased: return .green
        case .decreased: return .red
        case .unchanged, .new: return .primary
        }
    }

    private var changeSymbol: String? {
        switch event.change {
        case .increased: return "arrow.up"
        case .decreased: return "arrow.down"
        case .unchanged, .new: return nil
        }
    }

    /// Secondary caption next to the ticker, e.g. "from $0.25" or "New".
    private var changeCaption: String? {
        switch event.change {
        case .new: return "New"
        case .increased, .decreased:
            guard let prev = event.previousAmount else { return nil }
            return "from \(CurrencyFormat.string(prev, currency: event.currency))"
        case .unchanged: return nil
        }
    }
}
