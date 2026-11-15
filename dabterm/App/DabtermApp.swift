import SwiftUI

@main
struct DabtermApp: App {
    @StateObject private var model = AppModel()
    init() { Workspace.bootstrap() }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).preferredColorScheme(.dark)
        }
    }
}

/// Shared app state: terminal sessions, editor requests, settings.
@MainActor
final class AppModel: ObservableObject {
    @Published var tab: Tab = .terminal
    @Published var sessions: [ShellSession] = []
    @Published var activeSession: ShellSession?
    @Published var editorRequest: URL? = nil
    @Published var editorLine: Int? = nil
    @Published var editorFolder: URL = Workspace.home
    @AppStorage("fontSize") var fontSize: Double = 13
    @AppStorage("editorFontSize") var editorFontSize: Double = 14
    @AppStorage("editorWrap") var editorWrap: Bool = true

    enum Tab: Hashable { case terminal, editor, hosts, settings }

    init() {
        newSession()
        SmokeTest.runIfRequested(model: self)
    }

    func newSession() {
        let s = ShellSession()
        s.openInEditor = { [weak self] url, line in self?.open(url, line: line) }
        sessions.append(s); activeSession = s
    }
    /// Open a file (jumping to `line`) or a folder (as the workspace root) in the editor tab.
    func open(_ url: URL, line: Int? = nil) {
        if Workspace.isDirectory(url) { editorFolder = url }
        else {
            // keep the current workspace root if the file is inside it
            if !url.path.hasPrefix(editorFolder.path + "/") { editorFolder = url.deletingLastPathComponent() }
            editorLine = line
            editorRequest = url
        }
        tab = .editor
    }

    /// Handles files handed to us by Files, Safari "Open in…", the share sheet, or dabterm:// URLs.
    /// Files outside our sandbox are copied into ~/inbox (we can't keep security-scoped access
    /// across launches, and the shell needs a real path).
    func handleIncoming(_ url: URL) {
        if url.scheme == "dabterm" {
            // dabterm://open?path=~/x.txt&line=3   dabterm://run?cmd=ls
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let q = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            switch url.host {
            case "open": if let p = q["path"] { open(Workspace.resolve(p, cwd: Workspace.home), line: q["line"].flatMap(Int.init)) }
            case "run": if let c = q["cmd"] { runInTerminal(c) }
            case "ssh": if let h = q["host"] { runInTerminal("ssh \(shellQuote(h))") }
            default: break
            }
            return
        }
        guard url.isFileURL else { return }
        if url.standardizedFileURL.path.hasPrefix(Workspace.root.path) { open(url.standardizedFileURL); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let inbox = Workspace.root.appendingPathComponent("inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var dest = inbox.appendingPathComponent(url.lastPathComponent)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = inbox.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(n).\(url.pathExtension)"); n += 1
        }
        var coordError: NSError? = nil
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            try? FileManager.default.copyItem(at: readURL, to: dest)
        }
        guard FileManager.default.fileExists(atPath: dest.path) else { return }
        if Workspace.isDirectory(dest) { open(dest) }
        else if isTextLike(dest) { open(dest) }
        else { runInTerminal("cd ~/inbox && ls -la") }
    }
    private func isTextLike(_ url: URL) -> Bool {
        guard let d = FileManager.default.contents(atPath: url.path) else { return false }
        return d.isEmpty || String(data: d.prefix(4096), encoding: .utf8) != nil
    }

    func close(_ s: ShellSession) {
        sessions.removeAll { $0 === s }
        if sessions.isEmpty { newSession() } else if activeSession === s { activeSession = sessions.last }
    }
    func runInTerminal(_ line: String) {
        tab = .terminal
        guard let s = activeSession else { return }
        s.write("\n"); s.run(line: line)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView(selection: $model.tab) {
            TerminalTabView().tabItem { Label("Terminal", systemImage: "terminal") }.tag(AppModel.Tab.terminal)
            EditorScreen().tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }.tag(AppModel.Tab.editor)
            HostsView().tabItem { Label("SSH", systemImage: "network") }.tag(AppModel.Tab.hosts)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppModel.Tab.settings)
        }
        .tint(.cyan)
        .onOpenURL { url in model.handleIncoming(url) }
    }
}

/// Terminal tab: a tab strip for multiple sessions plus the active terminal.
struct TerminalTabView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.sessions, id: \.self) { s in
                            SessionChip(session: s, active: model.activeSession === s) { model.activeSession = s } close: { model.close(s) }
                        }
                    }
                }
                Button { model.newSession() } label: { Image(systemName: "plus").font(.system(size: 14, weight: .semibold)) }
                    .buttonStyle(.plain).padding(.horizontal, 6)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color(white: 0.08))
            ZStack {
                ForEach(model.sessions, id: \.self) { s in
                    TerminalContainer(session: s, fontSize: model.fontSize)
                        .opacity(model.activeSession === s ? 1 : 0)
                        .allowsHitTesting(model.activeSession === s)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

struct SessionChip: View {
    @ObservedObject var session: ShellSession
    let active: Bool; let select: () -> Void; let close: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(session.title).font(.system(size: 12, weight: active ? .semibold : .regular, design: .monospaced)).lineLimit(1)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain).opacity(0.6)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(active ? Color(white: 0.2) : Color(white: 0.12), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(active ? .white : .gray)
        .onTapGesture(perform: select)
    }
}

extension ShellSession: Hashable {
    static func == (a: ShellSession, b: ShellSession) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

/// Developer hook: `SIMCTL_CHILD_DABTERM_SMOKE="help;;ls;;ping -c 1 1.1.1.1" xcrun simctl launch ...`
/// runs the commands at startup and writes their output to Documents/smoke.log.
/// `SIMCTL_CHILD_DABTERM_TAB=editor|hosts|settings` opens a tab, `DABTERM_OPEN=path` opens a file.
enum SmokeTest {
    final class FileSink: OutputSink {
        let url: URL
        init(url: URL) { self.url = url; try? "".write(to: url, atomically: true, encoding: .utf8) }
        func write(_ text: String) {
            let clean = text.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression).replacingOccurrences(of: "\r", with: "")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(clean.utf8)); try? h.close() }
        }
    }
    @MainActor static func runIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let tab = env["DABTERM_TAB"] {
            switch tab { case "editor": model.tab = .editor; case "hosts": model.tab = .hosts; case "settings": model.tab = .settings; default: break }
        }
        if let open = env["DABTERM_OPEN"] { model.editorRequest = Workspace.resolve(open, cwd: Workspace.home); model.tab = .editor }
        guard let script = env["DABTERM_SMOKE"] else { return }
        let session = ShellSession()
        let sink = FileSink(url: Workspace.root.appendingPathComponent("smoke.log"))
        session.terminal = sink
        Task {
            for line in script.components(separatedBy: ";;") {
                sink.write("\n$ \(line)\n")
                await session.execute(line: line)
                sink.write("[exit \(session.env["?"] ?? "?")]\n")
            }
            sink.write("\nDONE\n")
        }
    }
}
