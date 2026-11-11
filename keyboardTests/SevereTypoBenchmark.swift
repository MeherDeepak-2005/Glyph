import Foundation
import Testing
@testable import keyboard

/// Replays the project's severe-typo golden through the shipped decoder: the neural search
/// space over the repository's dictionary and model. No expected word is injected into
/// candidate generation or scores.
@MainActor
struct SevereTypoBenchmark {
    @Test func coeevitjknThroughTheNeuralSearchSpace() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let contexts: [[String]] = [[], ["auto"], ["possibly", "receive"],
            ["for", "definitely", "decided"], ["could", "definitely", "receive"]]
        var rows: [[String: Any]] = []
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
        }
        for context in contexts {
            let engine = KeyboardEngine(languageDataURL: root.appendingPathComponent("keyboard/langdata.bin"),
                neuralWordModelURL: root.appendingPathComponent("keyboard/nss-english.nsslm"))
            var timings: [Double] = [], snapshots: [DecodeSnapshot] = []
            for repetition in 0...30 {
                let request = DecodeRequest(fieldRevision: 1, documentRevision: UInt64(repetition + 1),
                    wordSessionID: 1, generation: UInt64(repetition + 1), layoutRevision: 1,
                    currentWord: "coeevitjkn", context: context, taps: nil)
                let start = ProcessInfo.processInfo.systemUptime
                let snapshot: DecodeSnapshot = await withCheckedContinuation { continuation in
                    engine.decode(request) { continuation.resume(returning: $0) }
                }
                timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                snapshots.append(snapshot)
            }
            #expect(engine.isReady)
            let last = try #require(snapshots.last)
            let warm = Array(timings.dropFirst())
            let rank = last.candidates.firstIndex { $0.word == "correction" }
            let evidence: [[String: Any]] = last.candidates.map {
                ["word": $0.word, "score": $0.score, "spatial_cost": $0.spatialCost,
                 "language_log_probability": $0.logLanguageProbability,
                 "source": $0.source.rawValue]
            }
            let row: [String: Any] = ["mode": "nss", "context": context,
                "suggestions": last.suggestions, "correction": last.correction as Any? ?? NSNull(),
                "correction_candidate_rank": rank.map { ($0 + 1) as Any } ?? NSNull(),
                "correct_commits": snapshots.filter { $0.correction == "correction" }.count,
                "replays": snapshots.count, "first_decode_ms": timings[0],
                "warm_p50_ms": percentile(warm, 0.5), "warm_p95_ms": percentile(warm, 0.95),
                "warm_p99_ms": percentile(warm, 0.99), "candidates": evidence]
            rows.append(row)
            print("SEVERE_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: row,
                options: [.sortedKeys]), as: UTF8.self))
            // Raw NSS keeps a typed non-word unless a completed word outscores it; nothing
            // near this severe typo does, in any of these contexts (the n-gram tier's broad
            // recovery committed "correction").
            #expect(snapshots.allSatisfy { $0.correction == nil })
            #expect(snapshots.allSatisfy { $0.suggestions.first == "coeevitjkn" })
        }
        let report: [String: Any] = ["typed": "coeevitjkn", "intended": "correction",
            "environment": "iOS simulator; no touch offsets; model load excluded; first decode includes queued engine initialization",
            "decoder": "nss (keyboard/nss-english.nsslm over keyboard/langdata.bin)", "rows": rows]
        let destination = root.appendingPathComponent("tools/evaluation/results")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("coeevitjkn-simulator.json"))
    }
}
