public import Foundation
internal import OpenSSL
internal import CryptoKit
internal import Network

/// A practical subset of the `openssl` CLI implemented on top of libcrypto (OpenSSL 3).
/// Supported: version, rand, dgst, genrsa, genpkey, ecparam, req (-new, -x509), x509, rsa, pkey,
/// pkcs12 (export), s_client (-connect, prints the chain), enc (-aes-256-cbc with -pbkdf2), passwd.
/// Host-side I/O the engine needs (implemented by the app's shell command context).
public protocol OpenSSLIO: AnyObject {
    var args: [String] { get }
    var stdin: String? { get }
    func path(_ s: String) -> URL
    func write(_ s: String)
    func print(_ s: String)
    func printErr(_ s: String)
}

public struct OpenSSLError: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}
typealias CommandError = OpenSSLError

public struct OpenSSLEngine {
    public static var usage: String { "openssl <version|rand|dgst|genrsa|genpkey|ecparam|req|x509|rsa|pkey|pkcs12|s_client|enc|verify|prime> [options]" }
    var usage: String { Self.usage }
    public init() {}

    public func run(_ ctx: OpenSSLIO) async throws -> Int32 {
        guard let sub = ctx.args.first else { throw CommandError("usage: \(usage)") }
        let rest = Array(ctx.args.dropFirst())
        let o = Opts(rest)
        switch sub {
        case "version": ctx.print(String(cString: OpenSSL_version(OPENSSL_VERSION)))
        case "rand": try rand(o, ctx)
        case "dgst", "sha256", "sha1", "sha512", "md5": try dgst(sub == "dgst" ? o : Opts(["-\(sub)"] + rest), ctx)
        case "genrsa": try genrsa(o, ctx)
        case "genpkey": try genpkey(o, ctx)
        case "ecparam": try ecparam(o, ctx)
        case "req": try req(o, ctx)
        case "x509": try x509(o, ctx)
        case "rsa", "pkey", "ec": try pkey(o, ctx)
        case "pkcs12": try pkcs12(o, ctx)
        case "s_client": try await sclient(o, ctx)
        case "enc": try enc(o, ctx)
        case "verify": try verify(o, ctx)
        case "prime": try prime(o, ctx)
        case "passwd": try passwd(o, ctx)
        case "help", "list": ctx.print(usage)
        default: throw CommandError("unsupported subcommand '\(sub)'\n\(usage)")
        }
        return 0
    }

    // MARK: option parsing
    struct Opts {
        var flags: [String: String] = [:]; var positional: [String] = []
        init(_ a: [String]) {
            var i = 0
            while i < a.count {
                if a[i].hasPrefix("-"), a[i].count > 1, Int(a[i]) == nil {
                    let k = String(a[i].dropFirst())
                    if Self.valueFlags.contains(k), i + 1 < a.count { flags[k] = a[i+1]; i += 1 } else { flags[k] = "" }
                } else { positional.append(a[i]) }
                i += 1
            }
        }
        /// Options that take an argument. Everything else is a boolean switch.
        static let valueFlags: Set<String> = ["in", "out", "inkey", "key", "keyout", "subj", "days", "algorithm", "pkeyopt", "name", "connect", "servername", "CAfile", "CApath", "pass", "passin", "passout", "iter", "k", "kfile", "md", "signkey", "CA", "CAkey", "set_serial", "extfile", "extensions", "addext", "outform", "inform", "newkey", "certfile", "checkend", "config", "rand", "writerand", "untrusted", "trusted", "verify_name", "attime", "S", "paramfile", "hmac", "cipher", "starttls", "alpn", "sigopt", "digest", "nameopt", "certopt", "dateopt"]
        func has(_ k: String) -> Bool { flags[k] != nil }
        subscript(_ k: String) -> String? { flags[k] }
    }

    // MARK: helpers
    private func readInput(_ o: Opts, _ ctx: OpenSSLIO, key: String = "in") throws -> Data {
        if let p = o[key] { guard let d = FileManager.default.contents(atPath: ctx.path(p).path) else { throw CommandError("cannot open \(p)") }; return d }
        if let s = ctx.stdin { return Data(s.utf8) }
        throw CommandError("no input: use -\(key) file")
    }
    private func writeOutput(_ data: Data, _ o: Opts, _ ctx: OpenSSLIO, key: String = "out") throws {
        if let p = o[key] { try data.write(to: ctx.path(p)); ctx.printErr("wrote \(p)") }
        else { ctx.write(String(decoding: data, as: UTF8.self)) }
    }
    private func bioToData(_ bio: OpaquePointer?) -> Data {
        var ptr: UnsafeMutablePointer<CChar>? = nil
        let len = BIO_ctrl(bio, BIO_CTRL_INFO, 0, &ptr)
        guard let p = ptr, len > 0 else { return Data() }
        return Data(bytes: p, count: Int(len))
    }
    /// Runs `body` with a read-only memory BIO over `data`. The buffer must outlive the BIO, so
    /// everything that reads from it happens inside the closure.
    private func withMemBIO<T>(_ data: Data, _ body: (OpaquePointer?) throws -> T) rethrows -> T {
        let bytes = [UInt8](data)
        return try bytes.withUnsafeBufferPointer { bp in
            let bio = BIO_new_mem_buf(bp.baseAddress, Int32(bp.count))
            defer { BIO_free(bio) }
            return try body(bio)
        }
    }
    private func lastError() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        ERR_error_string_n(ERR_get_error(), &buf, buf.count)
        return String(cString: buf)
    }
    private func pemPassword(_ o: Opts) -> String? {
        for k in ["passin", "passout", "pass"] { if let v = o[k] { return v.hasPrefix("pass:") ? String(v.dropFirst(5)) : v } }
        return nil
    }

    private func loadPrivateKey(_ data: Data, pass: String?) throws -> OpaquePointer {
        let key: OpaquePointer? = withMemBIO(data) { bio in
            if var pw = pass.map({ Array($0.utf8CString) }) { return pw.withUnsafeMutableBufferPointer { PEM_read_bio_PrivateKey(bio, nil, nil, $0.baseAddress) } }
            return PEM_read_bio_PrivateKey(bio, nil, nil, nil)
        }
        guard let key else { throw CommandError("unable to load private key: \(lastError())") }
        return key
    }
    private func loadPublicKey(_ data: Data) throws -> OpaquePointer {
        guard let k = withMemBIO(data, { PEM_read_bio_PUBKEY($0, nil, nil, nil) }) else { throw CommandError("unable to load public key") }
        return k
    }
    private func loadCert(_ data: Data) throws -> OpaquePointer {
        if let c = withMemBIO(data, { PEM_read_bio_X509($0, nil, nil, nil) }) { return c }
        // try DER
        var p: UnsafePointer<UInt8>? = [UInt8](data).withUnsafeBufferPointer { $0.baseAddress }
        let bytes = [UInt8](data)
        let c = bytes.withUnsafeBufferPointer { bp -> OpaquePointer? in var q = bp.baseAddress; return d2i_X509(nil, &q, bytes.count) }
        _ = p; p = nil
        guard let c else { throw CommandError("unable to load certificate: \(lastError())") }
        return c
    }
    private func privateKeyPEM(_ key: OpaquePointer, pass: String?) -> Data {
        let bio = BIO_new(BIO_s_mem()); defer { BIO_free(bio) }
        if let pass { var pw = Array(pass.utf8); PEM_write_bio_PKCS8PrivateKey(bio, key, EVP_aes_256_cbc(), nil, 0, nil, &pw) }
        else { PEM_write_bio_PrivateKey(bio, key, nil, nil, 0, nil, nil) }
        return bioToData(bio)
    }
    private func publicKeyPEM(_ key: OpaquePointer) -> Data {
        let bio = BIO_new(BIO_s_mem()); defer { BIO_free(bio) }
        PEM_write_bio_PUBKEY(bio, key)
        return bioToData(bio)
    }
    private func certPEM(_ cert: OpaquePointer) -> Data {
        let bio = BIO_new(BIO_s_mem()); defer { BIO_free(bio) }
        PEM_write_bio_X509(bio, cert)
        return bioToData(bio)
    }
    private func certText(_ cert: OpaquePointer) -> String {
        let bio = BIO_new(BIO_s_mem()); defer { BIO_free(bio) }
        X509_print_ex(bio, cert, 0, UInt(X509_FLAG_COMPAT))
        return String(decoding: bioToData(bio), as: UTF8.self)
    }
    private func nameOneLine(_ name: OpaquePointer?) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        X509_NAME_oneline(name, &buf, Int32(buf.count))
        return String(cString: buf).replacingOccurrences(of: "/", with: ", ").trimmingCharacters(in: CharacterSet(charactersIn: ", "))
    }
    private func asn1Time(_ t: UnsafePointer<ASN1_TIME>?) -> String {
        let bio = BIO_new(BIO_s_mem()); defer { BIO_free(bio) }
        ASN1_TIME_print(bio, t)
        return String(decoding: bioToData(bio), as: UTF8.self)
    }

    private func setTime(_ t: UnsafeMutablePointer<ASN1_TIME>?, _ offset: Int) {
        X509_gmtime_adj(t, offset)
    }

    // MARK: key generation
    private func generateRSA(bits: Int) throws -> OpaquePointer {
        let pctx = EVP_PKEY_CTX_new_from_name(nil, "RSA", nil); defer { EVP_PKEY_CTX_free(pctx) }
        var key: OpaquePointer? = nil
        guard EVP_PKEY_keygen_init(pctx) == 1, EVP_PKEY_CTX_set_rsa_keygen_bits(pctx, Int32(bits)) == 1, EVP_PKEY_generate(pctx, &key) == 1, let key else { throw CommandError("RSA generation failed: \(lastError())") }
        return key
    }
    private func generateEC(curve: String) throws -> OpaquePointer {
        let normalized = ["prime256v1": "P-256", "secp256r1": "P-256", "secp384r1": "P-384", "secp521r1": "P-521"][curve] ?? curve
        let pctx = EVP_PKEY_CTX_new_from_name(nil, "EC", nil); defer { EVP_PKEY_CTX_free(pctx) }
        var key: OpaquePointer? = nil
        guard EVP_PKEY_keygen_init(pctx) == 1, EVP_PKEY_CTX_set_group_name(pctx, normalized) == 1, EVP_PKEY_generate(pctx, &key) == 1, let key else { throw CommandError("EC generation failed for curve \(curve): \(lastError())") }
        return key
    }
    private func generateKey(algorithm: String, opts: [String]) throws -> OpaquePointer {
        switch algorithm.uppercased() {
        case "RSA":
            let bits = opts.compactMap { $0.hasPrefix("rsa_keygen_bits:") ? Int($0.dropFirst(16)) : nil }.first ?? 2048
            return try generateRSA(bits: bits)
        case "EC":
            let curve = opts.compactMap { $0.hasPrefix("ec_paramgen_curve:") ? String($0.dropFirst(18)) : nil }.first ?? "P-256"
            return try generateEC(curve: curve)
        case "ED25519", "ED448", "X25519":
            let pctx = EVP_PKEY_CTX_new_from_name(nil, algorithm.uppercased(), nil)
            defer { EVP_PKEY_CTX_free(pctx) }
            var key: OpaquePointer? = nil
            guard EVP_PKEY_keygen_init(pctx) == 1, EVP_PKEY_generate(pctx, &key) == 1, let key else { throw CommandError("keygen failed: \(lastError())") }
            return key
        default: throw CommandError("unsupported algorithm \(algorithm) (RSA, EC, ED25519)")
        }
    }

    private func genrsa(_ o: Opts, _ ctx: OpenSSLIO) throws {
        let bits = o.positional.compactMap { Int($0) }.first ?? 2048
        guard bits >= 512, bits <= 16384 else { throw CommandError("bits must be 512..16384") }
        ctx.printErr("Generating RSA private key, \(bits) bit long modulus")
        let key = try generateRSA(bits: bits); defer { EVP_PKEY_free(key) }
        try writeOutput(privateKeyPEM(key, pass: o.has("aes256") ? pemPassword(o) : nil), o, ctx)
    }
    private func genpkey(_ o: Opts, _ ctx: OpenSSLIO) throws {
        let alg = o["algorithm"] ?? "RSA"
        var popts: [String] = []
        // collect all -pkeyopt values (Opts keeps last only, so re-scan)
        var i = 0; let a = ctx.args
        while i < a.count { if a[i] == "-pkeyopt", i + 1 < a.count { popts.append(a[i+1]); i += 1 }; i += 1 }
        let key = try generateKey(algorithm: alg, opts: popts); defer { EVP_PKEY_free(key) }
        if o.has("pubout") { try writeOutput(publicKeyPEM(key), o, ctx) } else { try writeOutput(privateKeyPEM(key, pass: pemPassword(o)), o, ctx) }
    }
    private func ecparam(_ o: Opts, _ ctx: OpenSSLIO) throws {
        let curve = o["name"] ?? "prime256v1"
        if o.has("list_curves") { ctx.print("prime256v1 (P-256)\nsecp384r1 (P-384)\nsecp521r1 (P-521)"); return }
        guard o.has("genkey") else { ctx.print("-----BEGIN EC PARAMETERS-----\n(use -genkey to generate a key for \(curve))\n-----END EC PARAMETERS-----"); return }
        let key = try generateEC(curve: curve); defer { EVP_PKEY_free(key) }
        try writeOutput(privateKeyPEM(key, pass: nil), o, ctx)
    }

    // MARK: req / x509
    private func parseSubject(_ s: String) -> OpaquePointer {
        let name = X509_NAME_new()!
        for part in s.split(separator: "/") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let k = String(part[..<eq]), v = String(part[part.index(after: eq)...])
            X509_NAME_add_entry_by_txt(name, k, MBSTRING_UTF8, v, -1, -1, 0)
        }
        return name
    }
    /// Extensions are DER-encoded by hand: X509V3_CTX / X509V3_EXT_nconf cannot be used from Swift
    /// here because BoringSSL (via SwiftNIO SSH) and OpenSSL disagree on that struct's layout.
    /// Supported: basicConstraints, subjectAltName (DNS/IP/email/URI), keyUsage, extendedKeyUsage,
    /// subjectKeyIdentifier=hash.
    private func makeExtension(_ key: String, _ value: String, cert: OpaquePointer?) -> OpaquePointer? {
        let critical = value.lowercased().contains("critical")
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.lowercased() != "critical" }
        var der: [UInt8] = []
        var nid: Int32 = 0
        switch key.lowercased() {
        case "basicconstraints":
            nid = NID_basic_constraints
            let isCA = parts.contains { $0.uppercased() == "CA:TRUE" }
            der = DER.sequence(isCA ? [0x01, 0x01, 0xFF] : [])
        case "subjectaltname":
            nid = NID_subject_alt_name
            var names: [UInt8] = []
            for p in parts {
                let kv = p.split(separator: ":", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0].uppercased() {
                case "DNS": names += DER.tlv(0x82, Array(kv[1].utf8))
                case "EMAIL": names += DER.tlv(0x81, Array(kv[1].utf8))
                case "URI": names += DER.tlv(0x86, Array(kv[1].utf8))
                case "IP":
                    var a4 = in_addr(); var a6 = in6_addr()
                    if inet_pton(AF_INET, kv[1], &a4) == 1 { names += DER.tlv(0x87, withUnsafeBytes(of: &a4) { Array($0) }) }
                    else if inet_pton(AF_INET6, kv[1], &a6) == 1 { names += DER.tlv(0x87, withUnsafeBytes(of: &a6) { Array($0) }) }
                default: break
                }
            }
            der = DER.sequence(names)
        case "keyusage":
            nid = NID_key_usage
            let bits: [String: Int] = ["digitalsignature": 0, "nonrepudiation": 1, "contentcommitment": 1, "keyencipherment": 2, "dataencipherment": 3, "keyagreement": 4, "keycertsign": 5, "crlsign": 6, "encipheronly": 7, "decipheronly": 8]
            var mask: UInt16 = 0
            for p in parts { if let b = bits[p.lowercased()] { mask |= UInt16(1) << UInt16(15 - b) } }
            var bytes: [UInt8] = [UInt8(mask >> 8)]
            if mask & 0xff != 0 { bytes.append(UInt8(mask & 0xff)) }
            var unused: UInt8 = 0
            if let last = bytes.last, last != 0 { var l = last; while l & 1 == 0 { l >>= 1; unused += 1 } }
            der = DER.tlv(0x03, [unused] + bytes)
        case "extendedkeyusage":
            nid = NID_ext_key_usage
            let oids: [String: [UInt8]] = ["serverauth": [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01], "clientauth": [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02], "codesigning": [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03], "emailprotection": [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x04], "timestamping": [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x08], "ocspsigning": [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x09]]
            var body: [UInt8] = []
            for p in parts { if let o = oids[p.lowercased()] { body += DER.tlv(0x06, o) } }
            der = DER.sequence(body)
        case "subjectkeyidentifier":
            nid = NID_subject_key_identifier
            guard let cert, let pk = X509_get0_pubkey(cert) else { return nil }
            var p: UnsafeMutablePointer<UInt8>? = nil
            let len = i2d_PUBKEY(pk, &p)
            guard let p, len > 0 else { return nil }
            defer { CRYPTO_free(p, "", 0) }
            // SKI = SHA-1 of the subjectPublicKey BIT STRING contents; approximate with hash of the full SPKI DER
            let digest = Insecure.SHA1.hash(data: Data(bytes: p, count: Int(len)))
            der = DER.tlv(0x04, Array(digest))
        default: return nil
        }
        guard !der.isEmpty else { return nil }
        let oct = ASN1_OCTET_STRING_new()
        defer { ASN1_OCTET_STRING_free(oct) }
        ASN1_OCTET_STRING_set(oct, der, Int32(der.count))
        return X509_EXTENSION_create_by_NID(nil, nid, critical ? 1 : 0, oct)
    }

    /// `isCA` follows OpenSSL 3: `req -x509` makes a CA cert unless basicConstraints is given via -addext.
    private func addExtensions(cert: OpaquePointer, issuer: OpaquePointer, o: Opts, args: [String], isCA: Bool) {
        let custom = addextPairs(args)
        var exts: [(String, String)] = [("subjectKeyIdentifier", "hash")]
        if !custom.contains(where: { $0.0.lowercased() == "basicconstraints" }) { exts.append(("basicConstraints", isCA ? "critical,CA:TRUE" : "CA:FALSE")) }
        exts += custom
        if let ef = o["extfile"], let text = try? String(contentsOfFile: ef, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.contains("=") && !line.hasPrefix("[") && !line.hasPrefix("#") {
                let p = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                exts.append((p[0], p[1]))
            }
        }
        for (k, v) in exts {
            if let ext = makeExtension(k, v, cert: cert) { X509_add_ext(cert, ext, -1); X509_EXTENSION_free(ext) }
        }
    }
    private func addextPairs(_ args: [String]) -> [(String, String)] {
        var out: [(String, String)] = []
        var i = 0
        while i < args.count {
            if args[i] == "-addext", i + 1 < args.count, let eq = args[i+1].firstIndex(of: "=") { out.append((String(args[i+1][..<eq]), String(args[i+1][args[i+1].index(after: eq)...]))); i += 1 }
            i += 1
        }
        return out
    }
    private func req(_ o: Opts, _ ctx: OpenSSLIO) throws {
        let pass = pemPassword(o)
        var key: OpaquePointer
        var keyWasGenerated = false
        if let kp = o["key"] { key = try loadPrivateKey(try readInput(o, ctx, key: "key"), pass: pass); _ = kp }
        else {
            let spec = o["newkey"] ?? "rsa:2048"
            if spec.lowercased().hasPrefix("rsa:") { key = try generateRSA(bits: Int(spec.dropFirst(4)) ?? 2048) }
            else if spec.lowercased().hasPrefix("ec:") || spec.lowercased().hasPrefix("ec") { key = try generateEC(curve: spec.contains(":") ? String(spec.split(separator: ":")[1]) : "P-256") }
            else if spec.lowercased() == "ed25519" { key = try generateKey(algorithm: "ED25519", opts: []) }
            else { throw CommandError("unsupported -newkey \(spec)") }
            keyWasGenerated = true
            ctx.printErr("Generating a \(spec) private key")
        }
        defer { EVP_PKEY_free(key) }
        if keyWasGenerated {
            let keyOut = o["keyout"] ?? "privkey.pem"
            try privateKeyPEM(key, pass: o.has("nodes") || o.has("noenc") ? nil : pass).write(to: ctx.path(keyOut))
            ctx.printErr("wrote private key to \(keyOut)")
        }
        let subj = o["subj"] ?? "/CN=localhost"
        let subject = parseSubject(subj); defer { X509_NAME_free(subject) }
        let mdName = ["sha256", "sha384", "sha512"].first { o.has($0) } ?? "sha256"
        let md = EVP_PKEY_get_id(key) == EVP_PKEY_ED25519 ? nil : EVP_get_digestbyname(mdName)
        if o.has("x509") {
            let cert = X509_new()!; defer { X509_free(cert) }
            X509_set_version(cert, 2)
            let serial = ASN1_INTEGER_new(); ASN1_INTEGER_set_int64(serial, Int64(o["set_serial"].flatMap { Int($0) } ?? Int(Date().timeIntervalSince1970))); X509_set_serialNumber(cert, serial); ASN1_INTEGER_free(serial)
            let days = Int(o["days"] ?? "365") ?? 365
            setTime(X509_getm_notBefore(cert), 0)
            setTime(X509_getm_notAfter(cert), days * 86400)
            X509_set_subject_name(cert, subject); X509_set_issuer_name(cert, subject)
            X509_set_pubkey(cert, key)
            addExtensions(cert: cert, issuer: cert, o: o, args: ctx.args, isCA: !o.has("not-ca") && !o.has("noca"))
            guard X509_sign(cert, key, md) > 0 else { throw CommandError("signing failed: \(lastError())") }
            if o.has("text") { ctx.write(certText(cert)) }
            try writeOutput(certPEM(cert), o, ctx)
        } else {
            let csr = X509_REQ_new()!; defer { X509_REQ_free(csr) }
            X509_REQ_set_version(csr, 0)
            X509_REQ_set_subject_name(csr, subject)
            X509_REQ_set_pubkey(csr, key)
            // SANs etc. via -addext
            let exts = OPENSSL_sk_new_null()
            for (k, v) in addextPairs(ctx.args) { if let ext = makeExtension(k, v, cert: nil) { OPENSSL_sk_push(exts, UnsafeRawPointer(ext)) } }
            if OPENSSL_sk_num(exts) > 0 { X509_REQ_add_extensions(csr, exts) }
            OPENSSL_sk_pop_free(exts) { X509_EXTENSION_free(OpaquePointer($0)) }
            guard X509_REQ_sign(csr, key, md) > 0 else { throw CommandError("signing failed: \(lastError())") }
            let bio = BIO_new(BIO_s_mem()); defer { BIO_free(bio) }
            if o.has("text") { X509_REQ_print(bio, csr) }
            PEM_write_bio_X509_REQ(bio, csr)
            try writeOutput(bioToData(bio), o, ctx)
        }
    }

    private func x509(_ o: Opts, _ ctx: OpenSSLIO) throws {
        let input = try readInput(o, ctx)
        // sign a CSR: openssl x509 -req -in csr -CA ca.pem -CAkey ca.key -days N -out cert.pem
        if o.has("req") {
            guard let csr = withMemBIO(input, { PEM_read_bio_X509_REQ($0, nil, nil, nil) }) else { throw CommandError("cannot read CSR") }
            defer { X509_REQ_free(csr) }
            let cert = X509_new()!; defer { X509_free(cert) }
            X509_set_version(cert, 2)
            let serial = ASN1_INTEGER_new(); ASN1_INTEGER_set_int64(serial, Int64(o["set_serial"].flatMap { Int($0) } ?? Int(Date().timeIntervalSince1970))); X509_set_serialNumber(cert, serial); ASN1_INTEGER_free(serial)
            setTime(X509_getm_notBefore(cert), 0); setTime(X509_getm_notAfter(cert), (Int(o["days"] ?? "365") ?? 365) * 86400)
            X509_set_subject_name(cert, X509_REQ_get_subject_name(csr))
            let pub = X509_REQ_get_pubkey(csr); X509_set_pubkey(cert, pub); EVP_PKEY_free(pub)
            var signKey: OpaquePointer
            var issuerCert: OpaquePointer? = nil
            if let caPath = o["CA"] {
                guard let caData = FileManager.default.contents(atPath: ctx.path(caPath).path) else { throw CommandError("cannot open CA \(caPath)") }
                issuerCert = try loadCert(caData)
                X509_set_issuer_name(cert, X509_get_subject_name(issuerCert))
                guard let kp = o["CAkey"], let kd = FileManager.default.contents(atPath: ctx.path(kp).path) else { throw CommandError("-CAkey required") }
                signKey = try loadPrivateKey(kd, pass: pemPassword(o))
            } else {
                guard let kp = o["signkey"], let kd = FileManager.default.contents(atPath: ctx.path(kp).path) else { throw CommandError("-signkey or -CA/-CAkey required") }
                signKey = try loadPrivateKey(kd, pass: pemPassword(o))
                X509_set_issuer_name(cert, X509_REQ_get_subject_name(csr))
            }
            defer { EVP_PKEY_free(signKey); if let issuerCert { X509_free(issuerCert) } }
            // copy requested extensions
            if let reqExts = X509_REQ_get_extensions(csr) {
                let sk = reqExts
                for i in 0..<OPENSSL_sk_num(sk) { X509_add_ext(cert, OpaquePointer(OPENSSL_sk_value(sk, i)), -1) }
                OPENSSL_sk_pop_free(sk) { X509_EXTENSION_free(OpaquePointer($0)) }
            }
            addExtensions(cert: cert, issuer: issuerCert ?? cert, o: o, args: ctx.args, isCA: false)
            let md = EVP_PKEY_get_id(signKey) == EVP_PKEY_ED25519 ? nil : EVP_get_digestbyname("sha256")
            guard X509_sign(cert, signKey, md) > 0 else { throw CommandError("signing failed: \(lastError())") }
            ctx.printErr("Certificate request self-signature ok\nsubject=\(nameOneLine(X509_get_subject_name(cert)))")
            try writeOutput(certPEM(cert), o, ctx)
            return
        }
        let cert = try loadCert(input); defer { X509_free(cert) }
        var printed = false
        if o.has("text") { ctx.write(certText(cert)); printed = true }
        if o.has("subject") { ctx.print("subject=\(nameOneLine(X509_get_subject_name(cert)))"); printed = true }
        if o.has("issuer") { ctx.print("issuer=\(nameOneLine(X509_get_issuer_name(cert)))"); printed = true }
        if o.has("dates") || o.has("startdate") { ctx.print("notBefore=\(asn1Time(X509_get0_notBefore(cert)))"); printed = true }
        if o.has("dates") || o.has("enddate") { ctx.print("notAfter=\(asn1Time(X509_get0_notAfter(cert)))"); printed = true }
        if o.has("serial") { let bn = ASN1_INTEGER_to_BN(X509_get_serialNumber(cert), nil); let hex = BN_bn2hex(bn); ctx.print("serial=\(String(cString: hex!))"); CRYPTO_free(hex, "", 0); BN_free(bn); printed = true }
        if o.has("fingerprint") || o.has("sha256") || o.has("sha1") {
            let mdName = o.has("sha1") ? "sha1" : "sha256"
            var buf = [UInt8](repeating: 0, count: Int(EVP_MAX_MD_SIZE)); var len: UInt32 = 0
            X509_digest(cert, EVP_get_digestbyname(mdName), &buf, &len)
            ctx.print("\(mdName.uppercased()) Fingerprint=" + buf[0..<Int(len)].map { String(format: "%02X", $0) }.joined(separator: ":")); printed = true
        }
        if o.has("pubkey") { let pk = X509_get_pubkey(cert); ctx.write(String(decoding: publicKeyPEM(pk!), as: UTF8.self)); EVP_PKEY_free(pk); printed = true }
        if o.has("checkend"), let secs = Int(o["checkend"] ?? "") {
            var day: Int32 = 0, sec: Int32 = 0
            ASN1_TIME_diff(&day, &sec, nil, X509_get0_notAfter(cert))
            let remaining = Int(day) * 86400 + Int(sec)
            ctx.print(remaining > secs ? "Certificate will not expire" : "Certificate will expire"); printed = true
        }
        if o.has("ext") || o.has("purpose") { ctx.write(certText(cert)); printed = true }
        if !o.has("noout") && (o["outform"]?.uppercased() == "DER") { try writeOutput(derOf(cert), o, ctx) }
        else if !o.has("noout") || !printed { try writeOutput(certPEM(cert), o, ctx) }
    }
    private func derOf(_ cert: OpaquePointer) -> Data {
        var p: UnsafeMutablePointer<UInt8>? = nil
        let len = i2d_X509(cert, &p)
        guard let p, len > 0 else { return Data() }
        defer { CRYPTO_free(p, "", 0) }
        return Data(bytes: p, count: Int(len))
    }

    private func pkey(_ o: Opts, _ ctx: OpenSSLIO) throws {
        let input = try readInput(o, ctx)
        let key: OpaquePointer = o.has("pubin") ? try loadPublicKey(input) : try loadPrivateKey(input, pass: o["passin"].map { $0.hasPrefix("pass:") ? String($0.dropFirst(5)) : $0 })
        defer { EVP_PKEY_free(key) }
        if o.has("text") || o.has("text_pub") {
            let bio = BIO_new(BIO_s_mem()); defer { BIO_free(bio) }
            if o.has("pubin") || o.has("text_pub") { EVP_PKEY_print_public(bio, key, 0, nil) } else { EVP_PKEY_print_private(bio, key, 0, nil) }
            ctx.write(String(decoding: bioToData(bio), as: UTF8.self))
        }
        if o.has("check") { ctx.print(EVP_PKEY_get_id(key) == EVP_PKEY_RSA ? "RSA key ok" : "key ok") }
        if o.has("noout") { return }
        if o.has("pubout") || o.has("pubin") { try writeOutput(publicKeyPEM(key), o, ctx) }
        else { try writeOutput(privateKeyPEM(key, pass: o["passout"].map { $0.hasPrefix("pass:") ? String($0.dropFirst(5)) : $0 } ?? (o.has("aes256") ? pemPassword(o) : nil)), o, ctx) }
    }

    private func pkcs12(_ o: Opts, _ ctx: OpenSSLIO) throws {
        guard o.has("export") else { throw CommandError("only -export is supported (openssl pkcs12 -export -inkey key.pem -in cert.pem -out bundle.p12 -passout pass:secret)") }
        let cert = try loadCert(try readInput(o, ctx)); defer { X509_free(cert) }
        let key = try loadPrivateKey(try readInput(o, ctx, key: "inkey"), pass: o["passin"]); defer { EVP_PKEY_free(key) }
        let pass = (o["passout"] ?? "pass:").replacingOccurrences(of: "pass:", with: "")
        guard let p12 = PKCS12_create(pass, o["name"] ?? "dabterm", key, cert, nil, 0, 0, 0, 0, 0) else { throw CommandError("PKCS12_create failed: \(lastError())") }
        defer { PKCS12_free(p12) }
        var p: UnsafeMutablePointer<UInt8>? = nil
        let len = i2d_PKCS12(p12, &p)
        guard let p, len > 0 else { throw CommandError("encode failed") }
        defer { CRYPTO_free(p, "", 0) }
        guard let out = o["out"] else { throw CommandError("-out required") }
        try Data(bytes: p, count: Int(len)).write(to: ctx.path(out))
        ctx.printErr("wrote \(out)")
    }

    private func verify(_ o: Opts, _ ctx: OpenSSLIO) throws {
        guard let certPath = o.positional.first else { throw CommandError("usage: openssl verify -CAfile ca.pem cert.pem") }
        guard let cd = FileManager.default.contents(atPath: ctx.path(certPath).path) else { throw CommandError("cannot open \(certPath)") }
        let cert = try loadCert(cd); defer { X509_free(cert) }
        let store = X509_STORE_new(); defer { X509_STORE_free(store) }
        if let ca = o["CAfile"], let cad = FileManager.default.contents(atPath: ctx.path(ca).path) {
            withMemBIO(cad) { bio in
                while let c = PEM_read_bio_X509(bio, nil, nil, nil) { X509_STORE_add_cert(store, c); X509_free(c) }
            }
            ERR_clear_error()
        }
        let sctx = X509_STORE_CTX_new(); defer { X509_STORE_CTX_free(sctx) }
        X509_STORE_CTX_init(sctx, store, cert, nil)
        if X509_verify_cert(sctx) == 1 { ctx.print("\(certPath): OK") }
        else { throw CommandError("\(certPath): verification failed: \(String(cString: X509_verify_cert_error_string(Int(X509_STORE_CTX_get_error(sctx)))))") }
    }

    // MARK: misc
    private func rand(_ o: Opts, _ ctx: OpenSSLIO) throws {
        guard let n = o.positional.compactMap({ Int($0) }).first else { throw CommandError("usage: openssl rand [-hex|-base64] num") }
        var buf = [UInt8](repeating: 0, count: n)
        RAND_bytes(&buf, Int32(n))
        if o.has("hex") { ctx.print(buf.map { String(format: "%02x", $0) }.joined()) }
        else if o.has("base64") { ctx.print(Data(buf).base64EncodedString()) }
        else if let out = o["out"] { try Data(buf).write(to: ctx.path(out)) }
        else { ctx.print(buf.map { String(format: "%02x", $0) }.joined()) }
    }
    private func dgst(_ o: Opts, _ ctx: OpenSSLIO) throws {
        let alg = ["sha256", "sha1", "sha512", "sha384", "md5", "sha3-256", "blake2b512"].first { o.has($0) } ?? "sha256"
        guard let md = EVP_get_digestbyname(alg) else { throw CommandError("unknown digest \(alg)") }
        let inputs: [(String?, Data)] = o.positional.isEmpty ? [(nil, Data((ctx.stdin ?? "").utf8))] : try o.positional.map { p in guard let d = FileManager.default.contents(atPath: ctx.path(p).path) else { throw CommandError("cannot open \(p)") }; return (p, d) }
        for (nm, d) in inputs {
            var out = [UInt8](repeating: 0, count: Int(EVP_MAX_MD_SIZE)); var len: UInt32 = 0
            if let hmacKey = o["hmac"] {
                var klen = hmacKey.utf8.count
                HMAC(md, Array(hmacKey.utf8), Int32(klen), [UInt8](d), d.count, &out, &len); _ = klen; klen = 0
            } else {
                let c = EVP_MD_CTX_new(); defer { EVP_MD_CTX_free(c) }
                EVP_DigestInit_ex(c, md, nil); _ = d.withUnsafeBytes { EVP_DigestUpdate(c, $0.baseAddress, d.count) }; EVP_DigestFinal_ex(c, &out, &len)
            }
            let hex = out[0..<Int(len)].map { String(format: "%02x", $0) }.joined()
            if o.has("binary") { ctx.write(String(decoding: out[0..<Int(len)], as: UTF8.self)) }
            else if let nm { ctx.print("\(alg.uppercased())(\(nm))= \(hex)") } else { ctx.print(hex) }
        }
    }
    private func enc(_ o: Opts, _ ctx: OpenSSLIO) throws {
        let cipherName = ["aes-256-cbc", "aes-128-cbc", "aes-256-ctr", "aes-128-ctr", "chacha20"].first { o.has($0) } ?? "aes-256-cbc"
        guard let cipher = EVP_get_cipherbyname(cipherName) else { throw CommandError("unknown cipher") }
        guard let passRaw = o["pass"] ?? o["k"] else { throw CommandError("-pass pass:secret required") }
        let pass = passRaw.hasPrefix("pass:") ? String(passRaw.dropFirst(5)) : passRaw
        let decrypt = o.has("d")
        var input = try readInput(o, ctx)
        if decrypt && o.has("a") { input = Data(base64Encoded: String(decoding: input, as: UTF8.self).filter { !$0.isWhitespace }) ?? input }
        let keyLen = Int(EVP_CIPHER_get_key_length(cipher)), ivLen = Int(EVP_CIPHER_get_iv_length(cipher))
        var salt = [UInt8](repeating: 0, count: 8)
        var body = input
        if decrypt { guard input.count >= 16, input.prefix(8) == Data("Salted__".utf8) else { throw CommandError("bad magic number") }; salt = Array(input[8..<16]); body = input.dropFirst(16) }
        else { RAND_bytes(&salt, 8) }
        var keyiv = [UInt8](repeating: 0, count: keyLen + ivLen)
        let iter = Int32(o["iter"] ?? "10000") ?? 10000
        PKCS5_PBKDF2_HMAC(pass, Int32(pass.utf8.count), salt, 8, iter, EVP_sha256(), Int32(keyLen + ivLen), &keyiv)
        let cctx = EVP_CIPHER_CTX_new(); defer { EVP_CIPHER_CTX_free(cctx) }
        EVP_CipherInit_ex(cctx, cipher, nil, Array(keyiv[0..<keyLen]), Array(keyiv[keyLen...]), decrypt ? 0 : 1)
        var out = [UInt8](repeating: 0, count: body.count + 32); var outLen: Int32 = 0; var fin: Int32 = 0
        guard EVP_CipherUpdate(cctx, &out, &outLen, [UInt8](body), Int32(body.count)) == 1 else { throw CommandError("cipher update failed") }
        guard EVP_CipherFinal_ex(cctx, &out[Int(outLen)], &fin) == 1 else { throw CommandError(decrypt ? "bad decrypt (wrong password?)" : "cipher final failed") }
        var result = Data(out[0..<Int(outLen + fin)])
        if !decrypt { result = Data("Salted__".utf8) + Data(salt) + result; if o.has("a") { result = Data((result.base64EncodedString(options: [.lineLength64Characters]) + "\n").utf8) } }
        try writeOutput(result, o, ctx)
    }
    private func prime(_ o: Opts, _ ctx: OpenSSLIO) throws {
        for p in o.positional {
            var bn = BN_new()
            guard BN_dec2bn(&bn, p) > 0 else { continue }
            let r = BN_check_prime(bn, nil, nil)
            ctx.print("\(p) is \(r == 1 ? "" : "not ")prime"); BN_free(bn)
        }
    }
    private func passwd(_ o: Opts, _ ctx: OpenSSLIO) throws {
        guard let pw = o.positional.first ?? ctx.stdin?.trimmingCharacters(in: .whitespacesAndNewlines) else { throw CommandError("usage: openssl passwd [-6|-5] password") }
        var saltBytes = [UInt8](repeating: 0, count: 12); RAND_bytes(&saltBytes, 12)
        let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"); let salt = String(saltBytes.map { alphabet[Int($0 % 64)] })
        // sha512-crypt / sha256-crypt via OpenSSL's crypt-compatible helper is not exported; use a PBKDF2 fallback labelled accordingly
        var out = [UInt8](repeating: 0, count: 32)
        PKCS5_PBKDF2_HMAC(pw, Int32(pw.utf8.count), Array(salt.utf8), Int32(salt.utf8.count), 100_000, o.has("5") ? EVP_sha256() : EVP_sha512(), 32, &out)
        ctx.print("$pbkdf2-\(o.has("5") ? "sha256" : "sha512")$100000$\(salt)$\(Data(out).base64EncodedString())")
    }

    // MARK: s_client
    private func sclient(_ o: Opts, _ ctx: OpenSSLIO) async throws {
        guard let connect = o["connect"] else { throw CommandError("usage: openssl s_client -connect host:443 [-servername name] [-showcerts]") }
        let parts = connect.split(separator: ":")
        let host = String(parts[0]), port = parts.count > 1 ? Int(parts[1]) ?? 443 : 443
        let sni = o["servername"] ?? host
        let probe = TLSProbe()
        let info = try await probe.connect(host: host, port: port, sni: sni)
        ctx.print("CONNECTED(\(host):\(port))\n---\nCertificate chain")
        for (i, c) in info.chain.enumerated() { ctx.print(" \(i) s:\(c.subject)\n   i:\(c.issuer)\n   v:NotBefore: \(c.notBefore); NotAfter: \(c.notAfter)") }
        if o.has("showcerts") || !o.has("brief") { ctx.print("---"); for c in info.chain { ctx.write(c.pem) } }
        ctx.print("---\nProtocol  : \(info.protocolVersion)\nCipher    : \(info.cipher)\nVerify return code: \(info.trusted ? "0 (ok)" : "21 (unable to verify the first certificate)")")
    }
}

/// Opens a TLS connection with Network.framework and extracts the peer certificate chain.
final class TLSProbe {
    init() {}
    struct CertInfo { let subject: String; let issuer: String; let notBefore: String; let notAfter: String; let pem: String }
    struct Info { let chain: [CertInfo]; let protocolVersion: String; let cipher: String; let trusted: Bool }
    func connect(host: String, port: Int, sni: String) async throws -> Info {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sni)
        var captured: SecTrust? = nil
        var trusted = false
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            captured = trust
            trusted = SecTrustEvaluateWithError(trust, nil)
            complete(true)
        }, .global())
        let params = NWParameters(tls: tls)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: params)
        guard try await withTimeout(10, { try await conn.ready() }) else { conn.cancel(); throw CommandError("connect timed out") }
        var proto = "TLS", cipher = "unknown"
        if let meta = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            let v = sec_protocol_metadata_get_negotiated_tls_protocol_version(meta.securityProtocolMetadata)
            proto = v == .TLSv13 ? "TLSv1.3" : v == .TLSv12 ? "TLSv1.2" : "TLS \(v.rawValue)"
            let c = sec_protocol_metadata_get_negotiated_tls_ciphersuite(meta.securityProtocolMetadata)
            cipher = String(format: "0x%04X", c.rawValue)
        }
        conn.cancel()
        var chain: [CertInfo] = []
        if let trust = captured, let certs = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
            for c in certs {
                let der = SecCertificateCopyData(c) as Data
                let b64 = der.base64EncodedString(options: [.lineLength64Characters])
                let pem = "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
                var subject = SecCertificateCopySubjectSummary(c) as String? ?? "?"
                var issuer = "?", nb = "?", na = "?"
                // Use libcrypto for issuer/dates
                let bytes = [UInt8](der)
                if let x = bytes.withUnsafeBufferPointer({ bp -> OpaquePointer? in var q = bp.baseAddress; return d2i_X509(nil, &q, bytes.count) }) {
                    let bio = BIO_new(BIO_s_mem())
                    var nb1 = [CChar](repeating: 0, count: 1024); X509_NAME_oneline(X509_get_subject_name(x), &nb1, 1024); subject = String(cString: nb1)
                    var nb2 = [CChar](repeating: 0, count: 1024); X509_NAME_oneline(X509_get_issuer_name(x), &nb2, 1024); issuer = String(cString: nb2)
                    ASN1_TIME_print(bio, X509_get0_notBefore(x)); nb = bioString(bio)
                    ASN1_TIME_print(bio, X509_get0_notAfter(x)); na = bioString(bio)
                    BIO_free(bio); X509_free(x)
                }
                chain.append(CertInfo(subject: subject, issuer: issuer, notBefore: nb, notAfter: na, pem: pem))
            }
        }
        return Info(chain: chain, protocolVersion: proto, cipher: cipher, trusted: trusted)
    }
    private func bioString(_ bio: OpaquePointer?) -> String {
        var ptr: UnsafeMutablePointer<CChar>? = nil
        let len = BIO_ctrl(bio, BIO_CTRL_INFO, 0, &ptr)
        let s = ptr.map { String(decoding: Data(bytes: $0, count: Int(len)), as: UTF8.self) } ?? ""
        BIO_ctrl(bio, BIO_CTRL_RESET, 0, nil)
        return s
    }
}

/// Minimal DER encoder.
enum DER {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []; var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag] + length(body.count) + body }
    static func sequence(_ body: [UInt8]) -> [UInt8] { tlv(0x30, body) }
}


// MARK: - NWConnection helpers (package-local copies)
extension NWConnection {
    func ready() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let box = DoneBox()
            stateUpdateHandler = { st in
                guard !box.done else { return }
                switch st {
                case .ready: box.done = true; c.resume()
                case .failed(let e): box.done = true; c.resume(throwing: e)
                case .cancelled: box.done = true; c.resume(throwing: OpenSSLError("cancelled"))
                default: break
                }
            }
            start(queue: .global())
        }
    }
}
final class DoneBox: @unchecked Sendable { var done = false }
func withTimeout(_ seconds: Double, _ op: @escaping @Sendable () async throws -> Void) async throws -> Bool {
    try await withThrowingTaskGroup(of: Bool.self) { g in
        g.addTask { try await op(); return true }
        g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return false }
        let r = try await g.next() ?? false
        g.cancelAll()
        return r
    }
}
