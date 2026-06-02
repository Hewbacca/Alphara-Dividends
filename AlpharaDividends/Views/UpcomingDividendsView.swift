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
    /// Compared against the user's LOCAL calendar day so the highlight stays on until
    /// midnight in the user's own timezone (not UTC midnight). Payment-day wins if both.
    private func rowBackground(for event: DividendEvent) -> Color? {
        if let pay = event.payDate, DateUtil.isLocalToday(pay) { return .green.opacity(0.18) }
        if DateUtil.isLocalToday(event.exDate) { return .blue.opacity(0.18) }
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
                Text(event.ticker).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(changeCaption).foregroundStyle(captionColor)
            }
            .font(.caption)
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

    /// Color of the amount: green for increases, red for cuts, default otherwise.
    private var changeColor: Color {
        switch event.change {
        case .increased: return .green
        case .decreased: return .red
        case .unchanged, .new: return .primary
        }
    }

    /// SF Symbol shown before the amount.
    private var changeSymbol: String? {
        switch event.change {
        case .increased: return "arrow.up"
        case .decreased: return "arrow.down"
        case .unchanged: return "equal"
        case .new: return nil
        }
    }

    /// Color of the status caption (secondary for unchanged/new so it reads as informational).
    private var captionColor: Color {
        switch event.change {
        case .increased: return .green
        case .decreased: return .red
        case .unchanged, .new: return .secondary
        }
    }

    /// Status caption next to the ticker — always present, e.g. "Increased from $0.25 (+4.0%)",
    /// "Cut from $0.25 (-20.0%)", "Unchanged", "New".
    private var changeCaption: String {
        switch event.change {
        case .new: return "New"
        case .unchanged: return "Unchanged"
        case .increased, .decreased:
            guard let prev = event.previousAmount, prev > 0 else {
                return event.change == .increased ? "Increased" : "Cut"
            }
            let prevStr = CurrencyFormat.string(prev, currency: event.currency)
            let pct = (event.cashAmount - prev) / prev * 100
            let sign = pct >= 0 ? "+" : ""
            let pctStr = String(format: "\(sign)%.1f%%", pct)
            let verb = event.change == .increased ? "Increased" : "Cut"
            return "\(verb) from \(prevStr) (\(pctStr))"
        }
    }
}
