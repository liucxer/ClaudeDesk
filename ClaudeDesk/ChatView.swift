import SwiftUI
import Combine

struct ChatView: View {
    let project: Project
    @EnvironmentObject private var store: ProjectStore
    @StateObject private var runner = ClaudeRunner()
    @State private var messages: [Message] = []
    @State private var input: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { msg in
                            MessageRow(message: msg)
                                .id(msg.id)
                        }
                        if runner.isRunning {
                            ThinkingIndicator(toolBusy: runner.toolBusy)
                                .id("thinking")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: runner.isRunning) { running in
                    if running { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }

            if let error = runner.errorMessage {
                errorBanner(error)
            }

            Divider()
            composer
        }
        .onAppear {
            messages = store.loadTranscript(for: project.id)
            store.touchLastOpened(project.id)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.headline)
                Text(project.directoryPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !project.directoryExists {
                Label("Directory missing", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .padding(12)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $input)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 160)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )
                .disabled(runner.isRunning)

            VStack(spacing: 6) {
                if runner.isRunning {
                    Button(action: { runner.cancel() }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: send) {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("⌘↩")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss") { runner.errorMessage = nil }
                .buttonStyle(.link)
        }
        .padding(8)
        .background(Color.red.opacity(0.08))
    }

    private func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !runner.isRunning else { return }
        input = ""
        let userMsg = Message(role: .user, text: prompt)
        messages.append(userMsg)
        store.appendToTranscript(userMsg, projectID: project.id)

        runner.send(prompt: prompt, project: project) { event in
            switch event {
            case .sessionStarted:
                store.markSessionStarted(project.id)
            case .assistantText(let text):
                let m = Message(role: .assistant, text: text)
                messages.append(m)
                store.appendToTranscript(m, projectID: project.id)
            case .toolActivity:
                break
            case .result(let isError, let msg):
                if isError {
                    let detail = msg ?? "claude returned an error."
                    let m = Message(role: .system, text: detail)
                    messages.append(m)
                    store.appendToTranscript(m, projectID: project.id)
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: alignment, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(bubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, alignment: bubbleAlignment)
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var alignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var bubbleAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.18)
        case .assistant: return Color.secondary.opacity(0.12)
        case .system: return Color.orange.opacity(0.12)
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Claude"
        case .system: return "System"
        }
    }
}

private struct ThinkingIndicator: View {
    let toolBusy: Bool
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(toolBusy ? "Running tool\(dots)" : "Thinking\(dots)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .onReceive(timer) { _ in phase = (phase + 1) % 4 }
    }

    private var dots: String { String(repeating: ".", count: phase) }
}
