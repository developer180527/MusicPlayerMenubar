import SwiftUI
import ServiceManagement

struct SettingsView: View {

    @State private var startAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Start at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("Login item error: \(error.localizedDescription)")
                            startAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }

                Text("Automatically launch MusicPlayerMenubar when you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340, height: 120)
        .onAppear {
            startAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
