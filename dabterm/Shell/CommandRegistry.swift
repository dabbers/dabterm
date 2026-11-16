import Foundation
#if canImport(Yaegi)
import Yaegi
#endif

final class CommandRegistry {
    static let shared = CommandRegistry()
    private var commands: [String: Command] = [:]
    /// Commands contributed by tool packs (see ToolPackManager); refreshed by `pack reload`.
    var packCommands: [String: Command] { ToolPackManager.shared.commands }
    var names: [String] { Array(Set(commands.keys).union(packCommands.keys)).sorted() }
    var all: [Command] { names.compactMap { command(named: $0) } }
    func isBuiltin(_ name: String) -> Bool { commands[name] != nil }

    private init() {
        let list: [Command] = [
            // files
            LsCommand(), CdCommand(), PwdCommand(), CatCommand(), MkdirCommand(), RmCommand(), MvCommand(), CpCommand(),
            TouchCommand(), FindCommand(), DuCommand(), StatCommand(), TreeCommand(), FileCommand(),
            // text
            EchoCommand(), PrintfCommand(), GrepCommand(), HeadCommand(), TailCommand(), WcCommand(), SortCommand(), UniqCommand(),
            CutCommand(), TrCommand(), SedCommand(), DiffCommand(), Base64Command(), XxdCommand(), JqCommand(),
            // shell
            HelpCommand(), ClearCommand(), HistoryCommand(), EnvCommand(), ExportCommand(), UnsetCommand(), WhichCommand(),
            DateCommand(), UnameCommand(), SleepCommand(), TrueCommand(), FalseCommand(), ExitCommand(), ShCommand(),
            EditCommand(), OpenCommand(), JSCommand(), WasmCommand(), PythonCommand(), GoCommand(), ChshCommand(), XargsCommand(), TimeCommand(), WatchCommand(), LessCommand(), PatchCommand(), SqliteCommand(), PipCommand(), AliasCommand(), SeqCommand(), YesCommand(), TeeCommand(), PrintenvCommand(),
            // network
            PingCommand(), TracerouteCommand(), DigCommand(), HostCommand(), CurlCommand(), WgetCommand(), NcCommand(),
            IfconfigCommand(), WhoisCommand(), PortscanCommand(), HttpCommand(),
            // crypto
            OpenSSLCommand(), ShasumCommand(), Md5Command(), UUIDCommand(),
            // ssh
            SSHCommand(), SSHKeygenCommand(), ScpCommand(), SSHCopyIdCommand(),
            // git
            GitCommand(), GhCommand(), PackCLICommand(),
        ]
        for c in list { commands[c.name] = c }
        #if canImport(Yaegi)
        // Tools from the Go framework; its jq (the full language) replaces the path-only one.
        for c in GoTools.all { commands[c.name] = c }
        commands["gunzip"] = AliasedCommand(name: "gunzip", target: "gzip", prefix: ["-d"])
        #endif
        commands["ll"] = AliasedCommand(name: "ll", target: "ls", prefix: ["-la"])
        commands["more"] = AliasedCommand(name: "more", target: "less", prefix: [])
        commands["la"] = AliasedCommand(name: "la", target: "ls", prefix: ["-a"])
        commands["nslookup"] = AliasedCommand(name: "nslookup", target: "dig", prefix: [])
        commands["tracert"] = AliasedCommand(name: "tracert", target: "traceroute", prefix: [])
        commands["sha256sum"] = AliasedCommand(name: "sha256sum", target: "shasum", prefix: ["-a", "256"])
        commands["vim"] = AliasedCommand(name: "vim", target: "edit", prefix: [])
        commands["vi"] = AliasedCommand(name: "vi", target: "edit", prefix: [])
        commands["nano"] = AliasedCommand(name: "nano", target: "edit", prefix: [])
        commands["code"] = AliasedCommand(name: "code", target: "edit", prefix: [])
        commands["node"] = AliasedCommand(name: "node", target: "js", prefix: [])
        commands["python3"] = AliasedCommand(name: "python3", target: "python", prefix: [])
        commands["py"] = AliasedCommand(name: "py", target: "python", prefix: [])
    }

    func command(named name: String) -> Command? { commands[name] ?? packCommands[name] }
    func register(_ c: Command) { commands[c.name] = c }
}

struct AliasedCommand: Command {
    let name: String
    let target: String
    let prefix: [String]
    var usage: String { "\(name) → \(target) \(prefix.joined(separator: " "))" }
    var summary: String { "alias for \(target) \(prefix.joined(separator: " "))" }
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard let t = CommandRegistry.shared.command(named: target) else { throw CommandError("alias target missing") }
        return try await t.run(await ctx.derived(name: target, args: prefix + ctx.args))
    }
}
