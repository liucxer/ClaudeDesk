import Foundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var selectedID: UUID?
    @Published var isPresentingNewProjectPrompt: Bool = false
    @Published var lastError: String?

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
        if selectedID == nil { selectedID = projects.first?.id }
    }

    var selectedProject: Project? {
        guard let id = selectedID else { return nil }
        return projects.first { $0.id == id }
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
        if selectedID == id { selectedID = projects.first?.id }
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
        selectedID = project.id
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
            selectedID = existing.id
            return
        }
        let project = Project(
            name: url.lastPathComponent,
            directoryPath: url.path
        )
        projects.append(project)
        selectedID = project.id
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
