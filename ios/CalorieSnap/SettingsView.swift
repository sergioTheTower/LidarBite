import SwiftUI

struct SettingsView: View {
    @ObservedObject var api: APIClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend") {
                    TextField("Server URL", text: $api.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API key", text: $api.apiKey)
                }
                Section("Scale") {
                    TextField("Plate weight (g)", text: $api.tareGrams)
                        .keyboardType(.numberPad)
                }
                Section {
                    Text("Point this at your Komodo stack, e.g. https://calories.yourdomain.com. The API key must match API_KEY on the server.\n\nPlate weight is subtracted from the number Claude reads on your scale, so you can weigh food on a plate without zeroing the scale each time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
