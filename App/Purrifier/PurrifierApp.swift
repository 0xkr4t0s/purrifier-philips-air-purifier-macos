import SwiftUI

/// Placeholder for milestone M3. The real app adds a `DeviceStore` (`@Observable`, main actor)
/// that owns a long-lived session, plus settings, launch at login and notifications.
@main
struct PurrifierApp: App {
    var body: some Scene {
        MenuBarExtra("Purrifier", systemImage: "aqi.medium") {
            PlaceholderPanel()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct PlaceholderPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Purrifier")
                .font(.headline)
            Text("for Philips Air+ purifiers")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            Text("The menu bar controls arrive in milestone M3. Until then, `purrctl` has all the tricks.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Not affiliated with or endorsed by Philips or Versuni.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit Purrifier") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 280)
    }
}
