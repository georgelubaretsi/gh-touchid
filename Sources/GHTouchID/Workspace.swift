import Foundation

// What `gh-touchid session` covers without --repo: the outermost Git repository containing the current folder and
// the Git repositories nested up to two levels below it (an umbrella checkout with clones inside), keeping those with
// a github.com `origin` whose owner has an App stored.

/// The session's repositories found from the current folder.
func workspaceRepositories() throws -> [String] {
    let current = FileManager.default.currentDirectoryPath
    guard let root = outermostRepository(containing: current) else {
        throw ToolError.input("no Git repository contains \(displayFolder(current)); name repositories with --repo")
    }
    var folders = [root]
    for child in subfolders(of: root) {
        if isRepository(child) {
            folders.append(child)
        }
        folders += subfolders(of: child).filter(isRepository)
    }

    var repositories: [String] = []
    for folder in folders {
        guard let repository = try? repositoryIdentifier(in: folder),
              hasAppCredentials(owner: ownerAccount(repository)),
              !repositories.contains(where: { $0.lowercased() == repository.lowercased() }) else {
            continue
        }
        repositories.append(repository)
    }
    guard !repositories.isEmpty else {
        throw ToolError.input(
            "no Git repository in \(displayFolder(root)) or nested in it has a github.com origin whose owner has "
                + "a GitHub App stored; name repositories with --repo"
        )
    }
    return repositories
}

private func isRepository(_ folder: String) -> Bool {
    FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(".git"))
}

/// The topmost folder at or above `folder` that is a Git repository.
private func outermostRepository(containing folder: String) -> String? {
    var found: String?
    var current = folder
    while true {
        if isRepository(current) {
            found = current
        }
        let parent = (current as NSString).deletingLastPathComponent
        if parent == current || parent.isEmpty {
            return found
        }
        current = parent
    }
}

/// The folders directly inside `folder`, without hidden ones and symbolic links.
private func subfolders(of folder: String) -> [String] {
    let url = URL(fileURLWithPath: folder, isDirectory: true)
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    return entries.filter { entry in
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }.map(\.path).sorted()
}
