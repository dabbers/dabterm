import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var token = ""
    @State private var loggedInAs: String? = nil
    @AppStorage("git.user.name") private var gitName = ""
    @AppStorage("git.user.email") private var gitEmail = ""
    @State private var storageInfo = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Terminal") {
                    HStack { Text("Font size"); Slider(value: $app.fontSize, in: 9...22, step: 1); Text("\(Int(app.fontSize))").monospacedDigit().frame(width: 28) }
                    Button("Clear command history") { try? FileManager.default.removeItem(at: ShellSession.historyURL); app.sessions.forEach { $0.history = [] } }
                }
                Section("Editor") {
                    HStack { Text("Font size"); Slider(value: $app.editorFontSize, in: 10...24, step: 1); Text("\(Int(app.editorFontSize))").monospacedDigit().frame(width: 28) }
                    Toggle("Wrap long lines", isOn: $app.editorWrap)
                }
                Section("GitHub") {
                    if let u = loggedInAs {
                        LabeledContent("Signed in as", value: u)
                        Button("Sign out", role: .destructive) { Keychain.delete(Keychain.githubTokenKey); loggedInAs = nil }
                    } else {
                        Button("Sign in with device code") { app.runInTerminal("gh auth login") }
                        SecureField("…or paste a personal access token", text: $token)
                        Button("Save token") { Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.githubTokenKey); token = ""; Task { await checkLogin() } }.disabled(token.isEmpty)
                        Text("Create a fine-grained token at github.com/settings/tokens with Contents: read & write on the repos you want to use. It is stored in the Keychain, never in the Files folder.").font(.footnote).foregroundStyle(.secondary)
                    }
                    TextField("Commit author name", text: $gitName)
                    TextField("Commit author email", text: $gitEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
                Section("Files") {
                    LabeledContent("Home folder", value: "Files → On My iPhone → dabterm")
                    Text(storageInfo).font(.footnote).foregroundStyle(.secondary)
                    Button("Open home in editor") { app.editorFolder = Workspace.home; app.tab = .editor }
                    Button("Recreate default folders & sample config") { Workspace.bootstrap() }
                }
                Section("About") {
                    LabeledContent("dabterm", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Link("Source on GitHub", destination: URL(string: "https://github.com/dabbers/dabterm")!)
                    Text("Terminal: SwiftTerm · SSH: Citadel (SwiftNIO SSH) · Crypto: OpenSSL 3 · Editor: CodeMirror 6").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .task { await checkLogin(); computeStorage() }
        }
    }
    private func checkLogin() async {
        guard let t = Keychain.get(Keychain.githubTokenKey) else { loggedInAs = nil; return }
        loggedInAs = (try? await GitHubClient(token: t).viewer()) ?? "(token saved; offline)"
    }
    private func computeStorage() {
        var total: Int64 = 0; var files = 0
        if let en = FileManager.default.enumerator(at: Workspace.home, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in en { if let s = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += Int64(s); files += 1 } }
        }
        storageInfo = "\(files) files, \(Formatter.bytes(total)) in the dabterm folder"
    }
}
