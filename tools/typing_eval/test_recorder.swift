import Foundation

// Standalone storage fixtures; the harness compiles the production recorder unchanged.
enum KBSettings { static let sharedDefaults = UserDefaults(suiteName: UUID().uuidString)! }
enum KBPersonalData {
    static var currentEpoch: UInt64 = 1
    static var containerURL: URL? { URL(fileURLWithPath: CommandLine.arguments[1]) }
}
enum KBDiagnostics { static func noteIntegrityEvent(_ code: String) { print("diagnostic: \(code)") } }

func sample(_ text: String = "a") -> KBTypingRecorder.Event {
    .init(uptime: 1, process: "fixture", session: 1, word: 1, layout: 1,
          kind: "key", text: text, model: "ngram", language: "english", build: "test")
}
func export() -> URL? {
    var done = false
    var result: URL?
    KBTypingRecorder.export { result = $0; done = true }
    let until = Date().addingTimeInterval(5)
    while !done && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(done, "export timed out")
    return result
}

@main struct RecorderTests {
    static func main() throws {
        runHostEditTests()
        runCPUProbeTests()
        KBTypingRecorder.record(sample())
        precondition(export() == nil, "default must be off")
        KBTypingRecorder.setEnabled(true)
        for _ in 0..<35 { KBTypingRecorder.record(sample()) }
        let first = try Data(contentsOf: export()!)
        precondition(first.split(separator: 10).count == 35)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(KBTypingRecorder.Event.self, from: Data(first.split(separator: 10)[0]))
        precondition(decoded.text == "a" && decoded.schema == 2)
        KBTypingRecorder.record(sample("queued-before-clear"))
        precondition(KBTypingRecorder.clear())
        precondition(export() == nil && !KBTypingRecorder.enabled, "queued text must not resurrect")
        KBTypingRecorder.setEnabled(true)
        KBTypingRecorder.record(sample("old-epoch"))
        KBPersonalData.currentEpoch += 1
        precondition(export() == nil, "old model epoch must not write")
        KBTypingRecorder.record(sample(String(repeating: "x", count: 65)))
        precondition(export() == nil, "oversized records must be rejected")
        KBTypingRecorder.record(sample())
        _ = export()
        let current = KBPersonalData.containerURL!.appendingPathComponent("typing-recordings/current.jsonl")
        try Data(repeating: 32, count: 5 * 1024 * 1024).write(to: current)
        KBTypingRecorder.record(sample("rotation"))
        _ = export()
        let previous = current.deletingLastPathComponent().appendingPathComponent("previous.jsonl")
        let previousData = try Data(contentsOf: previous), currentData = try Data(contentsOf: current)
        precondition(previousData.count == 5 * 1024 * 1024)
        precondition(currentData.count < 4096)
        precondition(KBTypingRecorder.clear())
        precondition(!FileManager.default.fileExists(atPath: current.deletingLastPathComponent().path))
        print("PASS: opt-in, JSON round trip, ordered flush, delete invalidation, epoch invalidation, bounds, rotation, export deletion")
    }
}
