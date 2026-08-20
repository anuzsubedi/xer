import AppKit
import SwiftUI

extension ContentView {

    var projectSidebar: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("PROJECTS")
                        Spacer()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)

                    if model.projects.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "shippingbox")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("No projects yet")
                                .font(.headline)
                            Text("Import a folder of projects, or add a single .xcodeproj / .xcworkspace.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Import Folder…") {
                                model.chooseAndImportParentFolder()
                            }
                            .disabled(model.isBusy)
                            Button("Add Project…") {
                                model.chooseAndImportProject()
                            }
                            .disabled(model.isBusy)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 28)
                    } else {
                        ForEach(filteredProjectGroups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder")
                                    Text(group.displayName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Button {
                                        removalCandidate = .folder(
                                            path: group.folderPath,
                                            name: group.displayName,
                                            projectCount: group.totalProjectCount
                                        )
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove imported folder from xer")
                                    .accessibilityLabel("Remove imported folder \(group.displayName)")
                                    .disabled(model.isBusy)
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 6)

                                ForEach(group.projects) { project in
                                    Button {
                                        guard project.id != model.selectedProjectID else { return }
                                        model.selectProject(project.id)
                                    } label: {
                                        ProjectRow(project: project, icon: model.projectIcon(for: project))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .background(
                                                project.id == model.selectedProjectID
                                                    ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.16)
                                                    : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            )
                                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            removalCandidate = .project(project)
                                        } label: {
                                            Label("Remove Project…", systemImage: "trash")
                                        }
                                        Button(role: .destructive) {
                                            removalCandidate = .folder(
                                                path: group.folderPath,
                                                name: group.displayName,
                                                projectCount: group.totalProjectCount
                                            )
                                        } label: {
                                            Label("Remove Imported Folder…", systemImage: "folder.badge.minus")
                                        }
                                    }
                                    .accessibilityAddTraits(project.id == model.selectedProjectID ? .isSelected : [])
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 18)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity)

            Divider()

            HStack(spacing: 10) {
                Menu {
                    Button("Import Folder…") {
                        model.chooseAndImportParentFolder()
                    }
                    Button("Add Project…") {
                        model.chooseAndImportProject()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Import a folder of projects, or add a single project (⌘O / ⇧⌘O)")
                .accessibilityLabel("Add projects")
                .disabled(model.isBusy)

                Button {
                    if let project = model.selectedProject {
                        removalCandidate = .project(project)
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(model.isBusy || model.selectedProject == nil)
                .accessibilityLabel("Remove project")

                sidebarSearchField

                Button {
                    updateManager.showUpdateCheck()
                } label: {
                    Image(systemName: updateManager.updateAvailable ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(updateManager.updateAvailable ? XerTheme.action : .secondary)
                }
                .buttonStyle(.borderless)
                .help(updateManager.updateAvailable ? "Update available" : "Check for updates")
                .accessibilityLabel(updateManager.updateAvailable ? "Update available" : "Check for updates")
                .overlay(alignment: .topTrailing) {
                    if updateManager.updateAvailable {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(.thinMaterial)
    }

    var filteredProjects: [ImportedProject] {
        guard !projectQuery.isEmpty else { return model.projects }
        return model.projects.filter {
            $0.displayName.localizedCaseInsensitiveContains(projectQuery)
                || $0.path.localizedCaseInsensitiveContains(projectQuery)
        }
    }

    var filteredProjectGroups: [SidebarProjectGroup] {
        let grouped = Dictionary(grouping: filteredProjects) { project in
            project.parentPath
                ?? project.url.deletingLastPathComponent().standardizedFileURL.path
        }
        return grouped.map { folderPath, projects in
            SidebarProjectGroup(
                folderPath: folderPath,
                projects: projects.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                },
                totalProjectCount: model.projects.count { project in
                    let projectFolderPath = project.parentPath
                        ?? project.url.deletingLastPathComponent().standardizedFileURL.path
                    return URL(fileURLWithPath: projectFolderPath, isDirectory: true)
                        .standardizedFileURL.path == URL(fileURLWithPath: folderPath, isDirectory: true)
                        .standardizedFileURL.path
                }
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $projectQuery)
                .textFieldStyle(.plain)
            if !projectQuery.isEmpty {
                Button {
                    projectQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 26)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}
