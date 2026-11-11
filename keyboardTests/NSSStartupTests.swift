import Foundation
import Testing
@testable import keyboard

// NSS is the only English decoder: the engine is ready once the extension's bundled dictionary
// and model have loaded, and without the model there is no decoder at all, so the keyboard
// types without suggestions or autocorrect. Reads the extension's own bundled files, so it
// runs wherever the host app embeds it.
@MainActor
struct NSSStartupTests {
	private func extensionResource(_ name: String) throws -> URL {
		let appex = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("demo_keyboard.appex"))
		return appex.appendingPathComponent(name)
	}

	/// Decodes run on the engine queue behind its startup, so this returns after startup too.
	private func decode(_ engine: KeyboardEngine, _ word: String) async -> DecodeSnapshot {
		let request = DecodeRequest(fieldRevision: 1, documentRevision: 1, wordSessionID: 1,
			generation: 1, layoutRevision: 1, currentWord: word, context: [], taps: nil)
		return await withCheckedContinuation { continuation in
			engine.decode(request) { continuation.resume(returning: $0) }
		}
	}

	@Test func bundledModelMakesTheEngineReady() async throws {
		let engine = KeyboardEngine(languageDataURL: try extensionResource("langdata.bin"),
			neuralWordModelURL: try extensionResource("nss-english.nsslm"))
		let snapshot = await decode(engine, "teh")
		#expect(engine.neuralWordModel != nil)
		#expect(engine.isReady)
		#expect(!snapshot.candidates.isEmpty)
		#expect(snapshot.suggestions.contains("the"))
	}

	@Test func unloadableModelLeavesTheWordAsTyped() async throws {
		let engine = KeyboardEngine(languageDataURL: try extensionResource("langdata.bin"),
			neuralWordModelURL: try extensionResource("missing.nsslm"))
		let snapshot = await decode(engine, "teh")
		#expect(engine.neuralWordModel == nil)
		#expect(!engine.isReady)
		#expect(snapshot.suggestions == ["teh"])
		#expect(snapshot.candidates.isEmpty)
		#expect(snapshot.correction == nil)
	}
}
