import SwiftUI
import SwiftData
import UserNotifications
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var apiKey = ""
    @State private var savedConfirmation = false
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @AppStorage(AppSettings.backgroundWifiOnlyKey) private var backgroundWifiOnly = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Polygon API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") { saveKey() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Get a free key at polygon.io", destination: URL(string: "https://polygon.io/dashboard/signup")!)
                        .font(.footnote)
                } header: {
                    Text("Data source")
                } footer: {
                    Text("Your key is stored in the device Keychain. The free tier allows 5 requests/minute with end-of-day data.")
                }

                Section {
                    Button {
                        Task { await syncNow() }
                    } label: {
                        HStack {
                            Text("Refresh now")
                            Spacer()
                            if isSyncing { ProgressView() }
                        }
                    }
                    .disabled(isSyncing)
                    if let syncMessage {
                        Text(syncMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Dividends")
                } footer: {
                    Text("Checks are paced to stay within the free tier's 5 requests/minute, so a refresh can take up to a minute. It keeps running if you switch tabs.")
                }

                Section {
                    Toggle("Background refresh on Wi-Fi only", isOn: $backgroundWifiOnly)
                } header: {
                    Text("Background")
                } footer: {
                    Text("When on, automatic background checks are skipped on cellular to save data. “Refresh now” and pull-to-refresh always work regardless of this setting.")
                }

                Section {
                    HStack {
                        Text("Notifications")
                        Spacer()
                        Text(notifStatusText).foregroundStyle(.secondary)
                    }
                    if notifStatus == .denied {
                        Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    } else if notifStatus == .notDetermined {
                        Button("Enable notifications") {
                            Task {
                                await NotificationManager.requestAuthorization()
                                notifStatus = await NotificationManager.authorizationStatus()
                            }
                        }
                    }
                } footer: {
                    Text("New-dividend alerts are delivered as local notifications. Background checks run opportunistically when iOS allows; use “Refresh now” or pull-to-refresh for an immediate check.")
                }
            }
            .navigationTitle("Settings")
            .task {
                apiKey = KeychainStore.apiKey ?? ""
                notifStatus = await NotificationManager.authorizationStatus()
            }
            .alert("Saved", isPresented: $savedConfirmation) {
                Button("OK") {}
            }
        }
    }

    private var notifStatusText: String {
        switch notifStatus {
        case .authorized: return "On"
        case .denied: return "Off"
        case .notDetermined: return "Not set"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }

    private func saveKey() {
        KeychainStore.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        savedConfirmation = true
    }

    private func syncNow() async {
        isSyncing = true
        syncMessage = nil
        defer { isSyncing = false }
        let service = DividendSyncService(dataSource: PolygonClient())
        do {
            let new = try await service.syncAndNotify(context: context)
            syncMessage = new.isEmpty ? "No new dividends found." : "Found \(new.count) new dividend(s)."
        } catch {
            syncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
