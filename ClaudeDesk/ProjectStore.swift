import Foundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    /// Multi-select: empty = placeholder, 1 = single ChatView, 2+ = split view.
    /// Sidebar's `List(selection:)` binds to this directly so cmd-click
    /// toggles membership and a plain click replaces (standard macOS).
    @Published var selectedIDs: Set<UUID> = [] {
        didSet { saveUIState() }
    }
    /// Last-observed pane width per project, persisted across launches so the
    /// split view restores its previous layout rather than always resetting to
    /// equal halves.
    @Published private(set) var paneWidths: [UUID: Double] = [:]
    @Published var isPresentingNewProjectPrompt: Bool = false
    @Published var lastError: String?

    private static let kSelectedIDsKey = "ClaudeDesk.selectedIDs"
    private static let kPaneWidthsKey  = "ClaudeDesk.paneWidths"

    private let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        load()
        loadUIState()
        // Drop any persisted selection that points at a project that no longer
        // exists (e.g., directory removed manually).
        selectedIDs = selectedIDs.filter { id in projects.contains(where: { $0.id == id }) }
        if selectedIDs.isEmpty, let first = projects.first?.id {
            selectedIDs = [first]
        }
    }

    private func loadUIState() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: Self.kSelectedIDsKey),
           let arr = try? JSONDecoder().decode([UUID].self, from: data) {
            // didSet here triggers a save back of identical data, which is fine.
            selectedIDs = Set(arr)
        }
        if let data = ud.data(forKey: Self.kPaneWidthsKey) {
            // Stored as [String: Double] (UUID isn't a JSON dict key).
            if let dict = try? JSONDecoder().decode([String: Double].self, from: data) {
                paneWidths = Dictionary(uniqueKeysWithValues:
                    dict.compactMap { (k, v) -> (UUID, Double)? in
                        UUID(uuidString: k).map { ($0, v) }
                    }
                )
            }
        }
    }

    private func saveUIState() {
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(Array(selectedIDs)) {
            ud.set(data, forKey: Self.kSelectedIDsKey)
        }
        let stringKeyed = Dictionary(uniqueKeysWithValues:
            paneWidths.map { ($0.key.uuidString, $0.value) }
        )
        if let data = try? JSONEncoder().encode(stringKeyed) {
            ud.set(data, forKey: Self.kPaneWidthsKey)
        }
    }

    /// Called from ContentView's GeometryReader whenever a pane is resized
    /// (either initially or by the user dragging the divider).
    func recordPaneWidth(_ projectID: UUID, width: Double) {
        // Coalesce sub-pixel chatter so we don't hammer UserDefaults during a
        // drag — only persist when the change is meaningful.
        if let prev = paneWidths[projectID], abs(prev - width) < 1 { return }
        paneWidths[projectID] = width
        saveUIState()
    }

    /// Bumped to force ContentView's HSplitView to rebuild with fresh idealWidths
    /// after we wipe paneWidths. Without re-identifying the view, the underlying
    /// NSSplitView keeps its current divider positions and ignores the change.
    @Published private(set) var splitLayoutGeneration: Int = 0

    /// Wipe saved widths for currently-selected projects and recycle the split
    /// view so panes redistribute to equal widths.
    func equalizeSelectedPaneWidths() {
        for id in selectedIDs { paneWidths.removeValue(forKey: id) }
        saveUIState()
        splitLayoutGeneration &+= 1
    }

    /// Selected projects in sidebar order (so split-view panes are stable
    /// regardless of click sequence).
    var selectedProjects: [Project] {
        projects.filter { selectedIDs.contains($0.id) }
    }

    /// Legacy single-selection accessor — first selected project, if any.
    var selectedProject: Project? {
        selectedProjects.first
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: AppPaths.projectsFile.path) else { return }
        do {
            let data = try Data(contentsOf: AppPaths.projectsFile)
            projects = try decoder.decode([Project].self, from: data)
        } catch {
            lastError = "Failed to load projects: \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let data = try prettyEncoder.encode(projects)
            try data.write(to: AppPaths.projectsFile, options: .atomic)
        } catch {
            lastError = "Failed to save projects: \(error.localizedDescription)"
        }
    }

    // MARK: - Mutations

    func updateProject(_ updated: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == updated.id }) else { return }
        projects[idx] = updated
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func moveUp(_ id: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        projects.swapAt(idx, idx - 1)
        save()
    }

    func moveDown(_ id: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == id }), idx < projects.count - 1 else { return }
        projects.swapAt(idx, idx + 1)
        save()
    }

    func rename(_ id: UUID, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].name = name
        save()
    }

    func markSessionStarted(_ id: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == id }),
              !projects[idx].hasStartedSession else { return }
        projects[idx].hasStartedSession = true
        save()
    }

    func remove(_ id: UUID) {
        projects.removeAll { $0.id == id }
        selectedIDs.remove(id)
        if selectedIDs.isEmpty, let first = projects.first?.id {
            selectedIDs = [first]
        }
        save()
        try? FileManager.default.removeItem(at: AppPaths.transcriptFile(for: id))
    }

    // MARK: - Flows

    func requestNewProject() {
        isPresentingNewProjectPrompt = true
    }

    func createNewProject(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let safeFolder = name.replacingOccurrences(of: "/", with: "-")
        let dir = AppPaths.defaultProjectsRoot.appendingPathComponent(safeFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            lastError = "Could not create project directory: \(error.localizedDescription)"
            return
        }
        let project = Project(name: name, directoryPath: dir.path)
        projects.append(project)
        selectedIDs = [project.id]
        save()
    }

    func requestOpenProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addExisting(directory: url)
    }

    func addExisting(directory url: URL) {
        if let existing = projects.first(where: { $0.directoryPath == url.path }) {
            selectedIDs = [existing.id]
            return
        }
        let project = Project(
            name: url.lastPathComponent,
            directoryPath: url.path
        )
        projects.append(project)
        selectedIDs = [project.id]
        save()
    }

    // MARK: - Transcript I/O

    func loadTranscript(for projectID: UUID) -> [Message] {
        let url = AppPaths.transcriptFile(for: projectID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        var result: [Message] = []
        for objectData in Self.scanJSONObjects(in: data) {
            if let msg = try? decoder.decode(Message.self, from: objectData) {
                result.append(msg)
            }
        }
        return result
    }

    /// Walks `data` and yields each balanced top-level `{...}` block.
    /// Tolerates both compact JSONL (one object per line) and legacy pretty-printed concatenated objects.
    private static func scanJSONObjects(in data: Data) -> [Data] {
        var out: [Data] = []
        var depth = 0
        var inString = false
        var escape = false
        var start: Data.Index? = nil
        for i in data.indices {
            let b = data[i]
            if inString {
                if escape {
                    escape = false
                } else if b == 0x5C { // \
                    escape = true
                } else if b == 0x22 { // "
                    inString = false
                }
                continue
            }
            switch b {
            case 0x22: // "
                inString = true
            case 0x7B: // {
                if depth == 0 { start = i }
                depth += 1
            case 0x7D: // }
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let s = start {
                        out.append(data.subdata(in: s..<(i + 1)))
                        start = nil
                    }
                }
            default:
                break
            }
        }
        return out
    }

    func appendToTranscript(_ message: Message, projectID: UUID) {
        do {
            let data = try lineEncoder.encode(message)
            let line = (String(data: data, encoding: .utf8) ?? "") + "\n"
            let url = AppPaths.transcriptFile(for: projectID)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                if let bytes = line.data(using: .utf8) {
                    try handle.write(contentsOf: bytes)
                }
                try handle.close()
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            lastError = "Failed to write transcript: \(error.localizedDescription)"
        }
    }
}
