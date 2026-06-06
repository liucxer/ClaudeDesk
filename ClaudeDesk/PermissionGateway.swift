import Foundation
import SwiftUI
import Combine
import Darwin

enum PermissionDecision {
    case allow
    case deny(reason: String)
}

struct PendingPermission: Identifiable {
    let id = UUID()
    let toolName: String
    let inputDescription: String
    let rawInput: [String: Any]
}

@MainActor
final class PermissionGateway: ObservableObject {
    static let shared = PermissionGateway()

    @Published var pending: PendingPermission?
    @Published var lastError: String?

    let socketPath: String
    let mcpScriptPath: String

    private let listenQueue = DispatchQueue(label: "claudedesk.permission.listen")
    private let serverFD: Int32

    // Responder lives outside `pending` so we can tell a clean resolve apart
    // from SwiftUI clearing `pending` because the sheet was dismissed (Esc,
    // window close, click-outside). The latter would leave the MCP socket
    // handler waiting on its semaphore forever.
    private var currentResponder: ((PermissionDecision) -> Void)?

    private init() {
        let randomToken = UUID().uuidString.prefix(12)
        let socketPath = "/tmp/claudedesk-\(randomToken).sock"
        self.socketPath = socketPath
        self.mcpScriptPath = Self.installRelayScript()
        // Bind + listen synchronously so the socket exists before any caller
        // (including ClaudeRunner) tries to spawn claude and connect.
        self.serverFD = Self.bindAndListen(socketPath: socketPath)
        startAcceptLoop()
    }

    func resolve(_ decision: PermissionDecision) {
        guard let r = currentResponder else { return }
        currentResponder = nil
        pending = nil
        listenQueue.async { r(decision) }
    }

    /// Called from `.sheet(onDismiss:)`. If the user dismissed the dialog
    /// without clicking a button, auto-deny so the blocked MCP handler can
    /// unwind. If they DID click a button, `resolve` has already cleared
    /// `currentResponder` and this is a no-op.
    func handleSheetDismiss() {
        guard let r = currentResponder else { return }
        currentResponder = nil
        pending = nil
        listenQueue.async { r(.deny(reason: "dialog dismissed without choice")) }
    }

    // MARK: - Relay script

    /// Writes the bundled shell-script MCP relay to Application Support and returns its path.
    /// The script's only job is to forward each JSON-RPC line over a UNIX socket to us.
    private static func installRelayScript() -> String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClaudeDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = dir.appendingPathComponent("permission-mcp.sh")
        let script = """
        #!/bin/bash
        SOCKET="$1"
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          # Skip notifications (no id field) — they expect no response.
          echo "$line" | /usr/bin/grep -q '"id":' || continue
          printf '%s\\n' "$line" | /usr/bin/nc -U "$SOCKET"
        done
        """
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
        )
        return scriptURL.path
    }

    // MARK: - Socket setup

    nonisolated private static func bindAndListen(socketPath: String) -> Int32 {
        unlink(socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) {
                    _ = strlcpy($0, src, 104)
                }
            }
        }
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, addrSize)
            }
        }
        if bindResult != 0 { Darwin.close(fd); return -1 }
        if Darwin.listen(fd, 8) != 0 { Darwin.close(fd); return -1 }
        return fd
    }

    nonisolated private func startAcceptLoop() {
        let fd = self.serverFD
        guard fd >= 0 else { return }
        let asker = makeAsker()
        listenQueue.async {
            while true {
                let clientFD = Darwin.accept(fd, nil, nil)
                if clientFD < 0 { break }
                DispatchQueue.global(qos: .userInitiated).async {
                    Self.handleClient(fd: clientFD, ask: asker)
                }
            }
            Darwin.close(fd)
        }
    }

    /// Producer signature accepts the client fd so the asker can monitor the
    /// socket for peer hangup and unblock if claude dies mid-prompt.
    nonisolated private func makeAsker() -> @Sendable (String, [String: Any], String, Int32) -> PermissionDecision {
        return { [weak self] toolName, input, desc, fd in
            let sem = DispatchSemaphore(value: 0)
            let box = DecisionBox()

            // Wake on peer hangup. If claude (or the bash relay) dies while
            // we're waiting for the user, the socket gets EOF — bail with deny
            // so the gateway state can recycle for the next turn.
            let watcher = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
            watcher.setEventHandler {
                var byte: UInt8 = 0
                let n = Darwin.recv(fd, &byte, 1, MSG_PEEK)
                if n <= 0 {
                    box.set(.deny(reason: "client disconnected"))
                    sem.signal()
                }
            }
            watcher.resume()

            DispatchQueue.main.async {
                guard let self else {
                    box.set(.deny(reason: "app exiting"))
                    sem.signal()
                    return
                }
                if self.currentResponder != nil {
                    box.set(.deny(reason: "another permission prompt is in progress"))
                    sem.signal()
                    return
                }
                self.currentResponder = { decision in
                    box.set(decision)
                    sem.signal()
                }
                self.pending = PendingPermission(
                    toolName: toolName,
                    inputDescription: desc,
                    rawInput: input
                )
            }

            // Hard timeout: if no decision arrives in 5 minutes (and the socket
            // also hasn't dropped), bail anyway so a stuck dialog can never
            // brick the gateway for the rest of the session.
            let waitResult = sem.wait(timeout: .now() + 300)
            watcher.cancel()
            if waitResult == .timedOut, !box.wasSet {
                box.set(.deny(reason: "permission prompt timed out"))
                Task { @MainActor [weak self] in
                    self?.handleSheetDismiss()
                }
            }
            return box.get()
        }
    }

    // MARK: - Connection handler

    nonisolated private static func handleClient(
        fd: Int32,
        ask: @escaping @Sendable (String, [String: Any], String, Int32) -> PermissionDecision
    ) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A) {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { Darwin.close(fd); return }
            buffer.append(chunk, count: n)
        }
        guard let nl = buffer.firstIndex(of: 0x0A) else { Darwin.close(fd); return }
        let lineData = buffer.subdata(in: 0..<nl)

        if let response = mcpHandle(lineData, fd: fd, ask: ask) {
            var out = response
            out.append(0x0A)
            out.withUnsafeBytes { buf in
                var sent = 0
                while sent < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                    if n <= 0 { break }
                    sent += n
                }
            }
        }
        Darwin.close(fd)
    }

    // MARK: - MCP protocol

    /// Builds a JSON-RPC response using JSONSerialization so quotes / newlines /
    /// control chars in nested strings are always escaped correctly.
    nonisolated private static func jsonRPCResponse(id: Any, result: [String: Any]) -> Data? {
        var body: [String: Any] = ["jsonrpc": "2.0", "result": result]
        body["id"] = id
        return try? JSONSerialization.data(withJSONObject: body)
    }

    nonisolated private static func jsonRPCError(id: Any, code: Int, message: String) -> Data? {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message] as [String: Any]
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    nonisolated private static func mcpHandle(
        _ data: Data,
        fd: Int32,
        ask: @escaping @Sendable (String, [String: Any], String, Int32) -> PermissionDecision
    ) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Notifications (no id) require no response.
        guard let id = obj["id"] else { return nil }
        let method = (obj["method"] as? String) ?? ""

        switch method {
        case "initialize":
            return jsonRPCResponse(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "claudedesk", "version": "0.1"]
            ])

        case "tools/list":
            return jsonRPCResponse(id: id, result: [
                "tools": [[
                    "name": "permission_prompt",
                    "description": "Ask the user to allow or deny a tool invocation",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "tool_name": ["type": "string"],
                            "input": ["type": "object"]
                        ],
                        "required": ["tool_name", "input"]
                    ]
                ] as [String: Any]]
            ])

        case "tools/call":
            guard let params = obj["params"] as? [String: Any],
                  (params["name"] as? String) == "permission_prompt",
                  let args = params["arguments"] as? [String: Any],
                  let toolName = args["tool_name"] as? String else {
                return jsonRPCError(id: id, code: -32602, message: "invalid params")
            }
            let input = (args["input"] as? [String: Any]) ?? [:]
            let desc = describeInput(input)
            let decision = ask(toolName, input, desc, fd)
            let innerObj: [String: Any]
            switch decision {
            case .allow:
                innerObj = ["behavior": "allow"]
            case .deny(let reason):
                innerObj = ["behavior": "deny", "message": reason]
            }
            // JSONSerialization will escape any quotes / newlines / control chars
            // inside `reason` correctly when it serializes innerObj to a string.
            guard let innerData = try? JSONSerialization.data(withJSONObject: innerObj),
                  let innerStr = String(data: innerData, encoding: .utf8) else {
                return jsonRPCError(id: id, code: -32603, message: "encode failed")
            }
            return jsonRPCResponse(id: id, result: [
                "content": [["type": "text", "text": innerStr]]
            ])

        case "ping":
            return jsonRPCResponse(id: id, result: [String: Any]())

        default:
            return jsonRPCError(id: id, code: -32601, message: "method not found")
        }
    }

    nonisolated private static func describeInput(_ input: [String: Any]) -> String {
        if let pretty = try? JSONSerialization.data(
            withJSONObject: input,
            options: [.prettyPrinted, .sortedKeys]
        ), let s = String(data: pretty, encoding: .utf8) { return s }
        return String(describing: input)
    }
}

/// Thread-safe single-shot box for the user's permission decision.
private final class DecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var value: PermissionDecision = .deny(reason: "no response")
    nonisolated(unsafe) private var _wasSet: Bool = false
    nonisolated init() {}
    /// First setter wins. Late setters (e.g. a stale UI response that arrives
    /// after a socket-EOF cancellation) are dropped.
    nonisolated func set(_ d: PermissionDecision) {
        lock.lock(); defer { lock.unlock() }
        guard !_wasSet else { return }
        value = d
        _wasSet = true
    }
    nonisolated func get() -> PermissionDecision {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    nonisolated var wasSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return _wasSet
    }
}
