import Foundation

/// A shell: takes what the user typed (or a script) and runs it in a session. dsh, the built-in
/// shell, is always present and the default. Others register here: compiled-in extras such as the
/// bash-syntax shell that comes with the Go framework, or whatever a build adds. A shell that is
/// not available in this build (its framework missing) is listed but cannot be selected.
///
/// Contract for a shell: it owns parsing and control flow; the app's commands are its "programs",
/// run through `ShellSession.runSimple` (buffered) or `ShellSession.runDsh` (full terminal access).
protocol ShellProvider: AnyObject {
    /// Name used by `chsh` and shown in Settings.
    var name: String { get }
    var summary: String { get }
    /// False when the build lacks what the shell needs; dsh is used instead.
    var isAvailable: Bool { get }
    /// Runs one line as typed at the prompt. Returns the exit status.
    func execute(line: String, session: ShellSession) async -> Int32
    /// Runs a script file. The default runs it line by line through `execute`.
    func execute(script: String, name: String, args: [String], session: ShellSession) async -> Int32
}

extension ShellProvider {
    func execute(script: String, name: String, args: [String], session: ShellSession) async -> Int32 {
        await session.runDshScript(script, name: name, args: args)
    }
}

@MainActor
final class ShellRegistry {
    static let shared = ShellRegistry()
    static let defaultsKey = "shell"
    private(set) var providers: [ShellProvider] = []
    private init() {
        register(DshShell())
        #if canImport(Yaegi)
        register(BashShell())
        #endif
    }
    func register(_ p: ShellProvider) {
        providers.removeAll { $0.name == p.name }
        providers.append(p)
    }
    func provider(named name: String) -> ShellProvider? { providers.first { $0.name == name } }

    /// The user's choice (UserDefaults), falling back to dsh when it is missing or unavailable.
    var selectedName: String {
        get { UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "dsh" }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }
    var current: ShellProvider {
        if let p = provider(named: selectedName), p.isAvailable { return p }
        return providers[0]
    }
}

/// The built-in shell: pipelines, redirects, variables, aliases, scripts in ~/bin.
final class DshShell: ShellProvider {
    let name = "dsh"
    let summary = "dabterm's built-in shell (pipes, redirects, variables, scripts)"
    var isAvailable: Bool { true }
    func execute(line: String, session: ShellSession) async -> Int32 { await session.runDsh(line: line) }
}

/// `chsh`: list the shells in this build or switch to one. Takes effect for the next line typed.
struct ChshCommand: Command {
    let name = "chsh"; let usage = "chsh [shell]   (no argument: list shells)"
    let summary = "list or switch the shell"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let reg = await ShellRegistry.shared
        if let want = ctx.args.first {
            guard let p = await reg.provider(named: want) else { throw CommandError("no such shell: \(want)") }
            guard p.isAvailable else { throw CommandError("\(want) is not available in this build") }
            await MainActor.run { reg.selectedName = want }
            ctx.print("shell set to \(want)")
            return 0
        }
        let current = await reg.current.name
        for p in await reg.providers {
            let mark = p.name == current ? "*" : " "
            let avail = p.isAvailable ? "" : "   (not in this build)"
            ctx.print("\(mark) \(p.name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(p.summary)\(avail)")
        }
        return 0
    }
}
