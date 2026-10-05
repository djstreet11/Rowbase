import SwiftUI
@preconcurrency import Sparkle

/// Sparkle 2 auto-update (docs/UPDATES.md). Feed URL + public EdDSA key live in Info.plist (scripts/bundle.sh), so a
/// bare `swift run` / snapshot binary has no updater at all — nothing to check against, and it must not phone home.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController?
    var isAvailable: Bool { controller != nil }

    private init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil,
              ProcessInfo.processInfo.environment["ROWBASE_SNAPSHOT"] == nil else { controller = nil; return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Safe while a session is already running: Sparkle just brings its window to the front.
    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set { withMutation(keyPath: \.automaticallyChecks) { controller?.updater.automaticallyChecksForUpdates = newValue } }
    }
    var automaticallyDownloads: Bool {
        get { access(keyPath: \.automaticallyDownloads); return controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { withMutation(keyPath: \.automaticallyDownloads) { controller?.updater.automaticallyDownloadsUpdates = newValue } }
    }
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}

/// App menu item under "About Rowbase".
struct CheckForUpdatesButton: View {
    let updater: AppUpdater
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
    }
}

/// Settings → Updates (⌘,).
struct UpdatesSettingsView: View {
    @Bindable var updater: AppUpdater
    var body: some View {
        Form {
            if updater.isAvailable {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                Toggle("Automatically download and install updates", isOn: $updater.automaticallyDownloads)
                    .disabled(!updater.automaticallyChecks)
                LabeledContent("Current version", value: Self.version)
                LabeledContent("Last checked", value: updater.lastCheck.map {
                    $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                HStack {
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                }
            } else {
                Text("Updates are available only in the installed Rowbase.app.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }

    static var version: String {
        let i = Bundle.main.infoDictionary ?? [:]
        return "\(i["CFBundleShortVersionString"] as? String ?? "dev") (\(i["CFBundleVersion"] as? String ?? "0"))"
    }
}
