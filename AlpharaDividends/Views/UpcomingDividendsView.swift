import SwiftUI
import SwiftData

/// Owns the "today" threshold and refreshes it when the calendar day rolls over or
/// the app returns to the foreground, so past-paid dividends drop off the list without
/// needing a manual refresh. The actual list lives in `UpcomingDividendsList`, re-keyed
/// on `dayToken` so its `@Query` predicate is rebuilt against the current day.
struct UpcomingDividendsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var dayToken = DateUtil.startOfTodayUTC()

    var body: some View {
        UpcomingDividendsList(today: dayToken)
            .id(dayToken)
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                refreshDayToken()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshDayToken() }
            }
    }

    /// Recompute the day threshold, assigning only when it actually changed so we don't
    /// needlessly tear down and rebuild the list.
    private func refreshDayToken() {
        let current = DateUtil.startOfTodayUTC()
        if current != dayToken { dayToken = current }
    }
}

private struct UpcomingDividendsList: View {
    @Environment(\.modelContext) private var context
    @Query private var events: [DividendEvent]
    @State private var errorMessage: String?
    @State private var isSyncing = false

    init(today: Date) {
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
            try await service.syncAndNotify(context: context, force: true)
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
                if let symbol = event.change.symbolName {
                    Image(systemName: symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(event.change.color)
                }
                Text(CurrencyFormat.string(event.cashAmount, currency: event.currency))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(event.change.color)
            }
            HStack(spacing: 6) {
                Text(event.ticker).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(event.changeCaption).foregroundStyle(event.change.captionColor)
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
}
