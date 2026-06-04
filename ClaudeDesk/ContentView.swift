import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ProjectStore

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let project = store.selectedProject {
                ChatView(project: project)
                    .id(project.id)
            } else {
                EmptyProjectPlaceholder()
            }
        }
    }
}

private struct EmptyProjectPlaceholder: View {
    @EnvironmentObject private var store: ProjectStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Select a project, or create a new one.")
                .foregroundStyle(.secondary)
            HStack {
                Button("New Project…") { store.requestNewProject() }
                Button("Open Existing…") { store.requestOpenProject() }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
