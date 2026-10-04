import Foundation

/// MCP server settings (`<home>/settings.json` → "mcp"). Unknown keys are preserved on save.
struct MCPSettings: Equatable, Sendable {
    var allowWrites = false
    /// nil = all connections ("*"); otherwise connection names.
    var connections: [String]? = nil
    var maxRows = 200
    var timeout = 30
    var format = "toon"
    var toolset = "full"

    static let formats = ["toon", "csv", "md", "json"]
    static let toolsets = ["full", "minimal"]

    /// Reads `mcp` out of a settings document (any JSON object) applying defaults and clamping.
    static func decode(_ root: [String: Any]) -> MCPSettings {
        var s = MCPSettings()
        guard let m = root["mcp"] as? [String: Any] else { return s }
        if let b = m["allowWrites"] as? Bool { s.allowWrites = b }
        if let l = m["connections"] as? [Any] { s.connections = l.compactMap { $0 as? String } }
        if let n = (m["maxRows"] as? NSNumber)?.intValue { s.maxRows = min(max(n, 1), 5000) }
        if let n = (m["timeout"] as? NSNumber)?.intValue { s.timeout = min(max(n, 1), 600) }
        if let f = m["format"] as? String, formats.contains(f) { s.format = f }
        if let t = m["toolset"] as? String, toolsets.contains(t) { s.toolset = t }
        return s
    }

    /// Merges these settings into `root`, keeping all other top-level keys and unknown keys inside "mcp".
    func encode(into root: [String: Any]) -> [String: Any] {
        var out = root
        var m = (root["mcp"] as? [String: Any]) ?? [:]
        m["allowWrites"] = allowWrites
        m["connections"] = connections.map { $0 as Any } ?? "*"
        m["maxRows"] = min(max(maxRows, 1), 5000)
        m["timeout"] = min(max(timeout, 1), 600)
        m["format"] = format
        m["toolset"] = toolset
        out["mcp"] = m
        return out
    }

    static func url(home: URL) -> URL { home.appendingPathComponent("settings.json") }

    static func load(home: URL) -> MCPSettings {
        guard let d = try? Data(contentsOf: url(home: home)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return MCPSettings() }
        return decode(o)
    }

    /// Atomic write (temp file + rename), preserving unrelated keys already on disk.
    func save(home: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let u = Self.url(home: home)
        var root: [String: Any] = [:]
        if let d = try? Data(contentsOf: u) {
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                throw NSError(domain: "Rowbase", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json is not a JSON object — fix or remove it first"])
            }
            root = o
        }
        let data = try JSONSerialization.data(withJSONObject: encode(into: root), options: [.prettyPrinted, .sortedKeys])
        let tmp = home.appendingPathComponent(".settings.json.\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: u.path) {
            _ = try fm.replaceItemAt(u, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: u)
        }
    }
}

/// Client configuration snippets printed by `rowbase mcp --print-config --json`.
struct MCPClientConfig: Sendable, Equatable {
    var claudeCode = "", claudeDesktop = "", cursor = "", vscode = "", codex = "", prompt = ""

    static func parse(_ data: Data) -> MCPClientConfig? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func s(_ k: String) -> String { (o[k] as? String) ?? "" }
        return MCPClientConfig(claudeCode: s("claude_code"), claudeDesktop: s("claude_desktop"), cursor: s("cursor"),
                               vscode: s("vscode"), codex: s("codex"), prompt: s("prompt"))
    }
}

enum MCPSupport {
    /// env ROWBASE_CLI → bundled Resources/rowbase → dev checkout dist/rowbase-macos-arm64 → `which rowbase`.
    static func locateCLI() -> URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        func exec(_ p: String) -> URL? { fm.isExecutableFile(atPath: p) ? URL(fileURLWithPath: p) : nil }
        if let p = env["ROWBASE_CLI"], !p.isEmpty, let u = exec(NSString(string: p).expandingTildeInPath) { return u }
        if let r = Bundle.main.resourceURL, let u = exec(r.appendingPathComponent("rowbase").path) { return u }
        var starts = [Bundle.main.bundleURL]
        if let e = Bundle.main.executableURL { starts.append(e) }
        for start in starts {
            var dir = start.deletingLastPathComponent()
            for _ in 0..<8 {
                if fm.fileExists(atPath: dir.appendingPathComponent("pyproject.toml").path),
                   let u = exec(dir.appendingPathComponent("dist/rowbase-macos-arm64").path) { return u }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        if let out = run("/usr/bin/env", ["which", "rowbase"], timeout: 5),
           let line = String(bytes: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !line.isEmpty, let u = exec(line) { return u }
        return nil
    }

    /// Blocking; call off the main thread.
    static func fetchConfig(cli: URL) -> MCPClientConfig? {
        guard let out = run(cli.path, ["mcp", "--print-config", "--json"], timeout: 15) else { return nil }
        return MCPClientConfig.parse(out)
    }

    /// Runs a process with the app's environment; returns stdout on exit 0, nil on failure/timeout.
    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // Drain concurrently so large output can't block the child.
        let box = DataBox()
        let reader = DispatchQueue(label: "mcp.read")
        let readDone = DispatchSemaphore(value: 0)
        reader.async { box.data = pipe.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        readDone.wait()
        return p.terminationStatus == 0 ? box.data : nil
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }
