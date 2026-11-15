import Foundation
import CryptoKit

/// A GitHub-backed working copy. State lives in `.dabgit/state.json` inside the folder:
/// the remote, branch, HEAD commit, and the blob SHA of every tracked file at HEAD.
/// Status = compare current file hashes against the index; commit = create blobs/tree/commit
/// through the GitHub Git Data API and advance the branch ref.
final class GitRepo {
    struct State: Codable {
        var owner: String; var name: String; var branch: String
        var head: String; var headTree: String
        var index: [String: String]        // path -> blob sha at HEAD
        var modes: [String: String]        // path -> mode
        var staged: Set<String> = []       // paths explicitly added (empty means commit -a semantics)
        var remoteURL: String { "https://github.com/\(owner)/\(name).git" }
    }
    let root: URL
    var state: State
    static let dirName = ".dabgit"
    static let ignored: Set<String> = [".dabgit", ".DS_Store", "node_modules", ".git"]

    init(root: URL, state: State) { self.root = root; self.state = state }

    static func open(at url: URL) -> GitRepo? {
        var dir = url.standardizedFileURL
        while dir.path.count >= Workspace.root.path.count {
            let f = dir.appendingPathComponent(dirName).appendingPathComponent("state.json")
            if let d = FileManager.default.contents(atPath: f.path), let s = try? JSONDecoder().decode(State.self, from: d) { return GitRepo(root: dir, state: s) }
            if dir.path == Workspace.root.path || dir.path == "/" { break }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
    func save() throws {
        let d = root.appendingPathComponent(Self.dirName)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: d.appendingPathComponent("state.json"))
    }

    /// git's blob hash: sha1("blob <len>\0" + content)
    static func blobSHA(_ data: Data) -> String {
        var h = Insecure.SHA1(); h.update(data: Data("blob \(data.count)\u{0}".utf8)); h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var ignorePatterns: [String] {
        guard let t = try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8) else { return [] }
        return t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
    }
    func isIgnored(_ rel: String) -> Bool {
        let comps = rel.split(separator: "/").map(String.init)
        if comps.contains(where: { Self.ignored.contains($0) }) { return true }
        for p in ignorePatterns {
            var pat = p
            let anchored = pat.hasPrefix("/"); if anchored { pat.removeFirst() }
            if pat.hasSuffix("/") { pat.removeLast() }
            if anchored || pat.contains("/") { if Glob.match(pat, rel) || rel.hasPrefix(pat + "/") { return true } }
            else if comps.contains(where: { Glob.match(pat, $0) }) { return true }
        }
        return false
    }

    /// All files currently in the working tree (relative paths).
    func workingFiles() -> [String: URL] {
        var out: [String: URL] = [:]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return out }
        for case let u as URL in en {
            let rel = String(u.path.dropFirst(root.path.count + 1))
            if isIgnored(rel) { if Workspace.isDirectory(u) { en.skipDescendants() }; continue }
            if Workspace.isDirectory(u) { continue }
            out[rel] = u
        }
        return out
    }

    struct Status { var modified: [String] = []; var added: [String] = []; var deleted: [String] = []; var isClean: Bool { modified.isEmpty && added.isEmpty && deleted.isEmpty } }
    func status() -> Status {
        var s = Status()
        let files = workingFiles()
        for (rel, url) in files {
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            let sha = Self.blobSHA(data)
            if let idx = state.index[rel] { if idx != sha { s.modified.append(rel) } } else { s.added.append(rel) }
        }
        for rel in state.index.keys where files[rel] == nil { s.deleted.append(rel) }
        s.modified.sort(); s.added.sort(); s.deleted.sort()
        return s
    }

    // MARK: clone / pull
    static func clone(owner: String, name: String, branch: String?, into dest: URL, client: GitHubClient, progress: (String) -> Void) async throws -> GitRepo {
        let repo = try await client.repo(owner, name)
        let br = branch ?? repo.defaultBranch
        let head = try await client.refSHA(owner, name, branch: br)
        let commit = try await client.commit(owner, name, sha: head)
        let entries = try await client.tree(owner, name, sha: commit.treeSHA)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var index: [String: String] = [:], modes: [String: String] = [:]
        let blobs = entries.filter { $0.type == "blob" }
        progress("Receiving objects: \(blobs.count) files")
        var done = 0
        try await withThrowingTaskGroup(of: (String, String, Data).self) { g in
            var it = blobs.makeIterator()
            var inflight = 0
            func addNext() -> Bool { guard let e = it.next() else { return false }; g.addTask { (e.path, e.sha, try await client.blob(owner, name, sha: e.sha)) }; return true }
            while inflight < 8, addNext() { inflight += 1 }
            while let (path, sha, data) = try await g.next() {
                inflight -= 1
                let url = dest.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                index[path] = sha
                done += 1
                if done % 25 == 0 || done == blobs.count { progress("Receiving objects: \(done)/\(blobs.count)") }
                if addNext() { inflight += 1 }
            }
        }
        for e in blobs { modes[e.path] = e.mode }
        for e in entries where e.type == "tree" { try? FileManager.default.createDirectory(at: dest.appendingPathComponent(e.path), withIntermediateDirectories: true) }
        let r = GitRepo(root: dest, state: State(owner: owner, name: name, branch: br, head: head, headTree: commit.treeSHA, index: index, modes: modes))
        try r.save()
        return r
    }

    /// Fast-forward pull: downloads changed blobs; refuses if local changes would be overwritten (unless force).
    func pull(client: GitHubClient, force: Bool, progress: (String) -> Void) async throws -> (updated: Int, newHead: String) {
        let remoteHead = try await client.refSHA(state.owner, state.name, branch: state.branch)
        if remoteHead == state.head { return (0, remoteHead) }
        let commit = try await client.commit(state.owner, state.name, sha: remoteHead)
        let entries = try await client.tree(state.owner, state.name, sha: commit.treeSHA)
        let local = status()
        let dirty = Set(local.modified + local.added + local.deleted)
        var updated = 0
        var newIndex: [String: String] = [:]
        for e in entries where e.type == "blob" {
            newIndex[e.path] = e.sha
            if state.index[e.path] == e.sha { continue }
            if dirty.contains(e.path) && !force { throw CommandError("local changes to \(e.path) would be overwritten by pull; commit them or use `git pull --force`") }
            let data = try await client.blob(state.owner, state.name, sha: e.sha)
            let url = root.appendingPathComponent(e.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            updated += 1
            progress("Updating \(e.path)")
            state.modes[e.path] = e.mode
        }
        for (path, _) in state.index where newIndex[path] == nil {
            if dirty.contains(path) && !force { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path)); updated += 1
        }
        state.index = newIndex; state.head = remoteHead; state.headTree = commit.treeSHA
        try save()
        return (updated, remoteHead)
    }

    // MARK: commit + push (one step: GitHub has no local object store)
    func commitAndPush(message: String, paths: [String]?, author: (String, String)?, client: GitHubClient, progress: (String) -> Void) async throws -> String {
        let s = status()
        var changed = Set(s.modified + s.added), deleted = Set(s.deleted)
        if let paths { let allow = Set(paths); changed = changed.filter { p in allow.contains(p) || allow.contains(where: { p.hasPrefix($0 + "/") }) }; deleted = deleted.filter { p in allow.contains(p) || allow.contains(where: { p.hasPrefix($0 + "/") }) } }
        guard !changed.isEmpty || !deleted.isEmpty else { throw CommandError("nothing to commit, working tree clean") }
        // Make sure we are on top of the remote.
        let remoteHead = try await client.refSHA(state.owner, state.name, branch: state.branch)
        if remoteHead != state.head { throw CommandError("remote branch has new commits; run `git pull` first") }
        var treeEntries: [[String: Any]] = []
        var newIndex = state.index
        for p in changed.sorted() {
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(p).path) else { continue }
            progress("Uploading \(p)")
            let sha = try await client.createBlob(state.owner, state.name, data: data)
            treeEntries.append(["path": p, "mode": state.modes[p] ?? (p.hasSuffix(".sh") ? "100755" : "100644"), "type": "blob", "sha": sha])
            newIndex[p] = sha
        }
        for p in deleted { treeEntries.append(["path": p, "mode": "100644", "type": "blob", "sha": NSNull()]); newIndex[p] = nil }
        let tree = try await client.createTree(state.owner, state.name, base: state.headTree, entries: treeEntries)
        let sha = try await client.createCommit(state.owner, state.name, message: message, tree: tree, parents: [state.head], author: author)
        try await client.updateRef(state.owner, state.name, branch: state.branch, sha: sha)
        state.head = sha; state.headTree = tree; state.index = newIndex; state.staged = []
        try save()
        return sha
    }

    func checkout(branch: String, create: Bool, client: GitHubClient, progress: (String) -> Void) async throws {
        if !status().isClean { throw CommandError("commit your changes before switching branches") }
        if create {
            try await client.createRef(state.owner, state.name, branch: branch, sha: state.head)
            state.branch = branch; try save(); return
        }
        state.branch = branch
        let head = try await client.refSHA(state.owner, state.name, branch: branch)
        state.head = ""  // force pull to refresh everything
        _ = try await pull(client: client, force: true, progress: progress)
        _ = head
    }

    func diff(_ path: String) -> String {
        guard let sha = state.index[path] else { return "+++ \(path) (new file)\n" }
        _ = sha
        return "diff for \(path): fetch the HEAD blob with `git show HEAD:\(path)`\n"
    }
}
