import Foundation

struct ProjectStore {
    var projects: [ImportedProject] = []
    var parentFolderURL: URL?
    var projectIcons: [String: AppIcon] = [:]
    var selectedProjectID: String?
    var selectedSchemeByProject: [String: String] = [:]
}
