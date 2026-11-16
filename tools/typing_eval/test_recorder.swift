import Foundation

enum KBSettings { static let sharedDefaults = UserDefaults(suiteName: UUID().uuidString)! }
enum KBPersonalData {
    static var currentEpoch: UInt64 = 1
    static var containerURL: URL? { URL(fileURLWithPath: CommandLine.arguments[1]) }
}
enum KBDiagnostics {
    static var events: [String] = []
    static func noteIntegrityEvent(_ code: String) { events.append(code) }
}

func check(_ condition: Bool, _ message: String = "", line: UInt = #line) {
    if !condition { fatalError("line \(line): \(message)") }
}
func sample(_ text: String = "a", kind: String = "key") -> KBTypingRecorder.Event {
    .init(uptime: 1, process: "fixture", session: 1, word: 1, layout: 1,
          kind: kind, text: text, model: "nss", language: "english", build: "test")
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
func events(_ url: URL) throws -> [KBTypingRecorder.Event] {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try Data(contentsOf: url).split(separator: 10).map { try decoder.decode(KBTypingRecorder.Event.self, from: Data($0)) }
}

@main struct RecorderTests {
    static func main() throws {
        let dir = KBPersonalData.containerURL!.appendingPathComponent("typing-recordings")
        let current = dir.appendingPathComponent("current.jsonl")

        KBTypingRecorder.record(sample())
        check(export() == nil && KBTypingRecorder.installID == nil, "default must be off")
        check(KBTypingRecorder.sealedChunks(sealingCurrent: true).isEmpty)

        KBTypingRecorder.profile = ["hand": "right", "thumbs": "two"]
        KBTypingRecorder.setEnabled(true)
        let install = KBTypingRecorder.installID
        check(install != nil)
        for index in 0..<35 { KBTypingRecorder.record(sample("w\(index)")) }
        let first = try events(export()!)
        check(first.count == 36 && first[0].kind == "header" && first[0].schema == 3)
        check(first[0].header?.install == install && first[0].header?.profile?["hand"] == "right")
        check(first.dropFirst().map(\.text) == (0..<35).map { "w\($0)" })

        var glide = sample("hello", kind: "glide")
        glide.glide = .init(path: [[1, 2, 0, 9.5], [3.5, 4, 8.3, 10]], startKey: "h", outcome: "committed", source: "preview",
                            previews: 4, liftToInsertMs: 2.5, truncated: nil)
        glide.confidence = 1.25
        var layout = sample("", kind: "layout")
        layout.geometry = .init(width: 390, height: 216, xPitch: 39, yPitch: 54, keys: [.init(label: "q", x: 3, y: 4, w: 33, h: 42)],
                                page: "letters", profile: "phone", screenWidth: 390, screenHeight: 844, screenScale: 3)
        var prompt = sample("", kind: "prompt-done")
        prompt.prompt = .init(id: "p1", target: "see you tomorrow", mode: "glide", result: "see you tomorrow")
        for event in [glide, layout, prompt] { KBTypingRecorder.record(event) }
        let rich = try events(export()!).suffix(3)
        check(rich.map(\.kind) == ["glide", "layout", "prompt-done"])
        check(rich.first?.glide?.path.count == 2 && rich.first?.glide?.path[1][2] == 8.3)
        check(rich.dropFirst().first?.geometry?.keys.first?.label == "q" && rich.last?.prompt?.target == "see you tomorrow")
        KBDiagnostics.events.removeAll()
        var tooLong = glide
        tooLong.glide?.path = Array(repeating: [0, 0, 0, 0], count: KBTypingRecorder.maxGlideSamples + 1)
        var malformed = glide
        malformed.glide?.path = [[0, 0, 0]]
        var notFinite = glide
        notFinite.glide?.path = [[0, .nan, 0, 0]]
        for event in [tooLong, malformed, notFinite, sample(String(repeating: "x", count: 65))] { KBTypingRecorder.record(event) }
        check(KBDiagnostics.events == Array(repeating: "capture-invalid-event-drop", count: 4))
        check(try events(export()!).count == 39, "invalid events must not be written")

        KBTypingRecorder.record(sample("queued-before-clear"))
        check(KBTypingRecorder.clear())
        check(export() == nil && !KBTypingRecorder.enabled, "queued text must not resurrect")
        check(!FileManager.default.fileExists(atPath: dir.path))

        KBTypingRecorder.setEnabled(true)
        KBTypingRecorder.record(sample("old-epoch"))
        KBPersonalData.currentEpoch += 1
        check(export() == nil, "old model epoch must not write")

        KBTypingRecorder.record(sample("before-seal"))
        _ = export()
        let handle = try FileHandle(forWritingTo: current)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 32, count: 1_024 * 1_024)); try handle.close()
        KBTypingRecorder.record(sample("after-seal"))
        var chunks = KBTypingRecorder.sealedChunks(sealingCurrent: false)
        check(try chunks.count == 1 && Data(contentsOf: chunks[0]).count > 1_024 * 1_024)
        let fresh = try events(current)
        check(fresh.map(\.kind) == ["header", "key"] && fresh[1].text == "after-seal")
        check(KBTypingRecorder.stored().chunks == 1)

        chunks = KBTypingRecorder.sealedChunks(sealingCurrent: true)
        check(chunks.count == 2 && chunks.map(\.lastPathComponent) == chunks.map(\.lastPathComponent).sorted())
        check(!FileManager.default.fileExists(atPath: current.path))
        check(try events(chunks[1]).last?.text == "after-seal")
        check(!KBTypingRecorder.discard(chunk: current), "only outbox chunks can be discarded")
        check(KBTypingRecorder.discard(chunk: chunks[0]) && KBTypingRecorder.sealedChunks(sealingCurrent: false).count == 1)
        KBTypingRecorder.record(sample("next-chunk"))
        let next = try events(export()!)
        check(next.filter { $0.kind == "header" }.count == 2 && next.last?.text == "next-chunk", "export joins the outbox and the active file")

        KBTypingRecorder.setEnabled(false)
        KBTypingRecorder.record(sample("while-off"))
        check(try events(export()!).last?.text == "next-chunk")
        check(KBTypingRecorder.clear() && KBTypingRecorder.stored() == (0, 0))
        print("PASS: opt-in, header and install ID, ordered flush, schema 3 round trip and bounds, delete and epoch invalidation, chunk sealing, outbox, export")
    }
}
