import SwiftUI
import AppKit
import RowbaseCore

struct AIMCPSheet: View {
    let state: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Client: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code", claudeDesktop = "Claude Desktop", cursor = "Cursor", vscode = "VS Code", codex = "Codex"
        var id: String { rawValue }
    }

    @State private var settings = MCPSettings()
    @State private var loaded = MCPSettings()
    @State private var cli: URL?
    @State private var config: MCPClientConfig?
    @State private var loadingConfig = true
    @State private var client: Client = .claudeCode
    @State private var copied: String?
    @State private var statusText = ""
    @State private var statusIsError = false

    private let missingText = "The MCP server binary wasn't found in this build. Build it with `python packaging/build.py` or install the rowbase CLI."

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MCP lets AI assistants explore and query your saved connections through the Rowbase server.")
                        Text("Copy the prompt into your assistant — it registers Rowbase, reads the built-in guide and creates a skill.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Section("Setup prompt") {
                    if let text = snippetOrNil(config?.prompt) {
                        codeBox(text, height: 120)
                        HStack {
                            Spacer()
                            copyButton(text, id: "prompt", title: "Copy Prompt", prominent: true)
                        }
                    } else { placeholder }
                }
                Section("Access") {
                    Toggle("Allow writes", isOn: $settings.allowWrites)
                    Text("Only on connections that are write-enabled; changes are always previewed and atomic.")
                        .font(.caption).foregroundStyle(.secondary)
                    if settings.allowWrites {
                        Label("Assistants will be able to modify data on write-enabled connections", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.callout)
                    }
                    Picker("Result format", selection: $settings.format) {
                        Text("TOON — fewest tokens").tag("toon")
                        Text("CSV").tag("csv")
                        Text("Markdown").tag("md")
                        Text("JSON").tag("json")
                    }
                    Picker("Tool set", selection: $settings.toolset) {
                        Text("Full — 10 tools").tag("full")
                        Text("Minimal — 5 tools").tag("minimal")
                    }
                    Stepper(value: $settings.maxRows, in: 1...5000, step: 50) {
                        HStack {
                            Text("Max rows per call"); Spacer()
                            TextField("", value: $settings.maxRows, format: .number.grouping(.never))
                                .multilineTextAlignment(.trailing).frame(width: 60).labelsHidden()
                        }
                    }
                    Stepper(value: $settings.timeout, in: 1...600, step: 5) {
                        HStack {
                            Text("Timeout (s)"); Spacer()
                            TextField("", value: $settings.timeout, format: .number.grouping(.never))
                                .multilineTextAlignment(.trailing).frame(width: 60).labelsHidden()
                        }
                    }
                }
                Section("Connections exposed to MCP") {
                    Toggle("All connections", isOn: Binding(get: { settings.connections == nil },
                                                            set: { settings.connections = $0 ? nil : state.connections.map(\.name) }))
                    if settings.connections != nil {
                        if state.connections.isEmpty {
                            Text("No connections yet.").foregroundStyle(.secondary)
                        }
                        ForEach(state.connections) { c in
                            Toggle(isOn: Binding(get: { settings.connections?.contains(c.name) ?? false },
                                                 set: { on in
                                var l = settings.connections ?? []
                                if on { if !l.contains(c.name) { l.append(c.name) } } else { l.removeAll { $0 == c.name } }
                                settings.connections = l
                            })) {
                                HStack(spacing: 8) {
                                    ConnDot(color: c.color)
                                    Text(c.name).lineLimit(1)
                                    Text(c.dialect.title).font(.caption).foregroundStyle(.secondary)
                                    if !c.readOnly { Text("read-write").font(.caption).foregroundStyle(.red) }
                                }
                            }
                        }
                    }
                }
                Section("Manual setup") {
                    if cli == nil { placeholder } else if loadingConfig {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
                    } else if let text = snippetOrNil(snippet) {
                        Picker("Client", selection: $client) {
                            ForEach(Client.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        codeBox(text, height: 90)
                        HStack {
                            Spacer()
                            copyButton(text, id: "snippet", title: "Copy", prominent: false)
                        }
                    } else {
                        Text("Couldn't read the client configuration from the MCP server binary.").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 720, height: 640)
        .task { await start() }
    }

    // MARK: pieces

    private var snippet: String? {
        guard let c = config else { return nil }
        switch client {
        case .claudeCode: return c.claudeCode
        case .claudeDesktop: return c.claudeDesktop
        case .cursor: return c.cursor
        case .vscode: return c.vscode
        case .codex: return c.codex
        }
    }

    private func snippetOrNil(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

    @ViewBuilder private var placeholder: some View {
        if cli == nil {
            Text(missingText).font(.callout).foregroundStyle(.secondary)
        } else if loadingConfig {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
        } else {
            Text("Couldn't read the setup prompt from the MCP server binary.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func codeBox(_ text: String, height: CGFloat) -> some View {
        ScrollView {
            SelectableText(text, font: .mono(11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: height)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder private func copyButton(_ text: String, id: String, title: String, prominent: Bool) -> some View {
        let label = copied == id ? "Copied" : title
        let icon = copied == id ? "checkmark" : "doc.on.doc"
        if prominent {
            Button { copy(text, id: id) } label: { Label(label, systemImage: icon) }
                .buttonStyle(.borderedProminent).controlSize(.regular)
        } else {
            Button { copy(text, id: id) } label: { Label(label, systemImage: icon) }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(statusText).font(.caption).foregroundStyle(statusIsError ? Color.red : Color.secondary).lineLimit(2)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { save() }.keyboardShortcut(.defaultAction)
                .background(Button("") { save() }.keyboardShortcut("s", modifiers: .command).opacity(0).frame(width: 0, height: 0))
        }
        .controlSize(.small)
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: actions

    private func start() async {
        let home = state.store.home
        settings = MCPSettings.load(home: home)
        loaded = settings
        let found = MCPSupport.locateCLI()
        cli = found
        guard let found else { loadingConfig = false; return }
        let cfg = await Task.detached(priority: .userInitiated) { MCPSupport.fetchConfig(cli: found) }.value
        config = cfg
        loadingConfig = false
    }

    private func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == id { copied = nil }
        }
    }

    private func save() {
        do {
            try settings.save(home: state.store.home)
            loaded = settings
            statusText = "Saved"; statusIsError = false
            Task { try? await Task.sleep(for: .milliseconds(400)); dismiss() }
        } catch {
            statusText = error.localizedDescription; statusIsError = true
        }
    }
}
