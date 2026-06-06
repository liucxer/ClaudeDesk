import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var gateway: PermissionGateway

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            let selected = store.selectedProjects
            if selected.isEmpty {
                EmptyProjectPlaceholder()
            } else if selected.count == 1 {
                ChatView(project: selected[0])
                    .id(selected[0].id)
            } else {
                // Multi-select: lay chats out side-by-side. HSplitView lets
                // the user drag pane widths; each chat enforces a min width
                // so the composer + bubble cap stay usable.
                HSplitView {
                    ForEach(selected) { project in
                        ChatView(project: project)
                            .id(project.id)
                            // idealWidth seeds HSplitView with the last
                            // remembered pane width; when no saved value
                            // exists, fall through to HSplitView's default
                            // equal distribution.
                            .frame(
                                minWidth: 380,
                                idealWidth: store.paneWidths[project.id].map { CGFloat($0) }
                            )
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .onChange(of: geo.size.width) { newWidth in
                                            store.recordPaneWidth(
                                                project.id,
                                                width: Double(newWidth)
                                            )
                                        }
                                }
                            )
                    }
                }
                // Bumping splitLayoutGeneration discards the underlying
                // NSSplitView so it re-inits with equal widths (driven by the
                // now-nil idealWidths). This is the only reliable way to force
                // a redistribute after the user dragged dividers.
                .id(store.splitLayoutGeneration)
            }
        }
        .sheet(item: $gateway.pending, onDismiss: gateway.handleSheetDismiss) { request in
            PermissionDialog(request: request)
                .interactiveDismissDisabled()
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
