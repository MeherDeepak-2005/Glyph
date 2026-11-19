import Foundation
import Testing
@testable import keyboard

/// Roman Telugu typed on the English keyboard (keyboard/tenglish_guard.bin).
@MainActor
struct TenglishGuardTests {
	private func langdataURL() -> URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("keyboard/langdata.bin")
	}

	private func decode(_ engine: KeyboardEngine, word: String, context: [String])
		async -> DecodeSnapshot {
		let request = DecodeRequest(fieldRevision: 1, documentRevision: 1,
			wordSessionID: 1, generation: 1, layoutRevision: 1,
			currentWord: word, context: context, taps: nil)
		return await withCheckedContinuation { continuation in
			engine.decode(request) { continuation.resume(returning: $0) }
		}
	}

	@Test func guardListHoldsTeluguWordsAndLeavesEnglishOut() {
		let list = TeluguLexicon.tenglishGuard
		#expect(list.isAvailable)
		#expect(list.vocabularyCount == 20_000)
		for word in ["nenu", "meeru", "idi", "ledu", "kuda", "chala", "ela", "enti", "ani", "oka", "em"] {
			#expect(list.contains(word), "\(word) should be a known Tenglish word")
		}
		// Common English words, slips and misspellings of them, and English loanwords.
		for word in ["the", "to", "and", "may", "hot", "menu", "teh", "adn", "wnat", "becuase",
			"recieve", "ti", "cinema", "commitee"] {
			#expect(!list.contains(word), "\(word) belongs to English")
		}
	}

	@Test func tenglishWordsAreKeptAsTyped() async {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		for word in ["nenu", "ela", "enti", "kuda", "ani", "em", "chala"] {
			for context in [[], ["i", "told", "him"], ["nenu"]] {
				let snapshot = await decode(engine, word: word, context: context)
				#expect(snapshot.correction == nil, "\(word) after \(context) became \(snapshot.correction ?? "")")
				#expect(snapshot.suggestions.first == word)
				// No spelling corrections: anything beside it extends what was typed.
				#expect(snapshot.suggestions.dropFirst().allSatisfy { $0.hasPrefix(word) },
					"\(word) after \(context) offered \(snapshot.suggestions)")
			}
		}
	}

	@Test func tenglishKeepsTheTypedCase() async {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let snapshot = await decode(engine, word: "Nenu", context: [])
		#expect(snapshot.correction == nil)
		#expect(snapshot.suggestions.first == "Nenu")
	}

	@Test func englishTyposAreStillCorrected() async {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		for (typo, fix) in [("teh", "the"), ("becuase", "because"), ("recieve", "receive"),
			("thier", "their"), ("adn", "and"), ("freind", "friend")] {
			#expect(!engine.isGuardedTenglish(typo))
			let snapshot = await decode(engine, word: typo, context: ["i", "think"])
			#expect(snapshot.correction == fix, "\(typo) became \(snapshot.correction ?? "nil")")
			#expect(snapshot.suggestions.first == fix)
		}
	}

	@Test func teluguCompletionsComeLateAndNeverDisplaceEnglish() {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		// A known word loses its spelling corrections; Telugu completions take the free slots.
		let (guarded, decision, confidence) = engine.applyTenglishGuard(typed: "cheppa",
			shown: "cheppa", suggestions: ["cheap", "cheppa", "chapman"], decision: "cheap",
			confidence: 4)
		#expect(decision == nil)
		#expect(confidence == 0)
		#expect(guarded.first == "cheppa")
		#expect(guarded.count == 3)
		#expect(guarded.dropFirst().allSatisfy { $0.hasPrefix("cheppa") && $0 != "cheppa" })

		// A full English strip is left exactly as it was, decision included.
		let english = ["vast", "vastly", "vasta"]
		let (kept, keptDecision, _) = engine.applyTenglishGuard(typed: "vasta", shown: "vasta",
			suggestions: english, decision: "vast", confidence: 4)
		#expect(kept == english)
		#expect(keptDecision == "vast")

		// Room in the strip: completions are appended after English, not before.
		let (filled, _, _) = engine.applyTenglishGuard(typed: "vasta", shown: "vasta",
			suggestions: ["vasta"], decision: nil, confidence: 0)
		#expect(filled.first == "vasta")
		#expect(filled.count == 3)

		// Only once most of the word is typed.
		#expect(engine.tenglishCompletions(of: "che", limit: 3).isEmpty)
		for word in engine.tenglishCompletions(of: "chepp", limit: 3) {
			#expect(word.hasPrefix("chepp") && Double("chepp".count) >= 0.6 * Double(word.count))
		}
	}
}
