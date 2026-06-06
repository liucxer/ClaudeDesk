import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ChatView: View {
    let project: Project
    @EnvironmentObject private var sessions: SessionStore

    var body: some View {
        ChatViewBody(project: project, session: sessions.session(for: project.id))
    }
}

private struct ChatViewBody: View {
    let project: Project
    @ObservedObject var session: ClaudeRunner
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var sessions: SessionStore
    @State private var input: String = ""
    /// Filenames (basenames inside `AppPaths.attachmentsDir`) queued to send
    /// with the next message. Cleared after `send()`.
    @State private var pendingAttachments: [String] = []
    @State private var isDropTargeted: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.messages) { msg in
                            MessageRow(message: msg)
                                .id(msg.id)
                        }
                        if session.isRunning && (session.streamingMessageID == nil || session.toolBusy) {
                            ThinkingIndicator(
                                toolBusy: session.toolBusy,
                                startedAt: session.runStartedAt,
                                inputTokens: session.inputTokens,
                                outputTokens: session.outputTokens
                            )
                            .id("thinking")
                        }
                        // Invisible end-of-content sentinel. Scrolling to this
                        // (anchor .bottom) pins the absolute bottom of the
                        // scrollable area to the viewport, so no slack
                        // padding is left underneath.
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }
                .onChange(of: session.messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: session.messages.last?.text) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: session.isRunning) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear {
                    // Jump to the very bottom when the user opens this project.
                    // No animation — feels like "we left it scrolled to bottom"
                    // rather than a panning effect. DispatchQueue.main.async
                    // defers until after layout, otherwise scrollTo fires
                    // before the rows exist.
                    DispatchQueue.main.async {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            if let error = session.errorMessage {
                errorBanner(error)
            }

            Divider()
            composer
        }
        .onAppear {
            sessions.markSeen(project.id)
        }
        .onDisappear {
            sessions.markUnseen(project.id)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.headline)
                    headerStatusBadge
                }
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
            // Show a close affordance per pane only when more than one project
            // is currently displayed — single-view mode keeps the header
            // uncluttered. Clicking removes this project from the selection,
            // which collapses the split.
            if store.selectedIDs.count > 1 {
                Button {
                    store.selectedIDs.remove(project.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("从分屏中移除这一栏（不会删除项目）")
            }
        }
        .padding(12)
    }

    /// Inline status next to the project name — mirrors what the sidebar row
    /// shows, so the user can tell at a glance whether the currently-visible
    /// pane is running, stuck, or idle.
    @ViewBuilder
    private var headerStatusBadge: some View {
        if sessions.stuckIDs.contains(project.id) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .help("Turn appears stuck (no activity for 90s+). Try Stop in the composer.")
        } else if session.isRunning {
            ProgressView()
                .controlSize(.small)
                .help("Working…")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !pendingAttachments.isEmpty {
                attachmentStrip
            }
            composerRow
        }
        .padding(12)
        // Drag images (or image files) onto the composer to attach.
        .onDrop(of: ["public.image", "public.file-url"], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: isDropTargeted ? 2 : 0)
                .padding(8)
                .allowsHitTesting(false)
        )
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments, id: \.self) { filename in
                    AttachmentChip(filename: filename) {
                        pendingAttachments.removeAll { $0 == filename }
                    }
                }
            }
        }
        .frame(height: 76)
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: pickImageFromDisk) {
                Image(systemName: "paperclip")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("附加图片（也可以直接 ⌘V 粘贴或拖拽进来）")
            .disabled(session.isRunning)

            ChatTextEditor(
                text: $input,
                isEnabled: !session.isRunning,
                onSubmit: send,
                onImagesPasted: handlePastedImages
            )
            .frame(minHeight: 60, maxHeight: 160)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3))
            )

            VStack(spacing: 6) {
                if session.isRunning {
                    Button(action: { session.cancel() }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: send) {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("↩ send · ⇧↩ newline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
            Button("Dismiss") { session.errorMessage = nil }
                .buttonStyle(.link)
        }
        .padding(8)
        .background(Color.red.opacity(0.08))
    }

    private func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow sending when there are attachments even if the text is empty.
        guard (!prompt.isEmpty || !pendingAttachments.isEmpty), !session.isRunning else { return }
        let toSend = pendingAttachments
        input = ""
        pendingAttachments = []
        session.send(prompt: prompt, project: project, store: store, attachments: toSend)
    }

    // MARK: - Image input

    private func handlePastedImages(_ datas: [Data]) {
        for data in datas {
            if let name = saveAttachment(data: data) {
                pendingAttachments.append(name)
            }
        }
    }

    private func pickImageFromDisk() {
        let panel = NSOpenPanel()
        panel.title = "Select images"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .tiff, .bmp]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let data = try? Data(contentsOf: url),
               let name = saveAttachment(data: data, hintExtension: url.pathExtension) {
                pendingAttachments.append(name)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            // File URL path (most apps drop these for image files).
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, PasteAwareTextView.isImageURL(url),
                          let data = try? Data(contentsOf: url) else { return }
                    DispatchQueue.main.async {
                        if let name = saveAttachment(data: data, hintExtension: url.pathExtension) {
                            pendingAttachments.append(name)
                        }
                    }
                }
                continue
            }
            // Raw image data (drag from Preview, screenshot apps, browsers).
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage,
                          let data = PasteAwareTextView.pngData(from: img) else { return }
                    DispatchQueue.main.async {
                        if let name = saveAttachment(data: data) {
                            pendingAttachments.append(name)
                        }
                    }
                }
            }
        }
    }

    /// Writes the given bytes to `attachments/<uuid>.<ext>` and returns the
    /// basename. Files larger than ~5 MB get re-encoded to JPEG to stay under
    /// the API's per-image limit.
    private func saveAttachment(data: Data, hintExtension: String? = nil) -> String? {
        let ext = (hintExtension?.lowercased() ?? "png")
        let normalized = ["png","jpg","jpeg","gif","webp","heic","tiff","bmp"].contains(ext) ? ext : "png"
        let filename = "\(UUID().uuidString).\(normalized)"
        let url = AppPaths.attachmentURL(filename: filename)
        do {
            try data.write(to: url)
            return filename
        } catch {
            return nil
        }
    }
}

/// Thumbnail pill in the composer's attachment strip.
private struct AttachmentChip: View {
    let filename: String
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = NSImage(contentsOf: AppPaths.attachmentURL(filename: filename)) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3))
            )

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white, .black.opacity(0.7))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        .frame(width: 64, height: 68)
    }
}

/// Thumbnail strip rendered above a message's text when the message has
/// attachments. Clicking a thumbnail opens the file in the default app
/// (Preview for images).
private struct AttachmentRow: View {
    let filenames: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(filenames, id: \.self) { filename in
                let url = AppPaths.attachmentURL(filename: filename)
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Group {
                        if let img = NSImage(contentsOf: url) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                }
                .buttonStyle(.plain)
                .help(filename)
            }
        }
    }
}

private struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: alignment, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    if let attachments = message.attachments, !attachments.isEmpty {
                        AttachmentRow(filenames: attachments)
                    }
                    if !message.text.isEmpty {
                        MarkdownView(text: message.text)
                    }
                }
                .textSelection(.enabled)
                .padding(10)
                .background(bubbleColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            // Cap width so long messages wrap, but let short bubbles size to
            // their content instead of stretching across the full row.
            .frame(maxWidth: 640, alignment: bubbleAlignment)
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

private struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let content):
            inlineText(content)
                .font(headingFont(for: level))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let content):
            // No `.frame(maxWidth: .infinity)` — that would force short
            // paragraphs to fill the bubble's available width, leaving the
            // bubble background extending past the actual text.
            inlineText(content)
                .fixedSize(horizontal: false, vertical: true)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inlineText(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(idx + 1).").foregroundStyle(.secondary).monospacedDigit()
                        inlineText(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .codeBlock(let lang, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let lang, !lang.isEmpty {
                    Text(lang)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.black.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .table(let headers, let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { ci in
                        inlineText(headers[ci])
                            .fontWeight(.semibold)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { ri in
                    GridRow {
                        ForEach(0..<headers.count, id: \.self) { ci in
                            inlineText(ci < rows[ri].count ? rows[ri][ci] : "")
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func inlineText(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        default: return .headline
        }
    }

    private enum Block {
        case heading(level: Int, content: String)
        case paragraph(String)
        case bulletList([String])
        case orderedList([String])
        case codeBlock(language: String?, code: String)
        case table(headers: [String], rows: [[String]])
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                blocks.append(.codeBlock(
                    language: lang.isEmpty ? nil : lang,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }
            if let (level, content) = parseHeading(line) {
                blocks.append(.heading(level: level, content: content))
                i += 1
                continue
            }
            // Tables: header row | --- | --- | followed by data rows.
            if isTableRow(line), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let headers = splitTableRow(line)
                var rows: [[String]] = []
                i += 2  // skip header + separator
                while i < lines.count, isTableRow(lines[i]) {
                    rows.append(splitTableRow(lines[i]))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }
            if isBullet(line) {
                var items: [String] = []
                while i < lines.count, isBullet(lines[i]) {
                    items.append(stripBullet(lines[i]))
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }
            if isOrderedItem(line) {
                var items: [String] = []
                while i < lines.count, isOrderedItem(lines[i]) {
                    items.append(stripOrdered(lines[i]))
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }
            var paraLines: [String] = [line]
            i += 1
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if l.hasPrefix("```") { break }
                if parseHeading(l) != nil { break }
                if isBullet(l) || isOrderedItem(l) { break }
                paraLines.append(l)
                i += 1
            }
            blocks.append(.paragraph(paraLines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func isTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 2 && t.hasPrefix("|") && t.hasSuffix("|") && t.contains("|")
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.hasSuffix("|") else { return false }
        let inner = String(t.dropFirst().dropLast())
        let cells = inner.components(separatedBy: "|")
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let cleaned = cell.trimmingCharacters(in: .whitespaces)
            return !cleaned.isEmpty && cleaned.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t = String(t.dropFirst()) }
        if t.hasSuffix("|") { t = String(t.dropLast()) }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        if line.hasPrefix("### ") { return (3, String(line.dropFirst(4))) }
        if line.hasPrefix("## ")  { return (2, String(line.dropFirst(3))) }
        if line.hasPrefix("# ")   { return (1, String(line.dropFirst(2))) }
        return nil
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ")
    }

    private static func stripBullet(_ line: String) -> String {
        String(line.dropFirst(2))
    }

    private static func isOrderedItem(_ line: String) -> Bool {
        var idx = line.startIndex
        var sawDigit = false
        while idx < line.endIndex, line[idx].isNumber {
            sawDigit = true
            idx = line.index(after: idx)
        }
        guard sawDigit, idx < line.endIndex else { return false }
        let c = line[idx]
        guard c == "." || c == ")" else { return false }
        let next = line.index(after: idx)
        return next < line.endIndex && line[next] == " "
    }

    private static func stripOrdered(_ line: String) -> String {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            idx = line.index(after: idx)
        }
        idx = line.index(after: idx) // skip . or )
        idx = line.index(after: idx) // skip space
        return String(line[idx...])
    }
}

private struct ThinkingIndicator: View {
    let toolBusy: Bool
    let startedAt: Date?
    let inputTokens: Int
    let outputTokens: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(label(now: ctx.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }

    private func label(now: Date) -> String {
        let verb = toolBusy ? "Running tool" : "Thinking"
        var parts: [String] = []
        if let start = startedAt {
            parts.append(Self.formatDuration(now.timeIntervalSince(start)))
        }
        if inputTokens > 0 {
            parts.append("↑ \(Self.formatTokens(inputTokens))")
        }
        if outputTokens > 0 {
            parts.append("↓ \(Self.formatTokens(outputTokens))")
        }
        if parts.isEmpty {
            return "\(verb)…"
        }
        return "\(verb)… (\(parts.joined(separator: " · ")))"
    }

    private static func formatDuration(_ s: TimeInterval) -> String {
        let total = max(0, Int(s))
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

    private static func formatTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n) tokens" }
        let k = Double(n) / 1000.0
        // 3.6k tokens, 12k tokens — drop the .0 on round-thousands
        if k >= 100 { return "\(Int(k.rounded()))k tokens" }
        let s = String(format: "%.1f", k).replacingOccurrences(of: ".0", with: "")
        return "\(s)k tokens"
    }
}
