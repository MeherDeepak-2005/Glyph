import Foundation
import Darwin

/// Opt-in research data, separate from aggregate diagnostics (docs/typing-recorder.md).
/// The keyboard extension and the app's practice screen write events here; nothing in this
/// file transmits. The app's research uploader takes sealed chunks from `sealedChunks`.
/// Commit events are observations, NEVER supervised labels by themselves.
enum KBTypingRecorder {
    struct Candidate: Codable {
        var word: String
        var score: Double?
        var spatialCost: Double?
        var logLanguageProbability: Double?
        var neuralLogProbability: Double?
        var typedWordMargin: Double?
        var source: String
    }
    /// One letter of a word as it was typed: the key, its landing offset in key pitches
    /// (clamped to ±1), and the gap to the previous key. Erased letters are removed, so a
    /// committed word's keystrokes line up with its typed literal.
    struct Keystroke: Codable {
        var key: String
        var dx: Double?
        var dy: Double?
        var intervalMs: Double?
    }
    /// One Glide gesture, whatever became of it.
    struct Glide: Codable {
        /// Every touch sample, lift point included: [x, y, ms since the first sample, touch
        /// radius], in keyboard-view points (the `layout` event gives the key rectangles).
        var path: [[Double]]
        var startKey: String?
        /// committed | rejected (the decoder matched nothing) | cancelled (the system took the
        /// touch) | dropped (the host text moved before the word could be inserted).
        var outcome: String
        /// Which decode produced the committed word: preview (the word shown under the finger),
        /// cache, session or final.
        var source: String?
        var previews: Int?
        var liftToInsertMs: Double?
        var truncated: Bool?
    }
    struct Key: Codable {
        var label: String
        var x: Double, y: Double, w: Double, h: Double
    }
    /// The keyboard's geometry for one `layout` revision: taps and Glide paths are only
    /// comparable within it.
    struct Layout: Codable {
        var width: Double, height: Double
        var xPitch: Double, yPitch: Double
        var keys: [Key]
        var page: String
        var profile: String
        var screenWidth: Double, screenHeight: Double, screenScale: Double
    }
    /// First line of every chunk: who and what produced it. `install` is a random ID made
    /// when research was first enabled; `profile` is what the tester chose to say about
    /// themselves (KBTypingRecorder.profile).
    struct Header: Codable {
        var install: String
        var appVersion: String
        var build: String
        var device: String
        var system: String
        var locale: String
        var profile: [String: String]?
    }
    /// A practice prompt shown by the app: `target` is what the tester was asked to enter.
    struct Prompt: Codable {
        var id: String
        var target: String
        var mode: String
        var result: String?
    }
    /// Schema 3 (docs/typing-recorder.md) adds chunk headers, keyboard geometry, absolute
    /// touch points, Glide gestures, correction outcomes and practice prompts to schema 2.
    struct Event: Codable {
        var schema = 3
        var id = UUID().uuidString
        var time = Date()
        var uptime: Double
        var process: String
        var session: UInt64
        var word: UInt64
        var relatedWord: UInt64?
        var layout: UInt64
        var kind: String
        var text: String?
        var replacement: String?
        var evidence: String?
        var candidates: [String]?
        var dx: Double?
        var dy: Double?
        var x: Double?
        var y: Double?
        var radius: Double?
        var touchID: String?
        var intervalMs: Double?
        var sinceMs: Double?
        var typed: String?
        var keystrokes: [Keystroke]?
        var durationMs: Double?
        var backspaces: Int?
        var confidence: Double?
        var candidateEvidence: [Candidate]?
        var glide: Glide?
        var geometry: Layout?
        var header: Header?
        var prompt: Prompt?
        var model: String
        var requestedModel: String?
        var language: String
        var build: String
    }
    static let maxGlideSamples = 1_500
    private static let queue = DispatchQueue(label: "keyboard.typing-records", qos: .utility)
    private static let admission = NSLock()
    private static var pending = 0
    private static var buffer: [(Event, String, UInt64)] = [] // queue-owned
    private static var scheduled = false
    private static let chunkBytes = 1_024 * 1_024               // the active file is sealed at this size
    private static let outboxBytes = 200 * 1_024 * 1_024        // sealed chunks waiting for upload
    private static let retention: TimeInterval = 30 * 86_400
    private static let enabledKey = "kb.typing.capture"
    private static let generationKey = "kb.typing.generation"
    private static let installKey = "kb.research.install"
    private static let profileKey = "kb.research.profile"
    static let processID = UUID().uuidString
    static var enabled: Bool { KBSettings.sharedDefaults.bool(forKey: enabledKey) }
    private static var generation: String { KBSettings.sharedDefaults.string(forKey: generationKey) ?? "initial" }
    private static var directory: URL? { KBPersonalData.containerURL?.appendingPathComponent("typing-recordings", isDirectory: true) }
    private static func outbox(_ dir: URL) -> URL { dir.appendingPathComponent("outbox", isDirectory: true) }
    private enum Failure: Error { case unavailable, lock, disabled }

    /// A random ID for this install's research data. It exists only while research has been
    /// enabled at least once, and "Delete all keyboard data" removes it.
    static var installID: String? { KBSettings.sharedDefaults.string(forKey: installKey) }
    /// What the tester chose to tell us (nickname, handedness, thumbs); written into chunk headers.
    static var profile: [String: String] {
        get { KBSettings.sharedDefaults.dictionary(forKey: profileKey) as? [String: String] ?? [:] }
        set {
            let bounded = newValue.filter { $0.key.count <= 32 && $0.value.count <= 64 }
            if bounded.isEmpty { KBSettings.sharedDefaults.removeObject(forKey: profileKey) }
            else { KBSettings.sharedDefaults.set(bounded, forKey: profileKey) }
        }
    }

    /// File lock is fail-closed: reset/export/writes never proceed without serialization.
    private static func locked<T>(_ body: () throws -> T) throws -> T {
        guard let root = KBPersonalData.containerURL else { throw Failure.unavailable }
        let fd = open(root.appendingPathComponent(".typing-recordings.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.lock }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.lock }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    static func setEnabled(_ value: Bool) {
        do {
            try locked {
                KBSettings.sharedDefaults.set(UUID().uuidString, forKey: generationKey)
                if value, installID == nil { KBSettings.sharedDefaults.set(UUID().uuidString, forKey: installKey) }
                KBSettings.sharedDefaults.set(value, forKey: enabledKey)
            }
        } catch { KBDiagnostics.noteIntegrityEvent("capture-control-failed") }
    }

    private static func valid(_ event: Event) -> Bool {
        func finite(_ values: Double?...) -> Bool { values.allSatisfy { $0?.isFinite ?? true } }
        guard event.uptime.isFinite,
              finite(event.dx, event.dy, event.x, event.y, event.radius, event.intervalMs, event.sinceMs, event.durationMs, event.confidence),
              (event.text?.count ?? 0) <= 64, (event.replacement?.count ?? 0) <= 64,
              (event.typed?.count ?? 0) <= 64, (event.keystrokes?.count ?? 0) <= 64,
              (event.candidates?.count ?? 0) <= 3,
              event.candidates?.allSatisfy({ $0.count <= 64 }) != false else { return false }
        if let glide = event.glide {
            guard glide.path.count <= maxGlideSamples, finite(glide.liftToInsertMs), (glide.startKey?.count ?? 0) <= 8,
                  glide.path.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }) else { return false }
        }
        if let geometry = event.geometry {
            guard geometry.keys.count <= 128, geometry.keys.allSatisfy({ $0.label.count <= 16 && finite($0.x, $0.y, $0.w, $0.h) }),
                  finite(geometry.width, geometry.height, geometry.xPitch, geometry.yPitch,
                         geometry.screenWidth, geometry.screenHeight, geometry.screenScale) else { return false }
        }
        if let prompt = event.prompt {
            guard prompt.id.count <= 64, prompt.target.count <= 256, prompt.mode.count <= 16, (prompt.result?.count ?? 0) <= 512 else { return false }
        }
        return true
    }

    static func record(_ event: Event) {
        let token = generation, epoch = KBPersonalData.currentEpoch
        guard enabled else { return }
        guard valid(event) else {
            KBDiagnostics.noteIntegrityEvent("capture-invalid-event-drop")
            return
        }
        admission.lock()
        guard pending < 512 else {
            admission.unlock()
            KBDiagnostics.noteIntegrityEvent("capture-backpressure-drop")
            return
        }
        pending += 1
        admission.unlock()
        queue.async {
            buffer.append((event, token, epoch))
            if buffer.count >= 32 { writeBuffer() }
            if !scheduled {
                scheduled = true
                queue.asyncAfter(deadline: .now() + 0.5) {
                    scheduled = false
                    writeBuffer()
                }
            }
        }
    }

    static func flush() { queue.async { writeBuffer() } }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func headerLine() throws -> Data {
        var system = utsname()
        uname(&system)
        let device = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let info = Bundle.main.infoDictionary
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let profile = self.profile
        let header = Header(install: installID ?? "unknown", appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: build, device: device, system: ProcessInfo.processInfo.operatingSystemVersionString,
            locale: Locale.current.identifier, profile: profile.isEmpty ? nil : profile)
        var data = try encoder().encode(Event(uptime: ProcessInfo.processInfo.systemUptime, process: processID,
            session: 0, word: 0, layout: 0, kind: "header", header: header, model: "none", language: "english", build: build))
        data.append(0x0A)
        return data
    }

    private static func writeBuffer() {
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        defer {
            admission.lock(); pending -= batch.count; admission.unlock()
        }
        do {
            try locked {
                guard enabled, let dir = directory else { return }
                let token = generation, epoch = KBPersonalData.currentEpoch
                var data = Data()
                let encoder = encoder()
                for (event, capturedToken, capturedEpoch) in batch where capturedToken == token && capturedEpoch == epoch {
                    data.append(try encoder.encode(event)); data.append(0x0A)
                }
                guard !data.isEmpty else { return }
                try prepareDirectory(dir)
                let current = dir.appendingPathComponent("current.jsonl")
                if fileSize(current) + data.count > chunkBytes { try seal(dir) }
                if !FileManager.default.fileExists(atPath: current.path) {
                    try (headerLine() + data).write(to: current, options: protectedWriteOptions)
                } else {
                    let handle = try FileHandle(forWritingTo: current)
                    defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: data)
                }
            }
        } catch { KBDiagnostics.noteIntegrityEvent("capture-write-failed") }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Chunk names sort by sealing time: milliseconds since 1970, zero-padded, then a random suffix.
    private static func chunkName(at date: Date = Date()) -> String {
        String(format: "%014lld-%@.jsonl", Int64(date.timeIntervalSince1970 * 1_000), String(UUID().uuidString.prefix(8)))
    }

    /// Moves the active file (and a schema-2 `previous.jsonl`) into the outbox, then enforces
    /// the outbox's age and size limits, oldest chunk first. Call under `locked`.
    private static func seal(_ dir: URL) throws {
        let box = outbox(dir)
        try prepareDirectory(box)
        for (name, date) in [("previous.jsonl", Date().addingTimeInterval(-1)), ("current.jsonl", Date())] {
            let url = dir.appendingPathComponent(name)
            guard fileSize(url) > 0 else { continue }
            try FileManager.default.moveItem(at: url, to: box.appendingPathComponent(chunkName(at: date)))
        }
        // A shared export is a second copy of the text; it does not outlive the hour it was made in.
        let export = dir.appendingPathComponent("export.jsonl")
        if let made = try? export.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(made) > 3_600 { try? FileManager.default.removeItem(at: export) }
        var chunks = try sealed(dir)
        let oldest = Int64((Date().timeIntervalSince1970 - retention) * 1_000)
        var total = chunks.reduce(0) { $0 + fileSize($1) }
        while let first = chunks.first, total > outboxBytes || (Int64(first.lastPathComponent.prefix(14)) ?? .max) < oldest {
            total -= fileSize(first)
            try FileManager.default.removeItem(at: first)
            chunks.removeFirst()
            KBDiagnostics.noteIntegrityEvent("capture-outbox-drop")
        }
    }

    private static func sealed(_ dir: URL) throws -> [URL] {
        let box = outbox(dir)
        guard FileManager.default.fileExists(atPath: box.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: box, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static var protectedWriteOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }
    private static func prepareDirectory(_ url: URL) throws {
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Invalidates queued events before deletion. Removing records also stops collection.
    @discardableResult static func clear() -> Bool {
        do {
            try locked {
                KBSettings.sharedDefaults.set(false, forKey: enabledKey)
                KBSettings.sharedDefaults.set(UUID().uuidString, forKey: generationKey)
                if let dir = directory, FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.removeItem(at: dir)
                }
            }
            return true
        } catch {
            KBDiagnostics.noteIntegrityEvent("capture-delete-failed")
            return false
        }
    }

    // MARK: The uploader's side (the app)

    /// Sealed chunks, oldest first. `sealingCurrent` first seals the active file, so everything
    /// recorded so far is in the list; the next event starts a new file with its own header.
    static func sealedChunks(sealingCurrent: Bool) -> [URL] {
        queue.sync {
            writeBuffer()
            do {
                return try locked {
                    guard let dir = directory, FileManager.default.fileExists(atPath: dir.path) else { return [] }
                    if sealingCurrent { try seal(dir) }
                    return try sealed(dir)
                }
            } catch {
                KBDiagnostics.noteIntegrityEvent("capture-outbox-failed")
                return []
            }
        }
    }

    /// Removes one sealed chunk (after it was uploaded). False when it could not be removed.
    @discardableResult static func discard(chunk: URL) -> Bool {
        do {
            return try locked {
                guard let dir = directory, chunk.deletingLastPathComponent().standardizedFileURL == outbox(dir).standardizedFileURL else { return false }
                try FileManager.default.removeItem(at: chunk)
                return true
            }
        } catch {
            KBDiagnostics.noteIntegrityEvent("capture-outbox-failed")
            return false
        }
    }

    /// Recorded data still on this device: sealed chunks and bytes, the active file included.
    static func stored() -> (chunks: Int, bytes: Int) {
        (try? locked { () -> (chunks: Int, bytes: Int) in
            guard let dir = directory else { return (0, 0) }
            let chunks = try sealed(dir)
            return (chunks.count, chunks.reduce(fileSize(dir.appendingPathComponent("current.jsonl"))) { $0 + fileSize($1) })
        }) ?? (0, 0)
    }

    /// Produces a snapshot separate from the live recording; sharing it requires an explicit ShareLink action.
    static func export(completion: @escaping (URL?) -> Void) {
        queue.async {
            writeBuffer()
            let output: URL?
            do {
                output = try locked {
                    guard let dir = directory, FileManager.default.fileExists(atPath: dir.path) else { return nil }
                    let sources = (try sealed(dir) + [dir.appendingPathComponent("previous.jsonl"), dir.appendingPathComponent("current.jsonl")])
                        .filter { fileSize($0) > 0 }
                    guard !sources.isEmpty else { return nil }
                    let url = dir.appendingPathComponent("export.jsonl")
                    try Data().write(to: url, options: protectedWriteOptions)
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    for source in sources { try handle.write(contentsOf: Data(contentsOf: source, options: .mappedIfSafe)) }
                    return url
                }
            } catch {
                KBDiagnostics.noteIntegrityEvent("capture-export-failed")
                output = nil
            }
            DispatchQueue.main.async { completion(output) }
        }
    }
}
