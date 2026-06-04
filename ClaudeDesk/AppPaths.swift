import Foundation

enum AppPaths {
    static let baseURL: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("ClaudeDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let projectsFile: URL = baseURL.appendingPathComponent("projects.json")

    static let sessionsDir: URL = {
        let dir = baseURL.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func transcriptFile(for projectID: UUID) -> URL {
        sessionsDir.appendingPathComponent("\(projectID.uuidString).jsonl")
    }

    static let defaultProjectsRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("ClaudeDesk/Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
