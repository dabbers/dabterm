import Foundation

private func inputText(_ ctx: CommandContext, _ files: [String]) throws -> String {
    if files.isEmpty { return ctx.stdin ?? "" }
    var out = ""
    for f in files {
        guard let d = FileManager.default.contents(atPath: ctx.path(f).path) else { throw CommandError("\(f): No such file or directory") }
        out += String(decoding: d, as: UTF8.self)
    }
    return out
}
private func lines(_ s: String) -> [String] {
    var l = s.components(separatedBy: "\n")
    if l.last == "" { l.removeLast() }
    return l
}

struct EchoCommand: Command {
    let name = "echo"; let usage = "echo [-n] [-e] text..."; let summary = "print text"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var args = ctx.args; var nl = true; var esc = false
        while let f = args.first, f == "-n" || f == "-e" || f == "-ne" || f == "-en" { if f.contains("n") { nl = false }; if f.contains("e") { esc = true }; args.removeFirst() }
        var s = args.joined(separator: " ")
        if esc { s = s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\e", with: "\u{1b}").replacingOccurrences(of: "\\033", with: "\u{1b}") }
        ctx.out.write(s + (nl ? "\n" : ""))
        return 0
    }
}

struct GrepCommand: Command {
    let name = "grep"; let usage = "grep [-inrvcEF] [-A n] [-B n] [-C n] pattern [file...]"; let summary = "search text with regex"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse(flagsWithValues: ["A", "B", "C"])
        let after = Int(flags["A"] ?? flags["C"] ?? "0") ?? 0, before = Int(flags["B"] ?? flags["C"] ?? "0") ?? 0
        guard let pattern = pos.first else { throw CommandError("usage: \(usage)") }
        var opts: NSRegularExpression.Options = []
        if flags["i"] != nil { opts.insert(.caseInsensitive) }
        let pat = flags["F"] != nil ? NSRegularExpression.escapedPattern(for: pattern) : pattern
        let re = try NSRegularExpression(pattern: pat, options: opts)
        let invert = flags["v"] != nil, numbers = flags["n"] != nil, countOnly = flags["c"] != nil, recursive = flags["r"] != nil || flags["R"] != nil
        var files = Array(pos.dropFirst())
        if recursive {
            let roots = files.isEmpty ? ["."] : files
            files = []
            for r in roots {
                let u = ctx.path(r)
                if Workspace.isDirectory(u) {
                    if let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for case let f as URL in en where !Workspace.isDirectory(f) && !f.path.contains("/node_modules/") { files.append(r == "." ? String(f.path.dropFirst(u.path.count + 1)) : r + f.path.dropFirst(u.path.count)) }
                    }
                } else { files.append(r) }
            }
        }
        let showName = files.count > 1
        var any = false
        if files.isEmpty {
            let r = scan(ctx.stdin ?? "", re: re, invert: invert, numbers: numbers, countOnly: countOnly, name: nil, ctx: ctx, after: after, before: before); any = any || r
        }
        for f in files {
            if Task.isCancelled { return 130 }
            guard let d = FileManager.default.contents(atPath: ctx.path(f).path), let text = String(data: d, encoding: .utf8) else { continue }
            let r = scan(text, re: re, invert: invert, numbers: numbers, countOnly: countOnly, name: showName ? f : nil, ctx: ctx, after: after, before: before); any = any || r
        }
        return any ? 0 : 1
    }
    private func scan(_ text: String, re: NSRegularExpression, invert: Bool, numbers: Bool, countOnly: Bool, name: String?, ctx: CommandContext, after: Int = 0, before: Int = 0) -> Bool {
        var count = 0
        let all = lines(text)
        var printed = Set<Int>()
        var lastPrinted = -1
        func emitContext(_ idx: Int) {
            guard !printed.contains(idx), idx >= 0, idx < all.count else { return }
            if lastPrinted >= 0 && idx > lastPrinted + 1 && (after > 0 || before > 0) { ctx.print("--") }
            printed.insert(idx); lastPrinted = idx
            ctx.print((name.map { "\u{1b}[35m\($0)\u{1b}[36m-\u{1b}[0m" } ?? "") + (numbers ? "\u{1b}[32m\(idx + 1)\u{1b}[36m-\u{1b}[0m" : "") + all[idx])
        }
        for (i, line) in all.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            let matches = re.matches(in: line, range: range)
            let hit = !matches.isEmpty
            if hit != invert {
                count += 1
                if countOnly { continue }
                if before > 0 { for j in max(0, i - before)..<i { emitContext(j) } }
                if lastPrinted >= 0 && i > lastPrinted + 1 && (after > 0 || before > 0) { ctx.print("--") }
                printed.insert(i); lastPrinted = i
                var shown = line
                if !invert {
                    var result = ""; var last = line.startIndex
                    for m in matches { guard let r = Range(m.range, in: line) else { continue }; result += line[last..<r.lowerBound]; result += "\u{1b}[1;31m" + line[r] + "\u{1b}[0m"; last = r.upperBound }
                    result += line[last...]; shown = result
                }
                let prefix = (name.map { "\u{1b}[35m\($0)\u{1b}[36m:\u{1b}[0m" } ?? "") + (numbers ? "\u{1b}[32m\(i + 1)\u{1b}[36m:\u{1b}[0m" : "")
                ctx.print(prefix + shown)
                if after > 0 { for j in (i + 1)...min(all.count - 1, i + after) where j < all.count { emitContext(j) } }
            }
        }
        if countOnly { ctx.print((name.map { "\($0):" } ?? "") + "\(count)") }
        return count > 0
    }
}

struct HeadCommand: Command {
    let name = "head"; let usage = "head [-n N] [file...]"; let summary = "first lines"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var (flags, pos) = ctx.parse(flagsWithValues: ["n", "c"])
        if let i = pos.firstIndex(where: { $0.hasPrefix("-") && Int($0.dropFirst()) != nil }) { flags["n"] = String(pos[i].dropFirst()); pos.remove(at: i) }
        let text = try inputText(ctx, pos)
        if let c = Int(flags["c"] ?? "") { ctx.out.write(String(text.prefix(c))); return 0 }
        let n = Int(flags["n"] ?? "10") ?? 10
        for l in lines(text).prefix(n) { ctx.print(l) }
        return 0
    }
}

struct TailCommand: Command {
    let name = "tail"; let usage = "tail [-n N] [file...]"; let summary = "last lines"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var (flags, pos) = ctx.parse(flagsWithValues: ["n"])
        if let i = pos.firstIndex(where: { $0.hasPrefix("-") && Int($0.dropFirst()) != nil }) { flags["n"] = String(pos[i].dropFirst()); pos.remove(at: i) }
        let n = Int(flags["n"] ?? "10") ?? 10
        for l in lines(try inputText(ctx, pos)).suffix(n) { ctx.print(l) }
        return 0
    }
}

struct WcCommand: Command {
    let name = "wc"; let usage = "wc [-lwc] [file...]"; let summary = "count lines, words, bytes"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        let text = try inputText(ctx, pos)
        let l = lines(text).count, w = text.split(whereSeparator: { $0.isWhitespace }).count, c = text.utf8.count
        var parts: [String] = []
        if flags.isEmpty || flags["l"] != nil { parts.append(String(l)) }
        if flags.isEmpty || flags["w"] != nil { parts.append(String(w)) }
        if flags.isEmpty || flags["c"] != nil { parts.append(String(c)) }
        ctx.print(parts.map { $0.padding(toLength: 8, withPad: " ", startingAt: 0) }.joined() + (pos.first ?? ""))
        return 0
    }
}

struct SortCommand: Command {
    let name = "sort"; let usage = "sort [-rnu] [file...]"; let summary = "sort lines"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        var l = lines(try inputText(ctx, pos))
        if flags["n"] != nil { l.sort { (Double($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0) < (Double($1.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0) } }
        else { l.sort() }
        if flags["r"] != nil { l.reverse() }
        if flags["u"] != nil { var seen = Set<String>(); l = l.filter { seen.insert($0).inserted } }
        for x in l { ctx.print(x) }
        return 0
    }
}

struct UniqCommand: Command {
    let name = "uniq"; let usage = "uniq [-c] [file]"; let summary = "collapse repeated lines"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        var prev: String? = nil; var n = 0
        func flush() { if let p = prev { ctx.print(flags["c"] != nil ? String(format: "%7d %@", n, p) : p) } }
        for l in lines(try inputText(ctx, pos)) { if l == prev { n += 1 } else { flush(); prev = l; n = 1 } }
        flush()
        return 0
    }
}

struct CutCommand: Command {
    let name = "cut"; let usage = "cut -d delim -f N[,M] | -c N-M [file]"; let summary = "cut fields or characters"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse(flagsWithValues: ["d", "f", "c"])
        let text = try inputText(ctx, pos)
        for l in lines(text) {
            if let f = flags["f"] {
                let delim = flags["d"] ?? "\t"
                let parts = l.components(separatedBy: delim)
                let idx = f.split(separator: ",").compactMap { Int($0) }.map { $0 - 1 }
                ctx.print(idx.compactMap { $0 < parts.count ? parts[$0] : nil }.joined(separator: delim))
            } else if let c = flags["c"] {
                let r = c.split(separator: "-").compactMap { Int($0) }
                let chars = Array(l)
                let lo = max(0, (r.first ?? 1) - 1), hi = min(chars.count, r.count > 1 ? r[1] : (c.hasSuffix("-") ? chars.count : lo + 1))
                ctx.print(lo < hi ? String(chars[lo..<hi]) : "")
            } else { throw CommandError("usage: \(usage)") }
        }
        return 0
    }
}

struct TrCommand: Command {
    let name = "tr"; let usage = "tr [-d] set1 [set2]"; let summary = "translate or delete characters"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        func expand(_ s: String) -> [Character] {
            switch s { case "a-z": return Array("abcdefghijklmnopqrstuvwxyz"); case "A-Z": return Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"); case "0-9": return Array("0123456789"); case "[:space:]": return [" ", "\t", "\n"]; default: return Array(s.replacingOccurrences(of: "\\n", with: "\n")) }
        }
        guard let s1 = pos.first else { throw CommandError("usage: \(usage)") }
        let set1 = expand(s1); let text = ctx.stdin ?? ""
        if flags["d"] != nil { ctx.out.write(String(text.filter { !set1.contains($0) })); return 0 }
        guard pos.count > 1 else { throw CommandError("usage: \(usage)") }
        let set2 = expand(pos[1])
        var map: [Character: Character] = [:]
        for (i, c) in set1.enumerated() { map[c] = set2[min(i, set2.count - 1)] }
        ctx.out.write(String(text.map { map[$0] ?? $0 }))
        return 0
    }
}

struct SedCommand: Command {
    let name = "sed"; let usage = "sed [-i] 's/pattern/replacement/[gi]' [file...]"; let summary = "stream editor (substitute)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        guard let expr = pos.first, expr.hasPrefix("s"), expr.count > 3 else { throw CommandError("only s/pat/rep/[gi] is supported") }
        let delim = expr[expr.index(after: expr.startIndex)]
        let parts = expr.dropFirst(2).split(separator: delim, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw CommandError("bad substitution") }
        let pat = String(parts[0]), rep = String(parts[1]).replacingOccurrences(of: "\\1", with: "$1").replacingOccurrences(of: "\\2", with: "$2").replacingOccurrences(of: "&", with: "$0")
        let mods = parts.count > 2 ? String(parts[2]) : ""
        let re = try NSRegularExpression(pattern: pat, options: mods.contains("i") ? [.caseInsensitive] : [])
        let files = Array(pos.dropFirst())
        func apply(_ text: String) -> String {
            lines(text).map { line in
                let range = NSRange(line.startIndex..., in: line)
                if mods.contains("g") { return re.stringByReplacingMatches(in: line, range: range, withTemplate: rep) }
                guard let m = re.firstMatch(in: line, range: range) else { return line }
                return (line as NSString).replacingCharacters(in: m.range, with: re.replacementString(for: m, in: line, offset: 0, template: rep))
            }.joined(separator: "\n") + "\n"
        }
        if files.isEmpty { ctx.out.write(apply(ctx.stdin ?? "")); return 0 }
        for f in files {
            let url = ctx.path(f)
            let text = try String(contentsOf: url, encoding: .utf8)
            let out = apply(text)
            if flags["i"] != nil { try out.write(to: url, atomically: true, encoding: .utf8) } else { ctx.out.write(out) }
        }
        return 0
    }
}

struct DiffCommand: Command {
    let name = "diff"; let usage = "diff a b"; let summary = "line diff of two files"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard ctx.args.count == 2 else { throw CommandError("usage: \(usage)") }
        let a = lines(try String(contentsOf: ctx.path(ctx.args[0]), encoding: .utf8)), b = lines(try String(contentsOf: ctx.path(ctx.args[1]), encoding: .utf8))
        let d = b.difference(from: a)
        if d.isEmpty { return 0 }
        ctx.print("--- \(ctx.args[0])\n+++ \(ctx.args[1])")
        var out: [(Int, String)] = []
        for c in d {
            switch c {
            case .remove(let o, let e, _): out.append((o, "\u{1b}[31m-\(e)\u{1b}[0m"))
            case .insert(let o, let e, _): out.append((o, "\u{1b}[32m+\(e)\u{1b}[0m"))
            }
        }
        for (_, l) in out.sorted(by: { $0.0 < $1.0 }) { ctx.print(l) }
        return 1
    }
}

struct Base64Command: Command {
    let name = "base64"; let usage = "base64 [-d] [file]"; let summary = "base64 encode/decode"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        let data: Data = pos.isEmpty ? Data((ctx.stdin ?? "").utf8) : (FileManager.default.contents(atPath: ctx.path(pos[0]).path) ?? Data())
        if flags["d"] != nil || flags["D"] != nil {
            guard let d = Data(base64Encoded: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CommandError("invalid input") }
            ctx.out.write(String(decoding: d, as: UTF8.self) + "\n")
        } else { ctx.print(data.base64EncodedString()) }
        return 0
    }
}

struct XxdCommand: Command {
    let name = "xxd"; let usage = "xxd [file]"; let summary = "hex dump"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let data: Data = ctx.args.isEmpty ? Data((ctx.stdin ?? "").utf8) : (FileManager.default.contents(atPath: ctx.path(ctx.args[0]).path) ?? Data())
        var off = 0
        let bytes = [UInt8](data)
        while off < bytes.count {
            let chunk = bytes[off..<min(off + 16, bytes.count)]
            var hex = ""
            for (i, b) in chunk.enumerated() { hex += String(format: "%02x", b); if i % 2 == 1 { hex += " " } }
            let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            ctx.print(String(format: "%08x: %@ %@", off, hex.padding(toLength: 40, withPad: " ", startingAt: 0), ascii))
            off += 16
        }
        return 0
    }
}

struct JqCommand: Command {
    let name = "jq"; let usage = "jq [.path.to[0].key] [file]"; let summary = "pretty-print / query JSON"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var args = ctx.args
        var filter = "."
        if let f = args.first, f.hasPrefix(".") { filter = f; args.removeFirst() }
        let text = try inputText(ctx, args)
        guard let data = text.data(using: .utf8), var obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw CommandError("invalid JSON") }
        let comps = filter.split(whereSeparator: { $0 == "." || $0 == "[" }).map { $0.replacingOccurrences(of: "]", with: "") }
        for c in comps where !c.isEmpty {
            if let i = Int(c), let arr = obj as? [Any] { guard i < arr.count else { throw CommandError("index out of range") }; obj = arr[i] }
            else if let dict = obj as? [String: Any] { obj = dict[c] ?? NSNull() }
            else { throw CommandError("cannot index \(type(of: obj)) with \(c)") }
        }
        if let s = obj as? String { ctx.print(s); return 0 }
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        ctx.print(String(decoding: out, as: UTF8.self))
        return 0
    }
}

struct TeeCommand: Command {
    let name = "tee"; let usage = "tee [-a] file"; let summary = "copy stdin to file and stdout"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        let text = ctx.stdin ?? ""
        for p in pos {
            let url = ctx.path(p)
            if flags["a"] != nil, let ex = try? String(contentsOf: url, encoding: .utf8) { try (ex + text).write(to: url, atomically: true, encoding: .utf8) }
            else { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        ctx.out.write(text)
        return 0
    }
}

struct SeqCommand: Command {
    let name = "seq"; let usage = "seq [first] last"; let summary = "print a sequence of numbers"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let n = ctx.args.compactMap { Int($0) }
        guard let last = n.last else { throw CommandError("usage: \(usage)") }
        let first = n.count > 1 ? n[0] : 1
        for i in stride(from: first, through: last, by: first <= last ? 1 : -1) { ctx.print(String(i)) }
        return 0
    }
}

struct YesCommand: Command {
    let name = "yes"; let usage = "yes [text]"; let summary = "repeat text (Ctrl-C to stop)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let s = ctx.args.isEmpty ? "y" : ctx.args.joined(separator: " ")
        for _ in 0..<2000 { if Task.isCancelled { return 130 }; ctx.print(s); if ctx.out is TerminalSink { try await Task.sleep(nanoseconds: 2_000_000) } }
        return 0
    }
}

struct PrintfCommand: Command {
    let name = "printf"; let usage = "printf format [args...]"; let summary = "formatted output (%s %d %x %f, \\n \\t)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard let fmtRaw = ctx.args.first else { throw CommandError("usage: \(usage)") }
        let fmt = fmtRaw.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\\\", with: "\\")
        var args = Array(ctx.args.dropFirst())
        var out = ""
        var i = fmt.startIndex
        while i < fmt.endIndex {
            let c = fmt[i]
            if c == "%", fmt.index(after: i) < fmt.endIndex {
                var j = fmt.index(after: i)
                var spec = "%"
                while j < fmt.endIndex, "-+ 0123456789.".contains(fmt[j]) { spec.append(fmt[j]); j = fmt.index(after: j) }
                guard j < fmt.endIndex else { out += spec; break }
                let conv = fmt[j]
                let arg = args.isEmpty ? "" : args.removeFirst()
                switch conv {
                case "%": out += "%"
                case "s": out += String(format: spec + "@", arg)
                case "d", "i": out += String(format: spec + "ld", Int(arg) ?? 0)
                case "x", "X", "o": out += String(format: spec + "l" + String(conv), Int(arg) ?? 0)
                case "f", "e", "g": out += String(format: spec + String(conv), Double(arg) ?? 0)
                case "c": out += String(arg.prefix(1))
                default: out += spec + String(conv)
                }
                i = fmt.index(after: j)
            } else { out.append(c); i = fmt.index(after: i) }
        }
        ctx.out.write(out)
        return 0
    }
}
