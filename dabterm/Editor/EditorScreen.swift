import SwiftUI

/// Editor tab: file tree sidebar (iPad) or sheet (iPhone), tab strip, CodeMirror, status bar, git panel.
struct EditorScreen: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var editor = EditorController()
    @StateObject private var tree = FileTreeModel()
    @State private var showTree = false
    @State private var showGit = false
    @State private var showNewFile = false
    @State private var newName = ""
    @State private var gotoLine = ""
    @State private var showGoto = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            Group {
                if sizeClass == .regular {
                    HStack(spacing: 0) {
                        FileTreeView(model: tree, editor: editor).frame(width: 260).background(Color(white: 0.1))
                        Divider()
                        editorColumn
                    }
                } else { editorColumn }
            }
            .navigationTitle(editor.openFile?.lastPathComponent ?? Workspace.display(tree.root))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if sizeClass != .regular { Button { showTree = true } label: { Image(systemName: "sidebar.left") } }
                    Button { showGit = true } label: { Image(systemName: "arrow.triangle.branch") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button { editor.command("find") } label: { Label("Find / Replace", systemImage: "magnifyingglass") }
                        Button { showGoto = true } label: { Label("Go to line", systemImage: "arrow.right.to.line") }
                        Button { editor.command("selectAll") } label: { Label("Select all", systemImage: "selection.pin.in.out") }
                        Button { editor.command("undo") } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        Button { editor.command("redo") } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        Divider()
                        Button { showNewFile = true } label: { Label("New file", systemImage: "doc.badge.plus") }
                        if let f = editor.openFile {
                            Button { model.runInTerminal("cd \(shellQuote(f.deletingLastPathComponent().path))") } label: { Label("Terminal here", systemImage: "terminal") }
                            ShareLink(item: f) { Label("Share file", systemImage: "square.and.arrow.up") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button { editor.save() } label: { Image(systemName: editor.dirty ? "square.and.arrow.down.fill" : "square.and.arrow.down") }
                        .disabled(editor.openFile == nil)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .sheet(isPresented: $showTree) { NavigationStack { FileTreeView(model: tree, editor: editor).navigationTitle("Files").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showTree = false } } } }.presentationDetents([.large]) }
        .sheet(isPresented: $showGit) { GitPanel(root: tree.root).presentationDetents([.medium, .large]) }
        .alert("New file", isPresented: $showNewFile) {
            TextField("name.ext", text: $newName)
            Button("Create") { let u = tree.root.appendingPathComponent(newName); try? Data().write(to: u); tree.refresh(); editor.open(u); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Go to line", isPresented: $showGoto) {
            TextField("line", text: $gotoLine).keyboardType(.numberPad)
            Button("Go") { if let l = Int(gotoLine) { editor.webView.evaluateJavaScript("dabterm.goto(\(l))") }; gotoLine = "" }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            tree.root = model.editorFolder; tree.refresh()
            if let r = model.editorRequest { editor.open(r, line: model.editorLine); model.editorRequest = nil; model.editorLine = nil }
        }
        .onChange(of: model.editorFolder) { _, f in tree.root = f; tree.refresh() }
        .onChange(of: model.editorRequest) { _, r in if let r { editor.open(r, line: model.editorLine); model.editorRequest = nil; model.editorLine = nil; showTree = false } }
        .onChange(of: model.editorFontSize) { _, _ in editor.applySettings() }
        .onChange(of: model.editorWrap) { _, _ in editor.applySettings() }
        .onAppear { editor.onSaved = { _ in tree.refresh() } }
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            if !editor.tabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(editor.tabs, id: \.self) { t in
                            HStack(spacing: 6) {
                                Image(systemName: FileIcon.name(for: t)).font(.system(size: 11)).foregroundStyle(FileIcon.color(for: t))
                                Text(t.lastPathComponent).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                if editor.openFile == t && editor.dirty { Circle().fill(.white).frame(width: 6, height: 6) }
                                Button { editor.close(t) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain).opacity(0.6)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(editor.openFile == t ? Color(red: 0.157, green: 0.173, blue: 0.204) : Color(white: 0.1))
                            .foregroundStyle(editor.openFile == t ? .white : .gray)
                            .onTapGesture { editor.open(t) }
                        }
                    }
                }.background(Color(white: 0.08))
            }
            ZStack {
                EditorWebView(controller: editor)
                if editor.openFile == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text").font(.system(size: 40)).foregroundStyle(.gray)
                        Text("Open a file from the sidebar, or type `edit file` in the terminal.").foregroundStyle(.gray).multilineTextAlignment(.center)
                        Button("Browse files") { if sizeClass == .regular { } else { showTree = true } }.buttonStyle(.bordered)
                    }.padding()
                }
            }
            HStack {
                Text(editor.status).lineLimit(1)
                Spacer()
                if editor.openFile != nil { Text("Ln \(editor.cursor.line), Col \(editor.cursor.col)") }
                Text(editor.openFile?.pathExtension.uppercased() ?? "").foregroundStyle(.cyan)
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.gray)
            .padding(.horizontal, 10).padding(.vertical, 4).background(Color(white: 0.08))
        }
    }
}

func shellQuote(_ s: String) -> String { s.contains(where: { " '\"$&|;<>()`\\".contains($0) }) ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s }

enum FileIcon {
    static func name(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"; case "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "c", "h", "cpp", "sh": return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "plist": return "curlybraces"; case "md", "txt": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic": return "photo"; case "pem", "key", "crt", "pub": return "key"
        default: return "doc"
        }
    }
    static func color(for url: URL) -> Color {
        switch url.pathExtension.lowercased() {
        case "swift": return .orange; case "js", "jsx": return .yellow; case "ts", "tsx": return .blue; case "py": return .green; case "json": return .yellow
        case "md": return .cyan; case "sh": return .green; case "pem", "key", "crt", "pub": return .pink; default: return .gray
        }
    }
}

@MainActor
final class FileTreeModel: ObservableObject {
    @Published var root: URL = Workspace.home
    @Published var expanded: Set<URL> = []
    @Published var version = 0
    @Published var gitStatus: GitRepo.Status? = nil
    @Published var repoRoot: URL? = nil
    func refresh() {
        version += 1
        if let r = GitRepo.open(at: root) { repoRoot = r.root; gitStatus = r.status() } else { repoRoot = nil; gitStatus = nil }
    }
    func children(of url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") || $0.lastPathComponent == ".gitignore" }
            .sorted { a, b in
                let da = Workspace.isDirectory(a), db = Workspace.isDirectory(b)
                if da != db { return da }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
    }
    func badge(for url: URL) -> String? {
        guard let s = gitStatus, let r = repoRoot else { return nil }
        let rel = String(url.path.dropFirst(r.path.count + 1))
        if s.modified.contains(rel) { return "M" }
        if s.added.contains(rel) { return "U" }
        if Workspace.isDirectory(url), (s.modified + s.added).contains(where: { $0.hasPrefix(rel + "/") }) { return "•" }
        return nil
    }
}

struct FileTreeView: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var editor: EditorController
    @EnvironmentObject var app: AppModel
    @State private var renaming: URL? = nil
    @State private var renameText = ""
    @State private var newItemIn: URL? = nil
    @State private var newItemIsFolder = false
    @State private var newItemName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { if model.root != Workspace.home { app.editorFolder = model.root.deletingLastPathComponent() } } label: { Image(systemName: "chevron.up") }.disabled(model.root == Workspace.home)
                Text(Workspace.display(model.root)).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                Menu {
                    Button { newItemIn = model.root; newItemIsFolder = false } label: { Label("New file", systemImage: "doc.badge.plus") }
                    Button { newItemIn = model.root; newItemIsFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    Button { app.runInTerminal("cd \(shellQuote(model.root.path))") } label: { Label("Terminal here", systemImage: "terminal") }
                    Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "plus.circle") }
            }.padding(.horizontal, 10).padding(.vertical, 8).background(Color(white: 0.08))
            List {
                ForEach(model.children(of: model.root), id: \.self) { node(url: $0, depth: 0) }
            }
            .listStyle(.plain).environment(\.defaultMinListRowHeight, 28).id(model.version)
        }
        .alert(newItemIsFolder ? "New folder" : "New file", isPresented: Binding(get: { newItemIn != nil }, set: { if !$0 { newItemIn = nil } })) {
            TextField("name", text: $newItemName)
            Button("Create") {
                guard let dir = newItemIn, !newItemName.isEmpty else { return }
                let u = dir.appendingPathComponent(newItemName)
                if newItemIsFolder { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) } else { try? Data().write(to: u); editor.open(u) }
                model.expanded.insert(dir); model.refresh(); newItemName = ""
            }
            Button("Cancel", role: .cancel) { newItemName = "" }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("name", text: $renameText)
            Button("Rename") { if let r = renaming { let t = r.deletingLastPathComponent().appendingPathComponent(renameText); try? FileManager.default.moveItem(at: r, to: t); if editor.openFile == r { editor.tabs.removeAll { $0 == r }; editor.open(t) }; model.refresh() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private func node(url: URL, depth: Int) -> AnyView {
        let isDir = Workspace.isDirectory(url)
        let open = model.expanded.contains(url)
        AnyView(Group {
            HStack(spacing: 6) {
                if isDir { Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 12) } else { Spacer().frame(width: 12) }
                Image(systemName: isDir ? (open ? "folder.fill" : "folder") : FileIcon.name(for: url)).font(.system(size: 13)).foregroundStyle(isDir ? .cyan : FileIcon.color(for: url))
                Text(url.lastPathComponent).font(.system(size: 13, design: .monospaced)).lineLimit(1)
                Spacer()
                if let b = model.badge(for: url) { Text(b).font(.system(size: 10, weight: .bold)).foregroundStyle(b == "U" ? .green : .orange) }
            }
            .padding(.leading, CGFloat(depth) * 14)
            .listRowBackground(editor.openFile == url ? Color(white: 0.2) : Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .contentShape(Rectangle())
            .onTapGesture { if isDir { if open { model.expanded.remove(url) } else { model.expanded.insert(url) } } else { editor.open(url) } }
            .contextMenu {
                if isDir {
                    Button { newItemIn = url; newItemIsFolder = false } label: { Label("New file here", systemImage: "doc.badge.plus") }
                    Button { newItemIn = url; newItemIsFolder = true } label: { Label("New folder here", systemImage: "folder.badge.plus") }
                    Button { app.editorFolder = url } label: { Label("Open as workspace root", systemImage: "arrow.down.right.and.arrow.up.left") }
                    Button { app.runInTerminal("cd \(shellQuote(url.path))") } label: { Label("Terminal here", systemImage: "terminal") }
                }
                Button { renaming = url; renameText = url.lastPathComponent } label: { Label("Rename", systemImage: "pencil") }
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { try? FileManager.default.removeItem(at: url); editor.tabs.removeAll { $0 == url }; if editor.openFile == url { editor.close(url) }; model.refresh() } label: { Label("Delete", systemImage: "trash") }
            }
            if isDir && open { ForEach(model.children(of: url), id: \.self) { node(url: $0, depth: depth + 1) } }
        })
    }
}

/// Source-control panel: status, select files, commit message, commit+push, pull, clone.
struct GitPanel: View {
    let root: URL
    @EnvironmentObject var app: AppModel
    @State private var repo: GitRepo? = nil
    @State private var status: GitRepo.Status? = nil
    @State private var selected: Set<String> = []
    @State private var message = ""
    @State private var busy = false
    @State private var log: [String] = []
    @State private var cloneSpec = ""
    @State private var error: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let r = repo { repoView(r) } else { noRepoView }
            }
            .navigationTitle("Source Control").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear { reload() }
        .alert("Git", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    private func reload() {
        repo = GitRepo.open(at: root)
        status = repo?.status()
        if let s = status { selected = Set(s.modified + s.added + s.deleted) }
    }

    private var noRepoView: some View {
        Form {
            Section("This folder is not linked to GitHub") {
                TextField("owner/repo or GitHub URL", text: $cloneSpec).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Clone into \(Workspace.display(root))") {
                    dismiss(); app.runInTerminal("cd \(shellQuote(root.path)) && git clone \(shellQuote(cloneSpec))")
                }.disabled(cloneSpec.isEmpty)
                Button("Link this folder to an existing repo") {
                    dismiss(); app.runInTerminal("cd \(shellQuote(root.path)) && git init \(shellQuote(cloneSpec))")
                }.disabled(cloneSpec.isEmpty)
            }
            Section { Text("Tokens are stored in the Keychain. Sign in with `gh auth login` in the terminal or in Settings.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func repoView(_ r: GitRepo) -> some View {
        Form {
            Section {
                LabeledContent("Repository", value: "\(r.state.owner)/\(r.state.name)")
                LabeledContent("Branch", value: r.state.branch)
                LabeledContent("HEAD", value: String(r.state.head.prefix(10)))
            }
            if let s = status {
                Section(s.isClean ? "No changes" : "Changes (\(s.modified.count + s.added.count + s.deleted.count))") {
                    ForEach(changeRows(s)) { row in
                        Toggle(isOn: selectionBinding(row.path)) { ChangeRowLabel(kind: row.kind, path: row.path) }
                    }
                }
                if !s.isClean {
                    Section("Commit") {
                        TextField("Commit message", text: $message, axis: .vertical).lineLimit(2...5)
                        Button { commit(r) } label: { HStack { if busy { ProgressView().padding(.trailing, 4) }; Text("Commit & push \(selected.count) file\(selected.count == 1 ? "" : "s")") } }
                            .disabled(busy || message.isEmpty || selected.isEmpty)
                    }
                }
            }
            Section("Sync") {
                Button("Pull latest from GitHub") { pull(r) }.disabled(busy)
                Button("Open in terminal") { dismiss(); app.runInTerminal("cd \(shellQuote(r.root.path)) && git status") }
                Button("View on GitHub") { if let u = URL(string: "https://github.com/\(r.state.owner)/\(r.state.name)/tree/\(r.state.branch)") { UIApplication.shared.open(u) } }
            }
            if !log.isEmpty { Section("Log") { ForEach(log, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) } } }
        }
    }

    struct ChangeRow: Identifiable { let kind: String; let path: String; var id: String { path } }
    private func changeRows(_ s: GitRepo.Status) -> [ChangeRow] {
        let rows = s.modified.map { ChangeRow(kind: "M", path: $0) } + s.added.map { ChangeRow(kind: "U", path: $0) } + s.deleted.map { ChangeRow(kind: "D", path: $0) }
        return rows.sorted { $0.path < $1.path }
    }
    private func selectionBinding(_ path: String) -> Binding<Bool> {
        Binding(get: { selected.contains(path) }, set: { on in if on { selected.insert(path) } else { selected.remove(path) } })
    }

    private func commit(_ r: GitRepo) {
        busy = true; log = []
        Task {
            do {
                let client = GitHubClient(token: Keychain.get(Keychain.githubTokenKey))
                let sha = try await r.commitAndPush(message: message, paths: Array(selected), author: GitCommand().authorIdentity(), client: client) { s in Task { @MainActor in log.append(s) } }
                log.append("pushed \(sha.prefix(7)) to \(r.state.branch)")
                message = ""; reload()
            } catch { self.error = "\(error)" }
            busy = false
        }
    }
    private func pull(_ r: GitRepo) {
        busy = true; log = []
        Task {
            do {
                let client = GitHubClient(token: Keychain.get(Keychain.githubTokenKey))
                let (n, head) = try await r.pull(client: client, force: false) { s in Task { @MainActor in log.append(s) } }
                log.append(n == 0 ? "Already up to date" : "Updated \(n) files → \(head.prefix(7))"); reload()
            } catch { self.error = "\(error)" }
            busy = false
        }
    }
}

struct ChangeRowLabel: View {
    let kind: String; let path: String
    var color: Color { kind == "U" ? .green : (kind == "D" ? .red : .orange) }
    var body: some View {
        HStack {
            Text(kind).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(color).frame(width: 14)
            Text(path).font(.system(size: 13, design: .monospaced)).lineLimit(1)
        }
    }
}
