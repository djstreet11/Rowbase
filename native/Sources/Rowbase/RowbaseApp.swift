import SwiftUI
import RowbaseCore
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        TunnelManager.shutdown()  // don't leave ssh -L processes behind
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct RowbaseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Rowbase") {
            MainView(state: state)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New SQL Tab") { state.openQuery() }.keyboardShortcut("t")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") {
                    if let id = state.activeTabID { state.requestClose(id) } else { NSApp.keyWindow?.performClose(nil) }
                }.keyboardShortcut("w")
            }
            CommandGroup(replacing: .sidebar) {
                Button(state.showSidebar ? "Hide Sidebar" : "Show Sidebar") { state.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button(state.showInspector ? "Hide Inspector" : "Show Inspector") { state.toggleInspector() }
                    .keyboardShortcut("i", modifiers: .command)
            }
            CommandMenu("Database") {
                Button("Run") { state.runActive() }.keyboardShortcut(.return, modifiers: .command)
                Button("Refresh") {
                    state.refresh()
                    if let t = state.activeTab, !t.isQuery {
                        state.guardPending(t) { t.info = nil; Task { await state.reload(t) } }
                    }
                }.keyboardShortcut("r")
                Divider()
                Button("Find Table") { state.filterFocusTick += 1 }.keyboardShortcut("p")
                Button("Connections…") { state.showConnections = true }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("History") { state.showHistory = true }.keyboardShortcut("y")
            }
        }
    }
}
