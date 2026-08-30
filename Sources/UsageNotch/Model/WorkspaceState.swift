import Foundation

/// Local repository state for a workspace that currently has a live agent session.
/// Nothing here requires a network request or mutates the repository.
struct WorkspaceState: Identifiable, Equatable {
    var id: String { rootPath }
    var project: String
    var rootPath: String
    var branch: String
    var changedFiles: Int
    var ahead: Int
    var behind: Int
    var checkedAt: Date

    var isClean: Bool { changedFiles == 0 }
}
