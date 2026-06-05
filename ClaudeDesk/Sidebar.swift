import SwiftUI
import AppKit

struct Sidebar: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var newProjectName: String = ""
    @State private var renamingProject: Project?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedID) {
                if store.projects.isEmpty {
                    Text("No projects yet")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.projects) { project in
                        SidebarRow(project: project)
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
            }
            .padding(8)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .font(.system(size: 13, weight: .medium))
            Text(project.directoryPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
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
