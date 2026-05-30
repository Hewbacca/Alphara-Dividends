import SwiftUI
import SwiftData

struct AddTickerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var existing: [TrackedCompany]

    @State private var query = ""
    @State private var results: [TickerSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    private let dataSource: DividendDataSource = PolygonClient()

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                ForEach(results) { result in
                    Button {
                        add(result)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.ticker).font(.headline)
                                Text(result.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isTracked(result.ticker) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(isTracked(result.ticker))
                }
            }
            .overlay {
                if isSearching {
                    ProgressView()
                } else if results.isEmpty && !query.isEmpty && errorMessage == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Add Ticker")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Symbol or company name")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: query) {
                await runSearch()
            }
        }
    }

    private func isTracked(_ ticker: String) -> Bool {
        existing.contains { $0.ticker == ticker.uppercased() }
    }

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        // Debounce typing.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await dataSource.searchTickers(query: term)
        } catch {
            if Task.isCancelled { return }
            results = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func add(_ result: TickerSearchResult) {
        guard !isTracked(result.ticker) else { return }
        context.insert(TrackedCompany(ticker: result.ticker, name: result.name))
        try? context.save()
        dismiss()
    }
}
