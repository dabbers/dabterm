import Foundation
import CryptoKit
import DabCrypto

/// `openssl` command: adapts the shell context to the DabCrypto engine (libcrypto subset).
struct OpenSSLCommand: Command {
    let name = "openssl"
    let usage = OpenSSLEngine.usage
    let summary = "certificates, keys, hashes (libcrypto subset)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        do { return try await OpenSSLEngine().run(OpenSSLBridge(ctx)) }
        catch let e as OpenSSLError { throw CommandError(e.message) }
    }
}

final class OpenSSLBridge: OpenSSLIO {
    let ctx: CommandContext
    init(_ ctx: CommandContext) { self.ctx = ctx }
    var args: [String] { Array(ctx.args.dropFirst(0)) }
    var stdin: String? { ctx.stdin }
    func path(_ s: String) -> URL { ctx.path(s) }
    func write(_ s: String) { ctx.out.write(s) }
    func print(_ s: String) { ctx.print(s) }
    func printErr(_ s: String) { ctx.printErr(s) }
}

struct ShasumCommand: Command {
    let name = "shasum"; let usage = "shasum [-a 1|256|512] [file...]"; let summary = "SHA checksums"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse(flagsWithValues: ["a"])
        let alg = flags["a"] ?? "1"
        let inputs: [(String, Data)] = pos.isEmpty ? [("-", Data((ctx.stdin ?? "").utf8))] : try pos.map { p in guard let d = FileManager.default.contents(atPath: ctx.path(p).path) else { throw CommandError("\(p): No such file") }; return (p, d) }
        for (n, d) in inputs {
            let hex: String
            switch alg {
            case "256": hex = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
            case "384": hex = SHA384.hash(data: d).map { String(format: "%02x", $0) }.joined()
            case "512": hex = SHA512.hash(data: d).map { String(format: "%02x", $0) }.joined()
            default: hex = Insecure.SHA1.hash(data: d).map { String(format: "%02x", $0) }.joined()
            }
            ctx.print("\(hex)  \(n)")
        }
        return 0
    }
}
struct Md5Command: Command {
    let name = "md5"; let usage = "md5 [file...]"; let summary = "MD5 checksums"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let inputs: [(String, Data)] = ctx.args.isEmpty ? [("-", Data((ctx.stdin ?? "").utf8))] : try ctx.args.map { p in guard let d = FileManager.default.contents(atPath: ctx.path(p).path) else { throw CommandError("\(p): No such file") }; return (p, d) }
        for (n, d) in inputs { ctx.print("MD5 (\(n)) = " + Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()) }
        return 0
    }
}
