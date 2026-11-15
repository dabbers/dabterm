import Foundation

/// GitHub REST client covering what the git command needs: repo metadata, trees, blobs,
/// commits, refs, branches, plus the device-flow login.
struct GitHubClient {
    var token: String?
    let base = URL(string: "https://api.github.com/")!

    struct APIError: LocalizedError, CustomStringConvertible { let status: Int; let message: String; var description: String { "GitHub API \(status): \(message)" }; var errorDescription: String? { description } }

    private func request(_ method: String, _ path: String, body: Any? = nil, raw: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: path.hasPrefix("http") ? URL(string: path)! : URL(string: path, relativeTo: base)!.absoluteURL)
        req.httpMethod = method
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("dabterm", forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        if http.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? String(decoding: data, as: UTF8.self)
            if http.statusCode == 401 { throw APIError(status: 401, message: "bad credentials — run `gh auth login`") }
            if http.statusCode == 404, token == nil { throw APIError(status: 404, message: "\(msg) (private repo? run `gh auth login`)") }
            throw APIError(status: http.statusCode, message: msg)
        }
        return (data, http)
    }
    private func json(_ method: String, _ path: String, body: Any? = nil) async throws -> [String: Any] {
        let (d, _) = try await request(method, path, body: body)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
    private func jsonArray(_ path: String) async throws -> [[String: Any]] {
        let (d, _) = try await request("GET", path)
        return (try JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
    }

    // MARK: repos
    struct Repo { let fullName: String; let defaultBranch: String; let isPrivate: Bool; let description: String? }
    func repo(_ owner: String, _ name: String) async throws -> Repo {
        let j = try await json("GET", "repos/\(owner)/\(name)")
        return Repo(fullName: j["full_name"] as? String ?? "\(owner)/\(name)", defaultBranch: j["default_branch"] as? String ?? "main", isPrivate: j["private"] as? Bool ?? false, description: j["description"] as? String)
    }
    func branches(_ owner: String, _ name: String) async throws -> [(name: String, sha: String)] {
        try await jsonArray("repos/\(owner)/\(name)/branches?per_page=100").compactMap { b in
            guard let n = b["name"] as? String, let c = b["commit"] as? [String: Any], let s = c["sha"] as? String else { return nil }
            return (n, s)
        }
    }
    func myRepos() async throws -> [String] { try await jsonArray("user/repos?per_page=100&sort=updated").compactMap { $0["full_name"] as? String } }
    func viewer() async throws -> String { try await json("GET", "user")["login"] as? String ?? "?" }

    // MARK: refs / commits / trees / blobs
    func refSHA(_ owner: String, _ name: String, branch: String) async throws -> String {
        let j = try await json("GET", "repos/\(owner)/\(name)/git/ref/heads/\(branch)")
        guard let o = j["object"] as? [String: Any], let sha = o["sha"] as? String else { throw APIError(status: 0, message: "no ref") }
        return sha
    }
    struct Commit { let sha: String; let treeSHA: String; let message: String; let author: String; let date: String; let parents: [String] }
    func commit(_ owner: String, _ name: String, sha: String) async throws -> Commit {
        let j = try await json("GET", "repos/\(owner)/\(name)/git/commits/\(sha)")
        let tree = (j["tree"] as? [String: Any])?["sha"] as? String ?? ""
        let author = j["author"] as? [String: Any]
        return Commit(sha: sha, treeSHA: tree, message: j["message"] as? String ?? "", author: author?["name"] as? String ?? "", date: author?["date"] as? String ?? "", parents: ((j["parents"] as? [[String: Any]]) ?? []).compactMap { $0["sha"] as? String })
    }
    func log(_ owner: String, _ name: String, sha: String, count: Int) async throws -> [Commit] {
        try await jsonArray("repos/\(owner)/\(name)/commits?sha=\(sha)&per_page=\(count)").map { j in
            let c = j["commit"] as? [String: Any] ?? [:]
            let a = c["author"] as? [String: Any]
            return Commit(sha: j["sha"] as? String ?? "", treeSHA: (c["tree"] as? [String: Any])?["sha"] as? String ?? "", message: c["message"] as? String ?? "", author: a?["name"] as? String ?? "", date: a?["date"] as? String ?? "", parents: ((j["parents"] as? [[String: Any]]) ?? []).compactMap { $0["sha"] as? String })
        }
    }
    struct TreeEntry { let path: String; let mode: String; let type: String; let sha: String; let size: Int? }
    func tree(_ owner: String, _ name: String, sha: String) async throws -> [TreeEntry] {
        let j = try await json("GET", "repos/\(owner)/\(name)/git/trees/\(sha)?recursive=1")
        if j["truncated"] as? Bool == true { throw APIError(status: 0, message: "repository tree too large for the API (>100k entries)") }
        return ((j["tree"] as? [[String: Any]]) ?? []).map { TreeEntry(path: $0["path"] as? String ?? "", mode: $0["mode"] as? String ?? "100644", type: $0["type"] as? String ?? "blob", sha: $0["sha"] as? String ?? "", size: $0["size"] as? Int) }
    }
    func blob(_ owner: String, _ name: String, sha: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "repos/\(owner)/\(name)/git/blobs/\(sha)", relativeTo: base)!.absoluteURL)
        req.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        req.setValue("dabterm", forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard (resp as! HTTPURLResponse).statusCode < 400 else { throw APIError(status: (resp as! HTTPURLResponse).statusCode, message: "blob fetch failed") }
        return d
    }
    func createBlob(_ owner: String, _ name: String, data: Data) async throws -> String {
        let j = try await json("POST", "repos/\(owner)/\(name)/git/blobs", body: ["content": data.base64EncodedString(), "encoding": "base64"])
        return j["sha"] as? String ?? ""
    }
    func createTree(_ owner: String, _ name: String, base: String?, entries: [[String: Any]]) async throws -> String {
        var body: [String: Any] = ["tree": entries]
        if let base { body["base_tree"] = base }
        return try await json("POST", "repos/\(owner)/\(name)/git/trees", body: body)["sha"] as? String ?? ""
    }
    func createCommit(_ owner: String, _ name: String, message: String, tree: String, parents: [String], author: (String, String)?) async throws -> String {
        var body: [String: Any] = ["message": message, "tree": tree, "parents": parents]
        if let a = author { body["author"] = ["name": a.0, "email": a.1, "date": ISO8601DateFormatter().string(from: Date())] }
        return try await json("POST", "repos/\(owner)/\(name)/git/commits", body: body)["sha"] as? String ?? ""
    }
    func updateRef(_ owner: String, _ name: String, branch: String, sha: String, force: Bool = false) async throws {
        _ = try await json("PATCH", "repos/\(owner)/\(name)/git/refs/heads/\(branch)", body: ["sha": sha, "force": force])
    }
    func createRef(_ owner: String, _ name: String, branch: String, sha: String) async throws {
        _ = try await json("POST", "repos/\(owner)/\(name)/git/refs", body: ["ref": "refs/heads/\(branch)", "sha": sha])
    }
    func createRepo(name: String, isPrivate: Bool, description: String?) async throws -> Repo {
        var body: [String: Any] = ["name": name, "private": isPrivate, "auto_init": true]
        if let d = description { body["description"] = d }
        let j = try await json("POST", "user/repos", body: body)
        return Repo(fullName: j["full_name"] as? String ?? name, defaultBranch: j["default_branch"] as? String ?? "main", isPrivate: isPrivate, description: description)
    }
    func createPR(_ owner: String, _ name: String, title: String, head: String, base: String, body: String) async throws -> String {
        let j = try await json("POST", "repos/\(owner)/\(name)/pulls", body: ["title": title, "head": head, "base": base, "body": body])
        return j["html_url"] as? String ?? ""
    }
    func pulls(_ owner: String, _ name: String) async throws -> [(Int, String, String)] {
        try await jsonArray("repos/\(owner)/\(name)/pulls?state=open").map { ($0["number"] as? Int ?? 0, $0["title"] as? String ?? "", ($0["head"] as? [String: Any])?["ref"] as? String ?? "") }
    }
    func issues(_ owner: String, _ name: String) async throws -> [(Int, String)] {
        try await jsonArray("repos/\(owner)/\(name)/issues?state=open").filter { $0["pull_request"] == nil }.map { ($0["number"] as? Int ?? 0, $0["title"] as? String ?? "") }
    }

    // MARK: device flow
    /// GitHub OAuth app client id for the device flow. Public by design (device-flow apps have no secret).
    /// Replace with your own OAuth app's client id (Settings → Developer settings → OAuth Apps, enable Device Flow).
    static let clientID = "Ov23liDabtermDeviceFlow0"
    struct DeviceCode { let deviceCode: String; let userCode: String; let verificationURL: String; let interval: Int }
    static func startDeviceFlow() async throws -> DeviceCode {
        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Accept"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID, "scope": "repo read:user"])
        let (d, _) = try await URLSession.shared.data(for: req)
        guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any], let dc = j["device_code"] as? String else { throw APIError(status: 0, message: "device flow unavailable: \(String(decoding: d, as: UTF8.self))") }
        return DeviceCode(deviceCode: dc, userCode: j["user_code"] as? String ?? "", verificationURL: j["verification_uri"] as? String ?? "https://github.com/login/device", interval: j["interval"] as? Int ?? 5)
    }
    static func pollDeviceFlow(_ code: DeviceCode) async throws -> String? {
        var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Accept"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID, "device_code": code.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
        let (d, _) = try await URLSession.shared.data(for: req)
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
        if let t = j["access_token"] as? String { return t }
        let err = j["error"] as? String ?? ""
        if err == "authorization_pending" || err == "slow_down" { return nil }
        throw APIError(status: 0, message: j["error_description"] as? String ?? err)
    }
}
