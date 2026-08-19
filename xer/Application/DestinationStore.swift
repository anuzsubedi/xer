import Foundation

struct DestinationStore {
    var destinations: [Destination] = []
    var warning: String?
    var searchQuery = ""
    var selectedIDs: Set<String> = []
    var schemeCompatibleIDs: Set<String>?
    var schemeDestinationNote: String?
}
