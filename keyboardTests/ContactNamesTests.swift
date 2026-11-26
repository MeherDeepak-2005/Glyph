import Foundation
import Testing
@testable import keyboard

@MainActor
struct ContactNamesTests {
	private func resource(_ name: String) -> URL {
		URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("keyboard/\(name)")
	}

	private func makeEngine() -> KeyboardEngine {
		KeyboardEngine(languageDataURL: resource("langdata.bin"), neuralWordModelURL: resource("nss-english.nsslm"))
	}

	private func decode(_ engine: KeyboardEngine, _ word: String, context: [String] = ["hi"]) async -> DecodeSnapshot {
		let request = DecodeRequest(fieldRevision: 1, documentRevision: 1, wordSessionID: 1, generation: 1,
			layoutRevision: 1, currentWord: word, context: context, taps: nil)
		return await withCheckedContinuation { continuation in
			engine.decode(request) { continuation.resume(returning: $0) }
		}
	}

	@Test func namesAreSplitIntoLatinTokens() {
		#expect(KBContactNames.tokens(from: ["Meher Deepak", "O'Brien", "Jean-Luc", "రాము", "meher", "J", "Zoë"])
			== ["Meher", "Deepak", "O'Brien", "Jean", "Luc", "Zoë"])
	}

	@Test func contactNamesAreKeptAndCapitalized() async {
		let engine = makeEngine()
		engine.importContactNames(["Meher", "Deepak", "Sravya"])
		for name in ["Meher", "Deepak", "Sravya"] {
			let typedLower = await decode(engine, name.lowercased())
			#expect(typedLower.correction == name, "\(name.lowercased()) became \(typedLower.correction ?? "nil")")
			#expect(typedLower.suggestions.first == name)
			let typedCapital = await decode(engine, name)
			#expect(typedCapital.correction == nil)
			#expect(typedCapital.suggestions.first == name)
		}
	}

	@Test func dictionaryWordsInContactsStayOrdinaryWords() async {
		let engine = makeEngine()
		engine.importContactNames(["Will", "Rose", "Grace", "Nenu", "Meher", "Krishna"])
		let will = await decode(engine, "will", context: ["i"])
		#expect(will.correction == nil)
		#expect(!will.suggestions.contains("Will"))
		for word in ["will", "rose", "grace", "nenu"] { #expect(engine.isCommonWord(word), "\(word)") }
		for name in ["meher", "krishna", "deepak", "ravi", "sravya"] { #expect(!engine.isCommonWord(name), "\(name)") }
	}
}
