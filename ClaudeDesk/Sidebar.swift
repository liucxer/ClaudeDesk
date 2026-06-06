import SwiftUI
import AppKit

struct Sidebar: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var sessions: SessionStore
    @State private var newProjectName: String = ""
    @State private var renamingProject: Project?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedIDs) {
                if store.projects.isEmpty {
                    Text("No projects yet")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.projects) { project in
                        SidebarRow(
                            project: project,
                            isRunning: sessions.runningIDs.contains(project.id),
                            hasUnseen: sessions.unseenIDs.contains(project.id),
                            isStuck: sessions.stuckIDs.contains(project.id)
                        )
                            .tag(project.id)
                            .contextMenu {
                                Button("Rename…") {
                                    renamingProject = project
                                }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([project.directoryURL])
                                }
                                Divider()
                                Button("Move Up") {
                                    store.moveUp(project.id)
                                }
                                .disabled(store.projects.first?.id == project.id)
                                Button("Move Down") {
                                    store.moveDown(project.id)
                                }
                                .disabled(store.projects.last?.id == project.id)
                                Divider()
                                Button("Remove from List", role: .destructive) {
                                    sessions.remove(project.id)
                                    store.remove(project.id)
                                }
                            }
                    }
                    .onMove { indices, newOffset in
                        store.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button {
                    store.requestNewProject()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .help("Create a new project under ~/ClaudeDesk/Projects")

                Button {
                    store.requestOpenProject()
                } label: {
                    Label("Open…", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .help("Add an existing directory as a project")

                Spacer()

                // Only useful when 2+ projects are visible in the split view.
                if store.selectedIDs.count > 1 {
                    Button {
                        store.equalizeSelectedPaneWidths()
                    } label: {
                        Image(systemName: "rectangle.split.3x1")
                    }
                    .buttonStyle(.bordered)
                    .help("把当前打开的工程平分宽度")
                }
            }
            .padding(8)

            Text("⌘ + 点击 多选 · 拖拽 可换序")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $store.isPresentingNewProjectPrompt, onDismiss: { newProjectName = "" }) {
            NewProjectSheet(name: $newProjectName) { name in
                store.createNewProject(named: name)
                store.isPresentingNewProjectPrompt = false
            } onCancel: {
                store.isPresentingNewProjectPrompt = false
            }
        }
        .sheet(item: $renamingProject) { project in
            RenameSheet(initialName: project.name) { newName in
                store.rename(project.id, to: newName)
                renamingProject = nil
            } onCancel: {
                renamingProject = nil
            }
        }
    }

}

private struct SidebarRow: View {
    let project: Project
    let isRunning: Bool
    let hasUnseen: Bool
    let isStuck: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                Text(project.directoryPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            statusIndicator
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isStuck {
            // Stuck wins over the spinner — the spinner says "working", which
            // is misleading when the turn has actually been silent for 90s+.
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.medium)
                .help("Turn appears stuck (no activity for 90s+). Try Stop in the chat view.")
        } else if isRunning {
            ProgressView()
                .controlSize(.mini)
        } else if hasUnseen {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .help("New response — click to view")
        }
    }
}

private struct NewProjectSheet: View {
    @Binding var name: String
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Project")
                .font(.headline)
            Text("A new directory will be created under ~/ClaudeDesk/Projects/.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
    }
}

private struct RenameSheet: View {
    @State private var name: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    init(initialName: String, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self._name = State(initialValue: initialName)
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Project")
                .font(.headline)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}
