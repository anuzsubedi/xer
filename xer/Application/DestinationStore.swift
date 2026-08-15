import Foundation

struct DestinationStore {
    var destinations: [Destination] = []
    var warning: String?
    var searchQuery = ""
    var selectedIDs: Set<String> = []
}
