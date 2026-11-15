#if RESEARCH_BETA
import BackgroundTasks
import CloudKit
import CryptoKit
import Foundation

/// Sends the typing recorder's sealed chunks to the research CloudKit container.
///
/// Only the app uploads; the keyboard extension only writes files. Every chunk is compressed
/// and then encrypted to the research public key bundled with the app (HPKE, X25519 +
/// ChaCha20-Poly1305), so what leaves the phone can be read only with the private key that
/// `tools/research/keys.swift` wrote beside the repository. Without a valid public key
/// nothing is uploaded: there is no plaintext path.
enum ResearchUploader {
    static let containerID = "iCloud.com.meherdeepak.glyph"
    static let refreshTaskID = "com.meherdeepak.glyph.research-upload"
    static let recordType = "TypingChunk"
    /// Sealed file layout: this magic, the 32-byte HPKE encapsulated key, then the ciphertext
    /// of the zlib-compressed JSONL. tools/research/open_chunks.swift reverses it.
    static let magic = Data("GLYPHRC1".utf8)
    static let info = Data("glyph-research-chunk-v1".utf8)

    struct Report {
        var uploaded = 0
        var waiting = 0
        var failure: String?
    }
    enum Failure: LocalizedError {
        case noPublicKey, compression
        var errorDescription: String? {
            switch self {
            case .noPublicKey: return "This build has no research key, so nothing can be uploaded."
            case .compression: return "A recording could not be prepared for upload."
            }
        }
    }

    private static let lastUploadKey = "kb.research.lastUpload"
    private static let lastDiagnosticsKey = "kb.research.lastDiagnostics"
    private static let gate = Gate()
    private actor Gate {
        var running = false
        func begin() -> Bool { if running { return false }; running = true; return true }
        func end() { running = false }
    }

    static var lastUpload: Date? {
        let value = KBSettings.sharedDefaults.double(forKey: lastUploadKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    /// The bundled research public key (base64 of the raw X25519 key), nil when missing or malformed.
    static var publicKey: Curve25519.KeyAgreement.PublicKey? {
        guard let url = Bundle.main.url(forResource: "research-public-key", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    static func seal(_ plaintext: Data, to key: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        guard let compressed = try? (plaintext as NSData).compressed(using: .zlib) as Data else { throw Failure.compression }
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info)
        let ciphertext = try sender.seal(compressed)
        return magic + sender.encapsulatedKey + ciphertext
    }

    /// Uploads everything recorded so far, oldest chunk first, and removes each chunk from the
    /// phone once CloudKit has it. Stops at the first failure; the rest waits for the next run.
    @discardableResult
    static func uploadPending() async -> Report {
        var report = Report()
        guard await gate.begin() else { return report }
        defer { Task { await gate.end() } }
        guard let install = KBTypingRecorder.installID else { return report }
        guard let key = publicKey else {
            report.failure = Failure.noPublicKey.localizedDescription
            return report
        }
        let database = CKContainer(identifier: containerID).publicCloudDatabase
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        var chunks = KBTypingRecorder.sealedChunks(sealingCurrent: true)
        if KBTypingRecorder.enabled, let diagnostics = diagnosticsChunk(install: install) { chunks.append(diagnostics) }
        report.waiting = chunks.count
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("research-upload", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for chunk in chunks {
            let name = chunk.deletingPathExtension().lastPathComponent
            let isDiagnostics = name.hasPrefix("diagnostics-")
            do {
                let plaintext = try Data(contentsOf: chunk, options: .mappedIfSafe)
                let sealedURL = scratch.appendingPathComponent(name + ".grc")
                try seal(plaintext, to: key).write(to: sealedURL, options: .atomic)   // already encrypted
                let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: "\(install)-\(name)"))
                record["install"] = install
                record["chunk"] = name
                record["bytes"] = plaintext.count
                record["schema"] = 3
                record["build"] = build
                record["data"] = CKAsset(fileURL: sealedURL)
                do {
                    _ = try await database.save(record)
                } catch let error as CKError where error.code == .serverRecordChanged {
                    // The same chunk was already saved by an earlier run that could not finish.
                }
                try? FileManager.default.removeItem(at: sealedURL)
                if isDiagnostics {
                    try? FileManager.default.removeItem(at: chunk)
                    KBSettings.sharedDefaults.set(Date().timeIntervalSince1970, forKey: lastDiagnosticsKey)
                } else {
                    KBTypingRecorder.discard(chunk: chunk)
                }
                report.uploaded += 1
                report.waiting -= 1
            } catch {
                if isDiagnostics { try? FileManager.default.removeItem(at: chunk) }
                report.failure = describe(error)
                break
            }
        }
        if report.uploaded > 0 { KBSettings.sharedDefaults.set(Date().timeIntervalSince1970, forKey: lastUploadKey) }
        return report
    }

    /// Once a day, the keyboard's aggregate counters (latency, memory, per-key error counts;
    /// no text) travel as one more chunk.
    private static func diagnosticsChunk(install: String) -> URL? {
        let last = KBSettings.sharedDefaults.double(forKey: lastDiagnosticsKey)
        guard Date().timeIntervalSince1970 - last > 86_400,
              let snapshot = try? JSONEncoder().encode(KBDiagnostics.read()),
              let object = try? JSONSerialization.jsonObject(with: snapshot) else { return nil }
        let day = ISO8601DateFormatter().string(from: Date())
        let line: [String: Any] = ["kind": "diagnostics", "schema": 3, "install": install, "time": day, "snapshot": object]
        guard let data = try? JSONSerialization.data(withJSONObject: line) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(Int(Date().timeIntervalSince1970)).jsonl")
        return (try? (data + Data([0x0A])).write(to: url, options: .atomic)) == nil ? nil : url
    }

    private static func describe(_ error: Error) -> String {
        guard let cloud = error as? CKError else { return error.localizedDescription }
        switch cloud.code {
        case .notAuthenticated: return "Sign in to iCloud on this iPhone to upload."
        case .networkUnavailable, .networkFailure: return "No connection. The recordings stay on this iPhone until the next try."
        case .quotaExceeded: return "The research storage is full."
        case .requestRateLimited, .serviceUnavailable, .zoneBusy: return "iCloud is busy. The recordings will go up later."
        default: return cloud.localizedDescription
        }
    }

    // MARK: Background refresh (best effort: iOS decides when, and rarely for an app that is seldom opened)

    private static var refreshPermitted: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])?.contains(refreshTaskID) == true
    }

    /// Call once, before the app finishes launching. Registering an identifier the Info.plist
    /// does not permit raises, so a build without it simply has no background upload.
    static func registerBackgroundRefresh() {
        guard refreshPermitted else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            scheduleBackgroundRefresh()
            let work = Task {
                let report = await uploadPending()
                task.setTaskCompleted(success: report.failure == nil)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleBackgroundRefresh() {
        guard refreshPermitted, KBTypingRecorder.enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3_600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
