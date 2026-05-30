import SwiftUI
import SwiftData

struct WatchlistView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TrackedCompany.name) private var companies: [TrackedCompany]
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if companies.isEmpty {
                    ContentUnavailableView(
                        "No tickers yet",
                        systemImage: "magnifyingglass",
                        description: Text("Tap + to search for a company and start tracking its dividends.")
                    )
                } else {
                    List {
                        ForEach(companies) { company in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(company.ticker).font(.headline)
                                Text(company.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Watchlist")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddTickerView()
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let company = companies[index]
            let ticker = company.ticker
            // Prune discovered events for this ticker too.
            let descriptor = FetchDescriptor<DividendEvent>(
                predicate: #Predicate { $0.ticker == ticker }
            )
            if let events = try? context.fetch(descriptor) {
                for event in events { context.delete(event) }
            }
            context.delete(company)
        }
        try? context.save()
    }
}
