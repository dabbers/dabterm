import SwiftUI
import UIKit

@main
struct DabtermApp: App {
    @StateObject private var model = AppModel()
    init() { Workspace.bootstrap() }
    var body: some Scene {
        WindowGroup {
            RootHost(model: model).ignoresSafeArea().preferredColorScheme(.dark)
        }
    }
}

/// Hosts RootView in a hosting controller with SwiftUI's keyboard avoidance switched off
/// (`safeAreaRegions` without `.keyboard`). The app pads for the keyboard itself from the frame
/// iOS reports; SwiftUI's own avoidance, even when ignored, still shrank the content on a half-open
/// iPhone Duo where the keyboard frame covers more than half the screen.
struct RootHost: UIViewControllerRepresentable {
    let model: AppModel
    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let hc = UIHostingController(rootView: AnyView(RootView().environmentObject(model)))
        hc.safeAreaRegions = .container
        hc.view.backgroundColor = .black
        return hc
    }
    func updateUIViewController(_ hc: UIHostingController<AnyView>, context: Context) {}
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
        ToolPackManager.shared.reload()
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

/// With a hardware keyboard attached iOS docks the key bar at the screen bottom without a
/// keyboard; SwiftUI does not inset for that, so the tab bar would sit under it. Track it.
@MainActor
final class KeyboardInset: ObservableObject {
    @Published var bottom: CGFloat = 0
    private var hiding = false
    private weak var dockedBar: KeyBar?
    private var settleWork: DispatchWorkItem?
    private func scheduleSettle() {
        settleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.settle() }
        settleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }
    private func settle() {
        guard !hiding, let bar = dockedBar, let bw = bar.window, let app = UIApplication.keyWindow else { return }
        let r = bw.convert(bar.bounds, from: bar)
        let bottomEdge = app.frame.maxY
        guard r.height > 0, r.minY > 0, r.minY < bottomEdge else { return }
        let v = max(0, bottomEdge - r.minY - app.safeAreaInsets.bottom)
        if abs(v - bottom) > 0.5 {
            HingeMonitor.shared.log("kb settle: bar at y=\(r.minY), inset \(bottom) -> \(v)")
            bottom = v
        }
        applyFold(keyboardTop: r.minY)
    }

    /// Half-open: iOS docks the accessory above the fold, keys at the bottom of the lower panel.
    /// Float the strip into the space under the fold and let the content use the accessory's band
    /// above it, so both bars sit next to what they belong to.
    private func applyFold(keyboardTop: CGFloat) {
        guard let bar = dockedBar, let app = UIApplication.keyWindow, let root = app.rootViewController?.view else { return }
        var fold: CGRect? = nil
        if #available(iOS 27.1, *) {
            fold = root.reservedRegions(kind: .division).first { $0.isActive && $0.frame.width > $0.frame.height }
                .map { root.convert($0.frame, to: app) }
        }
        guard !hiding, let fold, keyboardTop <= fold.minY + 1, keyboardTop > 0 else {
            if bar.isFloating { bar.unfloat(); HingeMonitor.shared.log("kb unfloat") }
            return
        }
        let h = bar.bounds.height
        bar.float(in: app, frame: CGRect(x: 0, y: fold.maxY, width: app.bounds.width, height: h))
        // The accessory's band above the fold is now empty: give it to the content.
        let want = max(0, app.frame.maxY - fold.minY - app.safeAreaInsets.bottom)
        if abs(want - bottom) > 0.5 { bottom = want }
        HingeMonitor.shared.log("kb float: strip at y=\(fold.maxY) fold=\(fold) inset=\(want)")
    }
    init() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let frame = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
                  let screen = (n.object as? UIScreen) ?? UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.screen }).first else { return }
            // Empty frames while the keyboard animates away mean "hidden", not a keyboard at the top.
            guard frame.height >= 50, frame.width >= 100 else { self.bottom = 0; return }
            // Our padding sits above the bottom safe area, which the keyboard covers: take it off.
            // On a half-open foldable the frame starts above the hinge and includes iOS's own gap
            // over it; the keys sit below. That is the keyboard's layout, so we simply pad by it.
            let window = UIApplication.keyWindow
            let safe = window?.safeAreaInsets.bottom ?? 0
            let bottomEdge = window?.frame.maxY ?? screen.bounds.height
            self.hiding = frame.minY >= bottomEdge
            self.bottom = max(0, min(frame.height, max(0, bottomEdge - frame.minY)) - safe)
            HingeMonitor.shared.log("kb frame=\(frame) screen=\(screen.bounds.size) window=\(window?.frame ?? .zero) inset=\(self.bottom)")
            self.applyFold(keyboardTop: frame.minY)
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hiding = true
            self?.bottom = 0
            self?.dockedBar?.unfloat()
        }
        // The notifications are not the last word on a foldable: at the end of a bent-to-flat
        // transition iOS sends one more with the stale bent frame. So once things settle, after a
        // keyboard change or a hinge move, measure where the key bar (the keyboard's accessory)
        // actually is and correct the inset from that.
        KeyBar.onPlaced = { [weak self] bar in self?.dockedBar = bar }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleSettle()
        }
        HingeMonitor.shared.onChange = { [weak self] in self?.scheduleSettle() }
        // Half a second after any keyboard change, record where things actually ended up.
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let w = UIApplication.keyWindow, let root = w.rootViewController?.view else { return }
                var line = "probe root=\(root.frame) rootSafe=\(root.safeAreaInsets) windowSafe=\(w.safeAreaInsets)"
                if let fr = UIApplication.firstResponder as? UIView, let fw = fr.window {
                    line += " responder=\(type(of: fr)) at \(fw.convert(fr.bounds, from: fr))"
                    // Walk up: the first ancestor whose top edge differs from its parent's is the culprit.
                    var v: UIView? = fr.superview
                    var chain: [String] = []
                    while let x = v, x !== fw {
                        let f = fw.convert(x.bounds, from: x)
                        let sa = x.safeAreaInsets
                        chain.append("\(type(of: x)) y=\(Int(f.minY)) h=\(Int(f.height)) sa=\(Int(sa.top))/\(Int(sa.bottom))")
                        v = x.superview
                    }
                    line += "\n  chain: " + chain.joined(separator: "\n  < ")
                }
                if #available(iOS 27.1, *) {
                    let div = root.reservedRegions(kind: .division, options: .includeInactive).map { "\($0.frame) active=\($0.isActive)" }
                    line += " division=\(div)"
                }
                HingeMonitor.shared.log(line)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    private func tabContent<V: View>(_ v: V, _ tab: AppModel.Tab) -> some View {
        let on = model.tab == tab
        // The keyboard safe-area region reaches descendants even though the padded root ignores it;
        // each tab's content must ignore it too, or SwiftUI shrinks the tab by the keyboard again.
        return v.ignoresSafeArea(.keyboard, edges: .bottom)
            .opacity(on ? 1 : 0).allowsHitTesting(on).accessibilityHidden(!on).zIndex(on ? 1 : 0)
    }
    @StateObject private var keyboardInset = KeyboardInset()
    var body: some View {
        // The system tab bar is never shown: iOS 26 hides it under the keyboard and floats it as a
        // big pill otherwise. We draw our own slim one above the keyboard.
        // Not a TabView: its tab controller adapts to the fold of a half-open iPhone Duo on its own
        // (pushing the content down by the keyboard's gap over the hinge) on top of our padding. All
        // four tabs stay alive, stacked; only the selected one is visible and tappable.
        VStack(spacing: 0) {
            ZStack {
                tabContent(TerminalTabView(), .terminal)
                tabContent(EditorScreen(), .editor)
                tabContent(HostsView(), .hosts)
                tabContent(SettingsView(), .settings)
            }
            AppTabBar(selection: $model.tab)
        }
        .tint(.cyan)
        // Pad for the keyboard ourselves, then ignore SwiftUI's own keyboard avoidance *outside*
        // the padding; the other way round both subtract the keyboard height.
        .padding(.bottom, keyboardInset.bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onOpenURL { url in model.handleIncoming(url) }
        .onChange(of: model.tab) { _, tab in
            // The editor's web view keeps keyboard focus across tab switches; hand it to the terminal.
            if tab == .terminal { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { model.activeSession?.focusTerminal?() } }
            else { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
        .onChange(of: model.activeSession) { _, s in if model.tab == .terminal { s?.focusTerminal?() } }
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
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.activeSession?.focusTerminal?() } }
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

/// The app's tabs as a slim row, drawn above the keyboard instead of the system tab bar.
struct AppTabBar: View {
    struct Item { let tab: AppModel.Tab; let title: String; let image: String }
    static let items: [Item] = [
        Item(tab: .terminal, title: "Terminal", image: "terminal"),
        Item(tab: .editor, title: "Editor", image: "chevron.left.forwardslash.chevron.right"),
        Item(tab: .hosts, title: "SSH", image: "network"),
        Item(tab: .settings, title: "Settings", image: "gearshape"),
    ]
    @Binding var selection: AppModel.Tab
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.items, id: \.tab) { item in
                Button { selection = item.tab } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.image).font(.system(size: 15, weight: .medium))
                        Text(item.title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(selection == item.tab ? Color.cyan : Color(white: 0.6))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(white: 0.07))
        .overlay(alignment: .top) { Rectangle().fill(Color(white: 0.2)).frame(height: 0.5) }
    }
}
