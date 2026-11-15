import Foundation
import WasmKit
import WasmKitWASI
import WASI

/// `wasm`: run WebAssembly/WASI modules with WasmKit (a pure-Swift interpreter, so it is allowed
/// on the App Store). Any `.wasm` file in ~/bin or the current folder also runs by name, and packs
/// can declare commands with `"kind": "wasm"`. Modules get stdin/stdout/stderr wired to the shell,
/// `~` pre-opened as `/` and the current directory as `.`.
struct WasmCommand: Command {
    let name = "wasm"; let usage = "wasm [--dir host:guest] file.wasm [args...]  |  wasm info file.wasm"
    let summary = "run a WASI WebAssembly module (WasmKit)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var args = ctx.args
        var extraPreopens: [WASIBridgeToHost.Preopen] = []
        while args.first == "--dir", args.count > 1 {
            let spec = args[1]; args.removeFirst(2)
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            extraPreopens.append(.init(guestPath: parts.count > 1 ? parts[1] : parts[0], hostPath: ctx.path(parts[0]).path))
        }
        if args.first == "info", args.count > 1 {
            let module = try WasmKit.parseWasm(bytes: [UInt8](try Data(contentsOf: ctx.path(args[1]))))
            ctx.print("exports: " + module.exports.map { "\($0.name)" }.joined(separator: " "))
            ctx.print("imports: " + module.imports.map { "\($0.module).\($0.name)" }.joined(separator: " "))
            return 0
        }
        guard let file = args.first else { throw CommandError("usage: \(usage)") }
        return try await WasmRunner.run(file: ctx.path(file), args: Array(args.dropFirst()), preopens: extraPreopens, ctx: ctx)
    }
}

enum WasmRunner {
    static func run(file: URL, args: [String], preopens extra: [WASIBridgeToHost.Preopen], ctx: CommandContext) async throws -> Int32 {
        guard FileManager.default.fileExists(atPath: file.path) else { throw CommandError("\(Workspace.display(file)): no such file") }
        let module = try WasmKit.parseWasm(bytes: [UInt8](try Data(contentsOf: file)))
        // stdout/stderr pipes -> terminal; stdin pipe <- piped text (or empty)
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0], inp: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&err) == 0, pipe(&inp) == 0 else { throw CommandError("pipe failed") }
        let pump = PipePump(fds: [(out[0], ctx.out), (err[0], ctx.err)])
        pump.start()
        if let s = ctx.stdin { _ = s.withCString { write(inp[1], $0, strlen($0)) } }
        close(inp[1])
        let argv = [file.lastPathComponent] + args
        let env = ctx.env.filter { $0.key.first?.isUppercase ?? false }
        let preopens = [WASIBridgeToHost.Preopen(guestPath: "/", hostPath: Workspace.root.path),
                        WASIBridgeToHost.Preopen(guestPath: ".", hostPath: ctx.cwd.path)] + extra
        let code: Int32 = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { close(out[1]); close(err[1]); close(inp[0]) }
                do {
                    let wasi = try WASIBridgeToHost(args: argv, environment: env,
                                                     fileSystem: .host().withStdio(stdin: inp[0], stdout: out[1], stderr: err[1]).withPreopens(preopens))
                    let engine = Engine()
                    let store = Store(engine: engine)
                    let result: UInt32 = try wasi.runAndClose { wasi in
                        var imports = Imports()
                        wasi.link(to: &imports, store: store)
                        let instance = try module.instantiate(store: store, imports: imports)
                        return try wasi.start(instance)
                    }
                    cont.resume(returning: Int32(truncatingIfNeeded: result))
                } catch let e as WASIExitCode {
                    cont.resume(returning: Int32(truncatingIfNeeded: e.code))
                } catch {
                    cont.resume(throwing: CommandError("wasm: \(error)"))
                }
            }
        }
        pump.finish()
        return code
    }
}

/// Forwards bytes from file descriptors to output sinks on a background thread.
final class PipePump {
    private let fds: [(Int32, OutputSink)]
    private let group = DispatchGroup()
    init(fds: [(Int32, OutputSink)]) { self.fds = fds }
    func start() {
        for (fd, sink) in fds {
            group.enter()
            Thread.detachNewThread { [group] in
                var buf = [UInt8](repeating: 0, count: 8192)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { break }
                    sink.write(String(decoding: buf[0..<n], as: UTF8.self))
                }
                close(fd)
                group.leave()
            }
        }
    }
    func finish() { _ = group.wait(timeout: .now() + 5) }
}
