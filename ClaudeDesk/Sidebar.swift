import SwiftUI
import AppKit

struct Sidebar: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var newProjectName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedID) {
                if store.projects.isEmpty {
                    Text("No projects yet")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(sortedProjects) { project in
                        SidebarRow(project: project)
                            .tag(project.id)
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([project.directoryURL])
                                }
                                Divider()
                                Button("Remove from List", role: .destructive) {
                                    store.remove(project.id)
                                }
                            }
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
    }

    private var sortedProjects: [Project] {
        store.projects.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
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
