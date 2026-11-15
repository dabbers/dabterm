import Foundation
import CryptoKit
import Citadel
import NIOCore

/// Loading and generating OpenSSH keys. Generation produces the standard
/// "openssh-key-v1" private key format (unencrypted) plus the one-line public key.
enum SSHKeys {
    enum LoadedKey { case ed25519(Curve25519.Signing.PrivateKey); case rsa(Insecure.RSA.PrivateKey) }

    static func load(_ url: URL, passphrase: String? = nil) throws -> LoadedKey {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw CommandError("cannot read key \(Workspace.display(url))") }
        let pass = passphrase.map { Data($0.utf8) }
        if let k = try? Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: pass) { return .ed25519(k) }
        if let k = try? Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: pass) { return .rsa(k) }
        if text.contains("BEGIN OPENSSH PRIVATE KEY"), text.contains("aes256") || passphrase == nil {
            // Detect encrypted keys so the caller can prompt
            if passphrase == nil, let body = openSSHBody(text), body.range(of: Data("bcrypt".utf8)) != nil { throw KeyError.passphraseRequired }
        }
        throw CommandError("unsupported or corrupt key \(Workspace.display(url)) (ed25519 and rsa OpenSSH keys are supported)")
    }
    enum KeyError: Error { case passphraseRequired }

    private static func openSSHBody(_ pem: String) -> Data? {
        let lines = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }
        return Data(base64Encoded: lines.joined())
    }

    /// Finds candidate identities: explicit IdentityFile, then default names in ~/ssh.
    static func candidates(for host: SSHHostConfig) -> [URL] {
        var list: [URL] = []
        if let i = host.resolvedIdentity() { list.append(i) }
        for n in ["id_ed25519", "id_rsa", "id_ecdsa"] { let u = Workspace.sshDir.appendingPathComponent(n); if FileManager.default.fileExists(atPath: u.path) { list.append(u) } }
        return list
    }

    // MARK: generation
    static func generateEd25519(comment: String) -> (privatePEM: String, publicLine: String) {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation
        var pubBlob = ByteBuffer()
        pubBlob.writeSSHString("ssh-ed25519"); pubBlob.writeSSHString(pub)
        let publicLine = "ssh-ed25519 " + Data(pubBlob.readableBytesView).base64EncodedString() + (comment.isEmpty ? "" : " " + comment)

        var priv = ByteBuffer()
        let check = UInt32.random(in: 0...UInt32.max)
        priv.writeInteger(check); priv.writeInteger(check)
        priv.writeSSHString("ssh-ed25519")
        priv.writeSSHString(pub)
        priv.writeSSHString(key.rawRepresentation + pub)
        priv.writeSSHString(comment)
        var pad: UInt8 = 1
        while priv.readableBytes % 8 != 0 { priv.writeInteger(pad); pad += 1 }

        var out = ByteBuffer()
        out.writeBytes(Array("openssh-key-v1".utf8) + [0])
        out.writeSSHString("none"); out.writeSSHString("none"); out.writeSSHString("")
        out.writeInteger(UInt32(1))
        out.writeSSHString(pubBlob.readableBytesView)
        out.writeSSHString(priv.readableBytesView)
        let b64 = Data(out.readableBytesView).base64EncodedString()
        var pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        var idx = b64.startIndex
        while idx < b64.endIndex { let end = b64.index(idx, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex; pem += b64[idx..<end] + "\n"; idx = end }
        pem += "-----END OPENSSH PRIVATE KEY-----\n"
        return (pem, publicLine)
    }

    static func fingerprint(publicLine: String) -> String {
        let parts = publicLine.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "?" }
        let h = SHA256.hash(data: blob)
        return "SHA256:" + Data(h).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    static func publicLine(for key: LoadedKey, comment: String) -> String {
        switch key {
        case .ed25519(let k):
            var b = ByteBuffer(); b.writeSSHString("ssh-ed25519"); b.writeSSHString(k.publicKey.rawRepresentation)
            return ("ssh-ed25519 " + Data(b.readableBytesView).base64EncodedString() + " " + comment).trimmingCharacters(in: .whitespaces)
        case .rsa(let k):
            var b = ByteBuffer(); b.writeSSHString("ssh-rsa"); _ = k.publicKey.write(to: &b)
            return ("ssh-rsa " + Data(b.readableBytesView).base64EncodedString() + " " + comment).trimmingCharacters(in: .whitespaces)
        }
    }
}

extension ByteBuffer {
    @discardableResult mutating func writeSSHString(_ s: String) -> Int { writeInteger(UInt32(s.utf8.count)) + writeString(s) }
    @discardableResult mutating func writeSSHString<C: Collection>(_ bytes: C) -> Int where C.Element == UInt8 { writeInteger(UInt32(bytes.count)) + writeBytes(bytes) }
}
