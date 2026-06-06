import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct Message: Codable, Identifiable, Hashable {
    let id: UUID
    let role: MessageRole
    var text: String
    let timestamp: Date
    /// Filenames (just basenames, like `<uuid>.png`) inside
    /// `AppPaths.attachmentsDir`. Optional + decoded lazily so older
    /// transcripts without this field still load.
    var attachments: [String]?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        timestamp: Date = Date(),
        attachments: [String]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.attachments = attachments
    }
}
