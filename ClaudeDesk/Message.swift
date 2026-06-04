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

    init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}
