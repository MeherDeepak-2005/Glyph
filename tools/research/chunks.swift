// Research chunk keys and decryption (macOS 14+, CryptoKit HPKE). The app seals every uploaded
// chunk to the research public key (keyboard/App/ResearchUploader.swift); this opens them.
//
//   swift tools/research/chunks.swift keys [--force]
//       Makes a new X25519 key pair: the public key goes to keyboard/App/research-public-key.txt
//       (bundled with the app), the private key to Config/research-private-key.txt (git-ignored).
//       Chunks sealed to an older public key can only be opened with its private key: keep it.
//   swift tools/research/chunks.swift open PRIVATE_KEY_FILE OUT_DIR CHUNK.grc...
//       Decrypts and decompresses each chunk to OUT_DIR/<name>.jsonl.
//   swift tools/research/chunks.swift seal PUBLIC_KEY_FILE IN.jsonl OUT.grc
//       What the app does before uploading; for tests.
import CryptoKit
import Foundation

let magic = Data("GLYPHRC1".utf8)
let info = Data("glyph-research-chunk-v1".utf8)
let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
func key(_ path: String) -> Data {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else {
        fail("\(path) is not a base64 X25519 key")
    }
    return raw
}

let arguments = Array(CommandLine.arguments.dropFirst())
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
switch arguments.first {
case "keys":
    let publicURL = root.appendingPathComponent("keyboard/App/research-public-key.txt")
    let privateURL = root.appendingPathComponent("Config/research-private-key.txt")
    if FileManager.default.fileExists(atPath: privateURL.path), !arguments.contains("--force") {
        fail("\(privateURL.path) exists. Chunks already uploaded can only be opened with it; pass --force to replace it anyway.")
    }
    let pair = Curve25519.KeyAgreement.PrivateKey()
    try (pair.rawRepresentation.base64EncodedString() + "\n").write(to: privateURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
    try (pair.publicKey.rawRepresentation.base64EncodedString() + "\n").write(to: publicURL, atomically: true, encoding: .utf8)
    print("public key  -> \(publicURL.path)\nprivate key -> \(privateURL.path)  (back this up; it is not in git)")
case "open":
    guard arguments.count >= 4 else { fail("open PRIVATE_KEY_FILE OUT_DIR CHUNK.grc...") }
    let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: key(arguments[1]))
    let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var opened = 0
    for path in arguments.dropFirst(3) {
        let url = URL(fileURLWithPath: path)
        do {
            let sealed = try Data(contentsOf: url)
            guard sealed.count > magic.count + 32, sealed.prefix(magic.count) == magic else { throw CocoaError(.fileReadCorruptFile) }
            let encapsulated = sealed.dropFirst(magic.count).prefix(32)
            var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: suite, info: info, encapsulatedKey: Data(encapsulated))
            let compressed = try recipient.open(Data(sealed.dropFirst(magic.count + 32)))
            let plain = try (compressed as NSData).decompressed(using: .zlib) as Data
            try plain.write(to: out.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".jsonl"), options: .atomic)
            opened += 1
        } catch {
            FileHandle.standardError.write(Data("cannot open \(path): \(error.localizedDescription)\n".utf8))
        }
    }
    print("opened \(opened) of \(arguments.count - 3) chunks into \(out.path)")
    if opened != arguments.count - 3 { exit(1) }
case "seal":
    guard arguments.count == 4 else { fail("seal PUBLIC_KEY_FILE IN.jsonl OUT.grc") }
    let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: key(arguments[1]))
    let plain = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    let compressed = try (plain as NSData).compressed(using: .zlib) as Data
    var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: suite, info: info)
    let ciphertext = try sender.seal(compressed)
    try (magic + sender.encapsulatedKey + ciphertext).write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
default:
    fail("usage: chunks.swift keys [--force] | open PRIVATE_KEY_FILE OUT_DIR CHUNK.grc... | seal PUBLIC_KEY_FILE IN.jsonl OUT.grc")
}
