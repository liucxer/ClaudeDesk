import SwiftUI

@main
struct ClaudeDeskApp: App {
    @StateObject private var store: ProjectStore
    @StateObject private var sessions: SessionStore

    init() {
        let projectStore = ProjectStore()
        _store = StateObject(wrappedValue: projectStore)
        _sessions = StateObject(wrappedValue: SessionStore(projectStore: projectStore))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(sessions)
                .environmentObject(PermissionGateway.shared)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { store.requestNewProject() }
                    .keyboardShortcut("n")
                Button("Open Project…") { store.requestOpenProject() }
                    .keyboardShortcut("o")
            }
        }
    }
}
