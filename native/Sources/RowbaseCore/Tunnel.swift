import Darwin
import Foundation

/// SSH local forwards via the system `ssh` binary (mirrors rowbase/tunnel.py). ROWBASE_SSH overrides the binary.
public actor TunnelManager {
    public static let shared = TunnelManager()
    private var tunnels: [String: (process: Process, port: Int)] = [:]
    private static let all = ProcessList()

    public static func command(_ ssh: SSHConfig, target: String, localPort: Int) -> [String] {
        var a = ["-N", "-L", "127.0.0.1:\(localPort):\(target)", "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes",
                 "-o", "ServerAliveInterval=30", "-o", "ConnectTimeout=10"]
        if let p = ssh.port { a += ["-p", String(p)] }
        if let i = ssh.identityFile { a += ["-i", NSString(string: i).expandingTildeInPath] }
        return a + [ssh.user.map { "\($0)@\(ssh.host)" } ?? ssh.host]
    }

    /// Start or reuse a tunnel to `target` ("host:port" or a remote unix socket path); returns the local port.
    public func port(_ ssh: SSHConfig, target: String) async throws -> Int {
        let key = "\(ssh.label)|\(ssh.identityFile ?? "")|\(target)"
        if let t = tunnels[key], t.process.isRunning { return t.port }
        let port = try Self.freePort()
        let p = Process()
        let bin = ProcessInfo.processInfo.environment["ROWBASE_SSH"] ?? "/usr/bin/ssh"
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = Self.command(ssh, target: target, localPort: port)
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw RowbaseError("SSH tunnel failed: cannot run \(bin): \(error.localizedDescription)") }
        Self.all.add(p)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !p.isRunning {
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw RowbaseError("SSH tunnel failed: \(msg.isEmpty ? "ssh exited with \(p.terminationStatus)" : msg)")
            }
            if Self.canConnect(port) {
                tunnels[key] = (p, port)
                return port
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        p.terminate()
        throw RowbaseError("SSH tunnel to \(ssh.host) timed out")
    }

    /// Terminate every ssh process started by this app (call on app termination).
    public nonisolated static func shutdown() { all.terminateAll() }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RowbaseError("socket() failed") }
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                               sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { throw RowbaseError("Cannot allocate a local port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func canConnect(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                               sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
}

final class ProcessList: @unchecked Sendable {
    private var list: [Process] = []
    private let lock = NSLock()
    func add(_ p: Process) { lock.withLock { list.append(p) } }
    func terminateAll() { lock.withLock { list.filter(\.isRunning).forEach { $0.terminate() }; list.removeAll() } }
}
