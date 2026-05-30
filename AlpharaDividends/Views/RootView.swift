import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            UpcomingDividendsView()
                .tabItem { Label("Upcoming", systemImage: "calendar") }

            WatchlistView()
                .tabItem { Label("Watchlist", systemImage: "list.bullet") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

#Preview {
    RootView()
        .modelContainer(for: [TrackedCompany.self, DividendEvent.self], inMemory: true)
}
