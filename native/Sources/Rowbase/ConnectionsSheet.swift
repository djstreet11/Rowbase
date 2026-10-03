import SwiftUI
import AppKit
import RowbaseCore

struct ConnectionsSheet: View {
    let state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var draft = Connection(readOnly: true)
    @State private var isNew = true
    @State private var password = ""
    @State private var portText = ""
    @State private var pasteURL = ""
    @State private var useColor = false
    @State private var color = Color.accentColor
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var errorText: String?
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                form
                Divider()
                footer
            }
        }
        .frame(width: 760, height: 540)
        .onAppear {
            if let id = state.selectedConnectionID, let c = state.connections.first(where: { $0.id == id }) {
                selection = id; load(c)
            } else if let c = state.connections.first {
                selection = c.id; load(c)
            } else { startNew() }
        }
        .onChange(of: selection) {
            if let id = selection, id != draft.id || isNew, let c = state.connections.first(where: { $0.id == id }) { load(c) }
        }
        .onChange(of: pasteURL) { applyPaste() }
        .onChange(of: portText) { draft.port = Int(portText.trimmingCharacters(in: .whitespaces)) }
        .confirmationDialog("Delete connection \(draft.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
        }
    }

    // MARK: list

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(state.connections) { c in
                    HStack(spacing: 8) {
                        ConnDot(color: c.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name).lineLimit(1)
                            HStack(spacing: 4) {
                                Text([c.dialect.title, c.env].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if !c.readOnly { Text("read-write").font(.caption).foregroundStyle(.red) }
                            }
                        }
                    }
                    .tag(c.id)
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button { startNew() } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
                Spacer()
            }
            .padding(8)
        }
    }

    // MARK: form

    private func opt(_ kp: WritableKeyPath<Connection, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: kp] ?? "" }, set: { draft[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                Picker("Driver", selection: Binding(get: { draft.dialect }, set: { draft.driver = $0.rawValue })) {
                    ForEach(Dialect.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Read-only", isOn: $draft.readOnly)
                if !draft.readOnly {
                    Label("Writes will be committed to this database", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                }
                TextField("Paste URL", text: $pasteURL, prompt: Text("mysql://user:pass@host:3306/db"))
            }
            Section {
                if draft.dialect == .sqlite {
                    HStack {
                        TextField("Path", text: opt(\.path))
                        Button("Choose…") { choose() }
                    }
                } else {
                    TextField("Host", text: opt(\.host), prompt: Text("127.0.0.1"))
                    TextField("Port", text: $portText, prompt: Text(draft.dialect.defaultPort.map(String.init) ?? ""))
                    TextField("Socket", text: opt(\.socket), prompt: Text("optional"))
                    TextField("Database", text: opt(\.database))
                    TextField("User", text: opt(\.user))
                    SecureField("Password", text: $password, prompt: Text(isNew ? "" : "unchanged"))
                }
            }
            Section {
                Picker("Env", selection: Binding(get: { draft.env ?? "" }, set: { draft.env = $0.isEmpty ? nil : $0 })) {
                    Text("none").tag("")
                    ForEach(ConnectionStore.envs, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Toggle("Color", isOn: $useColor)
                    if useColor { ColorPicker("", selection: $color).labelsHidden() }
                    else { Text("None").foregroundStyle(.secondary) }
                }
                TextField("Group", text: opt(\.group))
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !isNew { Button("Delete", role: .destructive) { confirmDelete = true } }
            Button("Test") { test() }.disabled(testing)
            if testing { ProgressView().controlSize(.small) }
            if let r = testResult {
                Text(r.text).font(.caption).foregroundStyle(r.ok ? Color.green : Color.red).lineLimit(2).textSelection(.enabled)
            }
            if let e = errorText { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { save() }.keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(10)
    }

    // MARK: actions

    private func load(_ c: Connection) {
        draft = c
        isNew = false
        password = ""
        pasteURL = ""
        portText = c.port.map(String.init) ?? ""
        if let col = hexColor(c.color) { useColor = true; color = col } else { useColor = false }
        testResult = nil; errorText = nil
    }

    private func startNew() {
        draft = Connection(name: "", driver: "mysql", readOnly: true)
        isNew = true
        selection = nil
        password = ""; pasteURL = ""; portText = ""; useColor = false
        testResult = nil; errorText = nil
    }

    private func applyPaste() {
        guard let (c, pw) = ConnectionURL.parse(pasteURL) else { return }
        draft.driver = c.driver
        draft.host = c.host; draft.port = c.port; draft.socket = c.socket
        draft.database = c.database; draft.path = c.path; draft.user = c.user
        draft.options = c.options
        portText = c.port.map(String.init) ?? ""
        if let pw { password = pw }
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = c.host ?? (c.path.map { ($0 as NSString).lastPathComponent } ?? "")
        }
        pasteURL = ""
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { draft.path = u.path }
    }

    private func edited() -> Connection {
        var c = draft
        c.color = useColor ? hexString(color) : nil
        return c
    }

    private func test() {
        testing = true; testResult = nil; errorText = nil
        var c = edited()
        if c.name.trimmingCharacters(in: .whitespaces).isEmpty { c.name = "test" }
        let typed = password
        let existing = isNew ? nil : state.connections.first(where: { $0.id == draft.id })
        let stored = existing.flatMap { state.store.password(for: $0) }
        let conn = c
        Task {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rowbase-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                let tmpStore = ConnectionStore(home: tmp, fileSecretsOnly: true)
                let pw = typed.isEmpty ? (stored ?? "") : typed
                try tmpStore.upsert(conn, password: pw)
                let version = try await Engine(store: tmpStore).ping(conn)
                testResult = (true, "OK · \(version)")
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }

    private func save() {
        errorText = nil
        let c = edited()
        let pw: String? = password.isEmpty ? nil : password
        do {
            let saved = try state.store.upsert(c, password: draft.dialect == .sqlite ? nil : pw)
            Task {
                await state.afterSave(saved)
                dismiss()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete() {
        let id = draft.id
        do {
            try state.store.delete(id)
            Task {
                await state.afterDelete(id)
                if let c = state.connections.first { selection = c.id; load(c) } else { startNew() }
            }
        } catch { errorText = error.localizedDescription }
    }
}
