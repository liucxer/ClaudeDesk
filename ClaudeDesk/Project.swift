import Foundation

struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var directoryPath: String
    let createdAt: Date
    var hasStartedSession: Bool

    init(
        id: UUID = UUID(),
        name: String,
        directoryPath: String,
        createdAt: Date = Date(),
        hasStartedSession: Bool = false
    ) {
        self.id = id
        self.name = name
        self.directoryPath = directoryPath
        self.createdAt = createdAt
        self.hasStartedSession = hasStartedSession
    }

    var directoryURL: URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
    }

    var directoryExists: Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDir)
        return ok && isDir.boolValue
    }
}
