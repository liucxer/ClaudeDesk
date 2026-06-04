import SwiftUI

@main
struct ClaudeDeskApp: App {
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
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
