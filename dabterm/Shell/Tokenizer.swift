import Foundation

/// A parsed pipeline: `a | b > file`.
struct Pipeline {
    struct Stage { var argv: [String] }
    var stages: [Stage]
    var redirect: (path: String, append: Bool)?
    var background = false
}

enum Tokenizer {
    /// Splits a command line into pipelines separated by `;` or `&&` (treated the same in v1).
    static func parse(_ line: String, env: [String: String]) throws -> [Pipeline] {
        let tokens = try tokenize(line, env: env)
        var pipelines: [Pipeline] = []
        var current = Pipeline(stages: [Pipeline.Stage(argv: [])])
        var i = 0
        func finish() {
            if !current.stages.last!.argv.isEmpty || current.stages.count > 1 { pipelines.append(current) }
            current = Pipeline(stages: [Pipeline.Stage(argv: [])])
        }
        while i < tokens.count {
            let t = tokens[i]
            switch t {
            case .op(";"), .op("&&"): finish()
            case .op("|"): current.stages.append(Pipeline.Stage(argv: []))
            case .op(">"), .op(">>"):
                guard i + 1 < tokens.count, case .word(let path) = tokens[i+1] else { throw CommandError("syntax error near redirect") }
                current.redirect = (path, t == .op(">>")); i += 1
            case .op("&"): current.background = true
            case .word(let w): current.stages[current.stages.count - 1].argv.append(w)
            default: break
            }
            i += 1
        }
        finish()
        return pipelines
    }

    enum Token: Equatable { case word(String); case op(String) }

    static func tokenize(_ line: String, env: [String: String]) throws -> [Token] {
        var tokens: [Token] = []
        var cur = ""
        var hasWord = false
        var quoted = false
        var noGlob = Set<Int>()
        var chars = Array(line)
        var i = 0
        func flush() { if hasWord { if quoted { noGlob.insert(tokens.count) }; tokens.append(.word(cur)); cur = ""; hasWord = false; quoted = false } }
        func expandVar() -> String {
            // $VAR or ${VAR}
            var name = ""
            if i + 1 < chars.count, chars[i+1] == "{" {
                i += 2
                while i < chars.count, chars[i] != "}" { name.append(chars[i]); i += 1 }
            } else {
                i += 1
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "?" { name.append(chars[i]); i += 1 }
                i -= 1
            }
            return env[name] ?? ""
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "#" where !hasWord: i = chars.count
            case "'":
                hasWord = true; quoted = true; i += 1
                while i < chars.count, chars[i] != "'" { cur.append(chars[i]); i += 1 }
                if i >= chars.count { throw CommandError("unterminated quote") }
            case "\"":
                hasWord = true; quoted = true; i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count, "$\"\\`".contains(chars[i+1]) { i += 1; cur.append(chars[i]) }
                    else if chars[i] == "$" { cur += expandVar() }
                    else { cur.append(chars[i]) }
                    i += 1
                }
                if i >= chars.count { throw CommandError("unterminated quote") }
            case "\\":
                if i + 1 < chars.count { i += 1; cur.append(chars[i]); hasWord = true }
            case "$": cur += expandVar(); hasWord = true
            case " ", "\t": flush()
            case "|", ";", "&", ">", "<":
                flush()
                if (c == "&" || c == ">") && i + 1 < chars.count && chars[i+1] == c { tokens.append(.op(String([c, c]))); i += 1 }
                else { tokens.append(.op(String(c))) }
            case "~" where !hasWord && (i + 1 >= chars.count || chars[i+1] == "/"):
                cur += Workspace.home.path; hasWord = true
            default: cur.append(c); hasWord = true
            }
            i += 1
        }
        flush()
        // glob expansion
        var out: [Token] = []
        for (idx, t) in tokens.enumerated() {
            if case .word(let w) = t, !noGlob.contains(idx), w.contains("*") || w.contains("?") {
                let matches = Glob.expand(w, cwd: URL(fileURLWithPath: env["PWD"] ?? Workspace.home.path))
                if matches.isEmpty { out.append(t) } else { out.append(contentsOf: matches.map { .word($0) }) }
            } else { out.append(t) }
        }
        _ = chars; chars = []
        return out
    }
}

enum Glob {
    static func expand(_ pattern: String, cwd: URL) -> [String] {
        let url = Workspace.resolve(pattern, cwd: cwd)
        let dir = url.deletingLastPathComponent()
        let pat = url.lastPathComponent
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let prefix: String
        if pattern.contains("/") {
            prefix = String(pattern[...pattern.lastIndex(of: "/")!])
        } else { prefix = "" }
        return items.filter { !$0.hasPrefix(".") && match(pat, $0) }.sorted().map { prefix + $0 }
    }

    static func match(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern), n = Array(name)
        var dp = Array(repeating: Array(repeating: false, count: n.count + 1), count: p.count + 1)
        dp[0][0] = true
        for i in 1...max(p.count, 1) where i <= p.count {
            for j in 0...n.count {
                if p[i-1] == "*" { dp[i][j] = dp[i-1][j] || (j > 0 && dp[i][j-1]) }
                else if j > 0 && (p[i-1] == "?" || p[i-1] == n[j-1]) { dp[i][j] = dp[i-1][j-1] }
            }
        }
        return dp[p.count][n.count]
    }
}
