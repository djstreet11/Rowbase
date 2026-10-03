import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
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
                    if let id = state.activeTabID { state.closeTab(id) } else { NSApp.keyWindow?.performClose(nil) }
                }.keyboardShortcut("w")
            }
            CommandMenu("Database") {
                Button("Run") { state.runActive() }.keyboardShortcut(.return, modifiers: .command)
                Button("Refresh") { state.refresh(); if let t = state.activeTab, !t.isQuery { t.info = nil; Task { await state.reload(t) } } }.keyboardShortcut("r")
                Divider()
                Button("Find Table") { state.filterFocusTick += 1 }.keyboardShortcut("p")
                Button("Connections…") { state.showConnections = true }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("History") { state.showHistory = true }.keyboardShortcut("y")
            }
        }
    }
}
