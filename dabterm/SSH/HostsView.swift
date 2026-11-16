import SwiftUI

/// SSH tab: hosts from ~/ssh/config, one-tap connect, add/edit hosts, manage keys.
struct HostsView: View {
    @EnvironmentObject var app: AppModel
    @State private var config = SSHConfig.load()
    @State private var editing: SSHHostConfig? = nil
    @State private var showAdd = false
    @State private var keys: [URL] = []
    @State private var showKeygen = false
    @State private var keyName = "id_ed25519"
    @State private var keyComment = ""
    @State private var copied: String? = nil

    var body: some View {
        NavigationStack {
            List {
                Section("Hosts") {
                    if config.hosts.filter({ !$0.isPattern }).isEmpty { Text("No hosts yet. Tap + to add one, or edit ~/ssh/config in the editor.").foregroundStyle(.secondary).font(.footnote) }
                    ForEach(config.hosts.filter { !$0.isPattern }) { h in
                        Button { app.runInTerminal("ssh \(shellQuote(h.alias))") } label: {
                            HStack {
                                Image(systemName: "server.rack").foregroundStyle(.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.alias).font(.headline)
                                    Text("\(h.effectiveUser)@\(h.effectiveHost)\(h.effectivePort != 22 ? ":\(h.effectivePort)" : "")\(h.identityFile.map { "  ·  \($0.split(separator: "/").last ?? "")" } ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.primary)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { try? SSHConfig.remove(alias: h.alias); reload() } label: { Label("Delete", systemImage: "trash") }
                            Button { editing = h } label: { Label("Edit", systemImage: "pencil") }.tint(.orange)
                        }
                        .contextMenu {
                            Button { editing = h } label: { Label("Edit", systemImage: "pencil") }
                            Button { app.runInTerminal("ssh-copy-id \(shellQuote(h.alias))") } label: { Label("Install my key (ssh-copy-id)", systemImage: "key") }
                            Button { app.runInTerminal("ping -c 4 \(shellQuote(h.effectiveHost))") } label: { Label("Ping", systemImage: "dot.radiowaves.left.and.right") }
                            Button { app.runInTerminal("scp \(shellQuote(h.alias)):~/ ~/projects/") } label: { Label("scp from host…", systemImage: "arrow.down.doc") }
                        }
                    }
                }
                Section("Keys  (Keychain; public halves in ~/ssh)") {
                    ForEach(keys, id: \.self) { k in
                        let pub = (try? String(contentsOf: URL(fileURLWithPath: k.path + ".pub"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "key.fill").foregroundStyle(.pink)
                                Text(k.lastPathComponent).font(.system(.body, design: .monospaced))
                                Spacer()
                                if let pub {
                                    Button(copied == k.path ? "Copied" : "Copy public key") { UIPasteboard.general.string = pub; copied = k.path }
                                        .font(.caption).buttonStyle(.bordered)
                                }
                            }
                            if let pub { Text(SSHKeys.fingerprint(publicLine: pub)).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                        }
                        .swipeActions { Button(role: .destructive) { SSHKeyStore.delete(name: k.lastPathComponent); reload() } label: { Label("Delete", systemImage: "trash") } }
                    }
                    Button { showKeygen = true } label: { Label("Generate new ed25519 key", systemImage: "plus.circle") }
                    Text("Private keys are kept in the iOS Keychain: this device only, never in backups or the Files folder. Only the .pub is in ~/ssh. A private key dropped into Files → dabterm → ssh is moved into the Keychain the next time keys are used.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button { app.editorRequest = Workspace.sshConfig; app.editorFolder = Workspace.sshDir; app.tab = .editor } label: { Label("Edit ~/ssh/config", systemImage: "doc.text") }
                    Button { app.editorRequest = Workspace.knownHosts; app.editorFolder = Workspace.sshDir; app.tab = .editor } label: { Label("Edit known_hosts", systemImage: "doc.text") }
                }
            }
            .navigationTitle("SSH")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
            .refreshable { reload() }
            .onAppear(perform: reload)
            .sheet(isPresented: $showAdd) { HostEditor(host: SSHHostConfig(alias: ""), isNew: true) { reload() } }
            .sheet(item: $editing) { h in HostEditor(host: h, isNew: false) { reload() } }
            .alert("Generate key", isPresented: $showKeygen) {
                TextField("file name", text: $keyName)
                TextField("comment (optional)", text: $keyComment)
                Button("Generate") { app.runInTerminal("ssh-keygen -t ed25519 -f ~/ssh/\(keyName)\(keyComment.isEmpty ? "" : " -C \(shellQuote(keyComment))")") }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
    private func reload() {
        config = SSHConfig.load()
        keys = SSHKeyStore.names().map { Workspace.sshDir.appendingPathComponent($0) }
    }
}

struct HostEditor: View {
    @State var host: SSHHostConfig
    let isNew: Bool
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""
    @State private var keyFiles: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Alias (e.g. myserver)", text: $host.alias).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("HostName (IP or DNS)", text: Binding(get: { host.hostName ?? "" }, set: { host.hostName = $0.isEmpty ? nil : $0 })).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("User", text: Binding(get: { host.user ?? "" }, set: { host.user = $0.isEmpty ? nil : $0 })).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port (22)", text: $portText).keyboardType(.numberPad)
                }
                Section("Authentication") {
                    Picker("IdentityFile", selection: Binding(get: { host.identityFile ?? "" }, set: { host.identityFile = $0.isEmpty ? nil : $0 })) {
                        Text("Auto (try keys in ~/ssh, then password)").tag("")
                        ForEach(keyFiles, id: \.self) { Text($0).tag("~/ssh/\($0)") }
                    }
                    TextField("ProxyJump (optional)", text: Binding(get: { host.proxyJump ?? "" }, set: { host.proxyJump = $0.isEmpty ? nil : $0 })).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .navigationTitle(isNew ? "Add host" : host.alias).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { host.port = Int(portText); try? SSHConfig.upsert(host); onSave(); dismiss() }.disabled(host.alias.isEmpty) }
            }
            .onAppear {
                portText = host.port.map(String.init) ?? ""
                keyFiles = SSHKeyStore.names()
            }
        }
    }
}
