import WidgetKit
import SwiftUI
import SwiftData

// MARK: - Snapshot model

/// A plain-value snapshot of a dividend for the timeline entry, decoupled from the SwiftData
/// `@Model` so it's safe to retain across timeline reloads.
struct DividendItem: Identifiable {
    let id: String
    let ticker: String
    let companyName: String
    let cashAmount: Double
    let currency: String
    let payDate: Date?
    let exDate: Date
    let change: DividendChange
    let caption: String
}

// MARK: - Timeline

struct DividendEntry: TimelineEntry {
    let date: Date
    let items: [DividendItem]
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> DividendEntry {
        DividendEntry(date: .now, items: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (DividendEntry) -> Void) {
        let items = Self.fetchUpcoming()
        completion(DividendEntry(date: .now, items: items.isEmpty ? Self.sample : items))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DividendEntry>) -> Void) {
        let entry = DividendEntry(date: .now, items: Self.fetchUpcoming())
        // Refresh at the next UTC midnight so paid-out dividends drop off automatically,
        // mirroring the in-app day-boundary behavior. The app also reloads timelines after
        // each sync via WidgetCenter.
        let nextMidnight = DateUtil.utcCalendar.date(
            byAdding: .day, value: 1, to: DateUtil.startOfTodayUTC()
        ) ?? .now.addingTimeInterval(60 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }

    /// Read upcoming dividends from the shared App Group store using the same filter/sort as
    /// the in-app Upcoming list: keep while `(payDate ?? exDate)` is today or later.
    static func fetchUpcoming() -> [DividendItem] {
        guard let container = try? SharedModelContainer.make() else { return [] }
        let context = ModelContext(container)
        let today = DateUtil.startOfTodayUTC()
        var descriptor = FetchDescriptor<DividendEvent>(
            predicate: #Predicate { ($0.payDate ?? $0.exDate) >= today },
            sortBy: [SortDescriptor(\.payDate, order: .forward),
                     SortDescriptor(\.exDate, order: .forward)]
        )
        descriptor.fetchLimit = 8
        guard let events = try? context.fetch(descriptor) else { return [] }
        return events.map {
            DividendItem(
                id: $0.id, ticker: $0.ticker, companyName: $0.companyName,
                cashAmount: $0.cashAmount, currency: $0.currency,
                payDate: $0.payDate, exDate: $0.exDate,
                change: $0.change, caption: $0.changeCaption
            )
        }
    }

    static let sample: [DividendItem] = [
        DividendItem(id: "1", ticker: "AAPL", companyName: "Apple Inc.",
                     cashAmount: 0.25, currency: "USD",
                     payDate: .now.addingTimeInterval(86_400 * 3), exDate: .now,
                     change: .increased, caption: "Increased from $0.24 (+4.2%)"),
        DividendItem(id: "2", ticker: "KO", companyName: "Coca-Cola Co.",
                     cashAmount: 0.485, currency: "USD",
                     payDate: .now.addingTimeInterval(86_400 * 9), exDate: .now,
                     change: .unchanged, caption: "Unchanged"),
        DividendItem(id: "3", ticker: "HD", companyName: "Home Depot Inc.",
                     cashAmount: 2.25, currency: "USD",
                     payDate: .now.addingTimeInterval(86_400 * 14), exDate: .now,
                     change: .increased, caption: "Increased from $2.09 (+7.7%)"),
    ]
}

// MARK: - Views

struct UpcomingDividendsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DividendEntry

    private var rowLimit: Int { family == .systemLarge ? 6 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Upcoming Dividends")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "calendar.badge.clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            if entry.items.isEmpty {
                Spacer()
                Text("No upcoming dividends")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ForEach(Array(entry.items.prefix(rowLimit))) { item in
                    DividendWidgetRow(item: item)
                    if item.id != entry.items.prefix(rowLimit).last?.id {
                        Divider().opacity(0.4)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct DividendWidgetRow: View {
    let item: DividendItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.companyName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.ticker)
                    if let pay = item.payDate {
                        Text("·")
                        Text(DateFormat.medium(pay))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                if let symbol = item.change.symbolName {
                    Image(systemName: symbol).font(.caption2.weight(.bold))
                }
                Text(CurrencyFormat.string(item.cashAmount, currency: item.currency))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(item.change.color)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Widget

struct UpcomingDividendsWidget: Widget {
    private let kind = "UpcomingDividendsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            UpcomingDividendsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Upcoming Dividends")
        .description("Your next upcoming dividend payments.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
