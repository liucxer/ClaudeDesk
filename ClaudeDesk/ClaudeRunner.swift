import Foundation
import Combine

enum StreamEvent {
    case sessionStarted(id: String)
    case assistantTextDelta(String)
    case assistantMessageEnd
    case toolActivity
    case usage(input: Int, output: Int)
    case result(isError: Bool, message: String?)
}

/// Per-project chat session. Owns the message buffer, drives the `claude` CLI subprocess,
/// and outlives the `ChatView` so a project can keep working in the background while the
/// user is viewing another one.
@MainActor
final class ClaudeRunner: ObservableObject {
    let projectID: UUID
    @Published var messages: [Message]
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var toolBusy: Bool = false
    @Published private(set) var streamingMessageID: UUID?
    @Published private(set) var runStartedAt: Date?
    /// Wall-clock timestamp of the most recent stream event from claude.
    /// SessionStore polls this to flag a turn as stuck (long gap with no
    /// activity while `isRunning` is still true).
    @Published private(set) var lastEventAt: Date?
    @Published private(set) var inputTokens: Int = 0
    @Published private(set) var outputTokens: Int = 0
    @Published var errorMessage: String?

    weak var registry: SessionStore?

    private var process: Process?

    init(projectID: UUID, transcript: [Message]) {
        self.projectID = projectID
        self.messages = transcript
    }

    func send(
        prompt: String,
        project: Project,
        store: ProjectStore,
        attachments: [String] = []
    ) {
        guard !isRunning else { return }
        guard let binary = Self.findClaudeBinary() else {
            errorMessage = "claude CLI not found. Install via `brew install claude-code`."
            return
        }

        let userMsg = Message(
            role: .user,
            text: prompt,
            attachments: attachments.isEmpty ? nil : attachments
        )
        messages.append(userMsg)
        store.appendToTranscript(userMsg, projectID: projectID)

        let proc = Process()
        proc.executableURL = binary
        proc.currentDirectoryURL = project.directoryURL

        // Always use stream-json input. With attachments we MUST go through
        // stdin (positional prompt is text-only); for text-only turns we use
        // the same path so there's one code path to reason about.
        var args: [String] = [
            "--print",
            "--input-format", "stream-json",
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
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = stdinPipe

        // Build the JSONL user message and write it as soon as claude starts.
        let userPayload = Self.buildUserMessagePayload(prompt: prompt, attachments: attachments)

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.toolBusy = false
                self.streamingMessageID = nil
                self.runStartedAt = nil
                self.lastEventAt = nil
                self.process = nil
                if terminated.terminationStatus != 0 {
                    let errData = (try? stderrHandle.readToEnd()) ?? Data()
                    let errText = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let detail = errText.isEmpty ? "" : "\n\(errText)"
                    self.errorMessage = "claude exited with code \(terminated.terminationStatus).\(detail)"
                }
                self.registry?.didFinishTurn(for: self.projectID)
            }
        }

        isRunning = true
        toolBusy = false
        errorMessage = nil
        runStartedAt = Date()
        lastEventAt = Date()
        inputTokens = 0
        outputTokens = 0
        process = proc
        registry?.didStartTurn(for: projectID)

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
                        await self?.handle(event, project: project, store: store)
                    }
                }
            }
            if !buffer.isEmpty, let event = Self.parseEvent(buffer) {
                await self?.handle(event, project: project, store: store)
            }
        }

        do {
            try proc.run()
            // Write the user message to claude's stdin and close so it sees EOF
            // and proceeds (stream-json input mode reads until EOF in --print).
            let stdinHandle = stdinPipe.fileHandleForWriting
            if let data = userPayload {
                var line = data
                line.append(0x0A)
                try? stdinHandle.write(contentsOf: line)
            }
            try? stdinHandle.close()
        } catch {
            isRunning = false
            process = nil
            errorMessage = "Failed to launch claude: \(error.localizedDescription)"
            registry?.didFinishTurn(for: projectID)
        }
    }

    /// Build the JSONL user-message line that gets piped into `claude` over
    /// stdin. Content blocks: optional images first (base64-encoded), then a
    /// text block. claude accepts either a plain string for `content` or an
    /// array of blocks; we always use the array form for uniformity.
    nonisolated private static func buildUserMessagePayload(
        prompt: String,
        attachments: [String]
    ) -> Data? {
        var content: [[String: Any]] = []
        for filename in attachments {
            let url = AppPaths.attachmentURL(filename: filename)
            guard let bytes = try? Data(contentsOf: url) else { continue }
            let mediaType = mediaTypeFor(filename: filename)
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": bytes.base64EncodedString()
                ] as [String: Any]
            ])
        }
        content.append(["type": "text", "text": prompt])
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": content
            ] as [String: Any]
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    nonisolated private static func mediaTypeFor(filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        default:            return "image/png"
        }
    }

    func cancel() {
        process?.terminate()
    }

    private func handle(_ event: StreamEvent, project: Project, store: ProjectStore) {
        // Any stream event resets the stuck timer.
        lastEventAt = Date()
        switch event {
        case .sessionStarted:
            store.markSessionStarted(project.id)
        case .assistantTextDelta(let chunk):
            toolBusy = false
            // Anthropic's stream protocol only reports output_tokens at message
            // boundaries — `content_block_delta` carries no usage info. The CLI
            // works around this by tokenizing each chunk locally. We don't have
            // a Swift tokenizer, so approximate from character count
            // (~3 chars/token for mixed Chinese+English). The real value from
            // `message_delta` later overrides via `max(...)`.
            outputTokens += max(1, chunk.count / 3)
            if let sid = streamingMessageID,
               let idx = messages.firstIndex(where: { $0.id == sid }) {
                messages[idx].text += chunk
            } else {
                let m = Message(role: .assistant, text: chunk)
                messages.append(m)
                streamingMessageID = m.id
            }
        case .assistantMessageEnd:
            if let sid = streamingMessageID,
               let final = messages.first(where: { $0.id == sid }) {
                store.appendToTranscript(final, projectID: project.id)
            }
            streamingMessageID = nil
        case .toolActivity:
            toolBusy = true
        case .usage(let i, let o):
            // message_delta carries only the latest output count; signal with
            // input = -1 so we keep the previous input value rather than reset.
            if i >= 0 { inputTokens = i }
            // Never go backwards: our local char-based estimate may have led
            // the API by a few percent; honor whichever is bigger so the UI
            // doesn't jitter.
            outputTokens = max(outputTokens, o)
        case .result(let isError, let msg):
            // If the turn ended without an explicit message_stop (tool error,
            // process killed, etc.), persist any in-progress assistant message
            // that's already visible in the UI.
            if let sid = streamingMessageID,
               let final = messages.first(where: { $0.id == sid }) {
                store.appendToTranscript(final, projectID: project.id)
            }
            streamingMessageID = nil
            if isError {
                let detail = msg ?? "claude returned an error."
                let m = Message(role: .system, text: detail)
                messages.append(m)
                store.appendToTranscript(m, projectID: project.id)
            }
        }
    }

    // MARK: - Helpers

    /// What the CLI's "↑ N tokens" indicator counts — fresh prompt tokens for
    /// this turn, excluding cache reads (which are loaded server-side and don't
    /// reflect upload size).
    nonisolated private static func freshInput(_ usage: [String: Any]) -> Int {
        return (usage["input_tokens"] as? Int ?? 0)
             + (usage["cache_creation_input_tokens"] as? Int ?? 0)
    }

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
            case "message_start":
                // Initial usage snapshot at the start of a new message — fires
                // mid-turn between tool calls, so we see input climb as more
                // context is built up. Cache reads are excluded because they're
                // cached server-side, not a meaningful "size" indicator.
                if let msg = event["message"] as? [String: Any],
                   let usage = msg["usage"] as? [String: Any] {
                    return .usage(
                        input: freshInput(usage),
                        output: usage["output_tokens"] as? Int ?? 0
                    )
                }
                return nil
            case "message_delta":
                // Updated output token count at the end of each message.
                if let usage = event["usage"] as? [String: Any] {
                    let output = usage["output_tokens"] as? Int ?? 0
                    // Output is monotone-increasing within a turn; signal with a
                    // negative input sentinel that means "keep current input".
                    return .usage(input: -1, output: output)
                }
                return nil
            default:
                return nil
            }
        case "assistant":
            // Fallback for clients without stream_event coverage — same usage
            // info but at message-block boundaries.
            if let message = obj["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                return .usage(
                    input: freshInput(usage),
                    output: usage["output_tokens"] as? Int ?? 0
                )
            }
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

