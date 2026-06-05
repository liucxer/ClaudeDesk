import Foundation
import Combine

enum StreamEvent {
    case sessionStarted(id: String)
    case assistantTextDelta(String)
    case assistantMessageEnd
    case toolActivity
    case result(isError: Bool, message: String?)
}

@MainActor
final class ClaudeRunner: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var toolBusy: Bool = false
    @Published var errorMessage: String?

    private var process: Process?

    func send(
        prompt: String,
        project: Project,
        onEvent: @escaping (StreamEvent) -> Void
    ) {
        guard !isRunning else { return }
        guard let binary = Self.findClaudeBinary() else {
            errorMessage = "claude CLI not found. Install via `brew install claude-code`."
            return
        }

        let proc = Process()
        proc.executableURL = binary
        proc.currentDirectoryURL = project.directoryURL

        var args: [String] = [
            "--print",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
        ]
        if let mcpJSON = Self.buildMCPConfigJSON() {
            args.append(contentsOf: [
                "--mcp-config", mcpJSON,
                "--permission-prompt-tool", "mcp__claudedesk__permission_prompt",
            ])
        }
        if project.hasStartedSession {
            args.append(contentsOf: ["--resume", project.id.uuidString])
        } else {
            args.append(contentsOf: ["--session-id", project.id.uuidString])
        }
        args.append(prompt)
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.toolBusy = false
                self.process = nil
                if terminated.terminationStatus != 0 {
                    let errData = (try? stderrHandle.readToEnd()) ?? Data()
                    let errText = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let detail = errText.isEmpty ? "" : "\n\(errText)"
                    self.errorMessage = "claude exited with code \(terminated.terminationStatus).\(detail)"
                }
            }
        }

        isRunning = true
        toolBusy = false
        errorMessage = nil
        process = proc

        Task.detached(priority: .userInitiated) { [weak self] in
            var buffer = Data()
            while true {
                guard let chunk = try? stdoutHandle.read(upToCount: 4096),
                      !chunk.isEmpty else { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if !lineData.isEmpty, let event = Self.parseEvent(lineData) {
                        await self?.deliver(event, onEvent: onEvent)
                    }
                }
            }
            if !buffer.isEmpty, let event = Self.parseEvent(buffer) {
                await self?.deliver(event, onEvent: onEvent)
            }
        }

        do {
            try proc.run()
        } catch {
            isRunning = false
            process = nil
            errorMessage = "Failed to launch claude: \(error.localizedDescription)"
        }
    }

    func cancel() {
        process?.terminate()
    }

    private func deliver(_ event: StreamEvent, onEvent: (StreamEvent) -> Void) {
        switch event {
        case .toolActivity: toolBusy = true
        case .assistantTextDelta: toolBusy = false
        default: break
        }
        onEvent(event)
    }

    // MARK: - Helpers

    nonisolated private static func parseEvent(_ data: Data) -> StreamEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "system":
            if (obj["subtype"] as? String) == "init",
               let sid = obj["session_id"] as? String {
                return .sessionStarted(id: sid)
            }
            return nil
        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  let eventType = event["type"] as? String else { return nil }
            switch eventType {
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any],
                      (delta["type"] as? String) == "text_delta",
                      let text = delta["text"] as? String else { return nil }
                return .assistantTextDelta(text)
            case "message_stop":
                return .assistantMessageEnd
            default:
                return nil
            }
        case "assistant":
            return nil
        case "user":
            return .toolActivity
        case "result":
            let isError = (obj["is_error"] as? Bool) ?? false
            let msg = (obj["error"] as? String) ?? (obj["result"] as? String)
            return .result(isError: isError, message: msg)
        default:
            return nil
        }
    }

    private static func buildMCPConfigJSON() -> String? {
        let scriptPath = PermissionGateway.shared.mcpScriptPath
        let socketPath = PermissionGateway.shared.socketPath
        let config: [String: Any] = [
            "mcpServers": [
                "claudedesk": [
                    "command": scriptPath,
                    "args": [socketPath],
                ] as [String: Any]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func findClaudeBinary() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fallback: ask login shell to resolve via PATH
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let path = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}
