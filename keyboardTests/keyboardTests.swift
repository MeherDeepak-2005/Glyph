import Foundation
import Testing
import UIKit
@testable import keyboard

@MainActor
struct KeyboardTests {
    @Test func emojiBinaryContainsSearchAliases() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let cryingEmoji = try #require(store.emoji(forWord: "cry"))

        #expect(store.emoji(forWord: "sob") == cryingEmoji)
        #expect(store.emoji(forWord: "sobbing") == cryingEmoji)
        #expect(store.search("cry").first == cryingEmoji)
        #expect(store.search("sob").first == cryingEmoji)
    }

    @Test func emojiSearchAvoidsSubstringNoise() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let happyResults = store.search("happy")
        let rainResults = store.search("rain")

        #expect(happyResults.first == "😊")
        #expect(!happyResults.contains("😢"))
        #expect(!happyResults.contains("😭"))
        #expect(!rainResults.contains("🧠"))
        #expect(!rainResults.contains("🚆"))
    }

    @Test func emojiSearchUsesGeneratedUnicodeKeywords() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let umbrellaResults = store.search("umbrella")

        #expect(umbrellaResults.contains("☂️") || umbrellaResults.contains("🌂"))
        #expect(store.search("umb").contains("☂️") || store.search("umb").contains("🌂"))
    }

    @Test func emojiBinaryProvidesDisplayCatalog() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))

        #expect(store.categoryCount > 0)
        #expect(!store.name(0).isEmpty)
        #expect(!store.icon(0).isEmpty)
        #expect(store.emojiCount(0) > 0)
        #expect(!store.emoji(0, 0).isEmpty)
    }

    private func emojiBinaryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("keyboard/emoji.bin")
    }

    private func langdataURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("keyboard/langdata.bin")
    }

	private func keyboardResourceURL(_ name: String) -> URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("keyboard/\(name)")
	}

	private func makeEngine(userModel: UserModel? = nil) -> KeyboardEngine {
		KeyboardEngine(languageDataURL: langdataURL(),
			neuralWordModelURL: keyboardResourceURL("nss-english.nsslm"), userModel: userModel)
	}

	@Test func bundledLanguageDataUsesUnigramOnlyV7() throws {
		let url = langdataURL()
		let data = try #require(LangData(url: url))
		let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
		#expect(data.nativeCandidateLexicon.formatVersion == 7)
		#expect(bytes <= 32_000_000)
		#expect(data.wordCount == 187_462)
	}

	@Test func suggestionCasePolicyOwnsDisplayTapAndCorrectionText() throws {
		func present(typed: String, suggestions: [String], correction: String?,
			sentenceStart: Bool = false) -> PresentedDecodeSnapshot {
			let request = DecodeRequest(fieldRevision: 1, documentRevision: 1,
				wordSessionID: 1, generation: 1, layoutRevision: 1,
				currentWord: typed, context: [], taps: nil)
			let snapshot = DecodeSnapshot(request: request, suggestions: suggestions,
				candidates: [], correction: correction, confidence: 1,
				nextCharacterPriors: [:], completedAtUptime: 1)
			return SuggestionCasePolicy.present(snapshot, sentenceStart: sentenceStart)
		}

		for (typed, expected) in [("mgiht", "might"), ("Mgiht", "Might"),
			("MGIHT", "MIGHT")] {
			let result = present(typed: typed, suggestions: ["might", "night"],
				correction: "might")
			#expect(result.primaryText == expected)
			#expect(result.correction == expected)
		}
		let mixed = present(typed: "McDonald", suggestions: ["mcdonald"],
			correction: nil)
		#expect(mixed.primaryText == "McDonald")
		#expect(mixed.suggestions.first?.isExactTypedCandidate == true)

		let sentence = present(typed: "", suggestions: ["hello", "i'm", "i'll"],
			correction: nil, sentenceStart: true)
		#expect(sentence.suggestions.map(\.text) == ["Hello", "I'm", "I'll"])
		let pronoun = present(typed: "i", suggestions: ["i"], correction: nil)
		#expect(pronoun.primaryText == "I")
	}

	@MainActor @Test func suggestionPassThroughBoundaryDoesNotMoveKeyGeometry() throws {
		for width: CGFloat in [320, 390, 440] {
			let bar = SuggestionBar(theme: .system(dark: true))
			bar.frame = CGRect(x: 0, y: 0, width: width, height: 32)
			bar.setSuggestions(["one", "two", "three"], highlightPrimary: true)
			bar.layoutIfNeeded()
			#expect(bar.point(inside: CGPoint(x: width / 2, y: 27.9), with: nil))
			#expect(!bar.point(inside: CGPoint(x: width / 2, y: 28), with: nil))
			let primary = try #require(suggestionButton("suggestion.primary", in: bar))
			#expect(primary.frame.minY == 0)
			#expect(primary.frame.height == 32)
			#expect(primary.accessibilityTraits.contains(.selected))
		}
	}

	@Test func klipyRequestContainsOnlyExplicitMediaQuery() throws {
		let url = try #require(KlipyClient.requestURL(apiKey: "test-key_1", kind: .gifs,
			query: "  Telugu reaction  ", page: 2))
		let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
		let fields = Dictionary(uniqueKeysWithValues:
			(components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
		#expect(url.scheme == "https")
		#expect(url.path == "/api/v1/test-key_1/gifs/search")
		#expect(fields == ["page": "2", "per_page": "20", "q": "Telugu reaction"])
		let trending = try #require(KlipyClient.requestURL(apiKey: "key", kind: .gifs, query: nil, page: 1))
		#expect(trending.path == "/api/v1/key/gifs/trending")
		let trendingFields = Dictionary(uniqueKeysWithValues:
			(URLComponents(url: trending, resolvingAgainstBaseURL: false)?.queryItems ?? [])
				.map { ($0.name, $0.value ?? "") })
		#expect(trendingFields == ["page": "1", "per_page": "20"])
		#expect(KlipyClient.requestURL(apiKey: "key", kind: .stickers, query: " ", page: 1)?.path
			== "/api/v1/key/stickers/trending")
		#expect(KlipyClient.requestURL(apiKey: "bad/key", kind: .gifs, query: "hi", page: 1) == nil)
	}

	@Test func klipyParserRejectsUnsafeAndMalformedMedia() throws {
		let json = """
		{"data":{"has_next":true,"data":[
		 {"id":7,"title":"Hello","file":{"sm":{
		   "webp":{"url":"https://cdn.example/preview.webp","width":240,"height":180},
		   "gif":{"url":"https://cdn.example/send.gif","width":240,"height":180}}}},
		 {"id":8,"title":"Unsafe","file":{"sm":{
		   "webp":{"url":"http://cdn.example/preview.webp","width":240,"height":180},
		   "gif":{"url":"http://cdn.example/send.gif","width":240,"height":180}}}}
		]}}
		"""
		let parsed = KlipyClient.parse(Data(json.utf8))
		#expect(parsed.0.count == 1)
		#expect(parsed.0.first?.id == "7")
		#expect(parsed.0.first?.sendURL.scheme == "https")
		#expect(parsed.1)
		#expect(KlipyClient.parse(Data("not-json".utf8)).0.isEmpty)
	}

	@MainActor @Test func mediaPanelLoadsTrendingOnOpen() {
		let panel = MediaPanelView(theme: .system(dark: true), showsGlobe: false,
			hasFullAccess: false, kind: .gifs)
		let labels = recursiveSubviews(panel).compactMap { ($0 as? UILabel)?.text }
		#expect(labels.contains(where: { $0.contains("Full Access is required") }))
		#expect(!labels.contains(where: { $0.contains("Search GIFs to browse") }))
	}

	@MainActor @Test func mediaPanelDeniesSearchedMediaWithoutFullAccess() {
		let panel = MediaPanelView(theme: .system(dark: true), showsGlobe: false,
			hasFullAccess: false, kind: .gifs, query: "reaction")
		let labels = recursiveSubviews(panel).compactMap { ($0 as? UILabel)?.text }
		#expect(labels.contains(where: { $0.contains("Full Access") }))
	}

	@Test func progressAccountingIsDeterministicAndProvisionalGlideCanCancel() throws {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
		let first = try #require(calendar.date(from: DateComponents(
			year: 2026, month: 7, day: 18, hour: 12)))
		let second = try #require(calendar.date(byAdding: .day, value: 1, to: first))
		var data = KBStatsData()
		KBStats.apply(words: 2, glided: false, on: &data, date: first, calendar: calendar)
		KBStats.apply(words: 1, glided: true, on: &data, date: second, calendar: calendar)
		#expect(data.totalTyped == 2)
		#expect(data.totalGlided == 1)
		#expect(data.currentStreak == 2)
		let pending = KBStats.noteProvisional(glided: true)
		#if DEBUG
		#expect(KBStats.isProvisionalForTesting(pending))
		#endif
		KBStats.cancel(pending)
		#if DEBUG
		#expect(!KBStats.isProvisionalForTesting(pending))
		#endif
	}

	@MainActor private func recursiveSubviews(_ view: UIView) -> [UIView] {
		view.subviews + view.subviews.flatMap(recursiveSubviews)
	}

    @Test func contractionsAreRealWordsInStaticTrie() async throws {
        let ld = try #require(LangData(url: langdataURL()))
        for w in ["what's", "don't", "it's", "can't", "you're", "would've"] {
            #expect(ld.trieContains(w), "\(w) missing from static trie")
        }
        let snapshot = await decode(makeEngine(), word: "what's", context: [])
        let selfHit = snapshot.candidates.first { $0.word == "what's" }
        #expect(try #require(selfHit).spatialCost == 0)
        #expect(snapshot.correction == nil)
    }

    @MainActor @Test func renderSuggestionBar() throws {
		let bar = SuggestionBar(theme: .system(dark: false))
		bar.frame = CGRect(x: 0, y: 0, width: 390, height: 32)
        bar.backgroundColor = UIColor(hex: 0xE8E6EC)
        bar.setSuggestions(["hello", "help", "hell"], typedPrefix: "hel")
        bar.layoutIfNeeded()
        try writePNG(of: bar, name: "suggestion_bar_plain")

        let tools = try #require(bar.subviews.first {
            $0.accessibilityIdentifier == "suggestion.tools" } as? UIButton)
        tools.sendActions(for: .touchUpInside)
        bar.layoutIfNeeded()
        #expect(bar.showingTools)
        try writePNG(of: bar, name: "suggestion_bar_tools")
    }

    @MainActor @Test func renderKeyDeck() throws {
        for dark in [false, true] {
            let deck = KeyboardView(theme: .system(dark: dark), showsGlobe: false)
            deck.frame = CGRect(x: 0, y: 0, width: 393, height: deck.keyboardHeight)
            deck.backgroundColor = dark ? UIColor(hex: 0x2A2A2E) : UIColor(hex: 0xE8E6EC)
            deck.layoutIfNeeded()
            try writePNG(of: deck, name: dark ? "key_deck_dark" : "key_deck_light")
        }

        let search = KeyboardView(theme: .system(dark: true), showsGlobe: false)
        search.setActionEnabled(false)
        search.showMedia(kind: .gifs, hasFullAccess: true)
        search.frame = CGRect(x: 0, y: 0, width: 393, height: search.keyboardHeight)
        search.layoutIfNeeded()
        func all(_ view: UIView) -> [UIView] { view.subviews + view.subviews.flatMap(all) }
        let open = try #require(all(search).first {
            $0.accessibilityIdentifier == "media.search" } as? UIButton)
        open.sendActions(for: .touchUpInside)
        search.frame.size.height = search.keyboardHeight
        search.backgroundColor = UIColor(hex: 0x2A2A2E)
        search.layoutIfNeeded()
        try writePNG(of: search, name: "media_search_gifs")
    }

    @MainActor @Test func glideSuggestionPresentationStaysSynchronized() throws {
		let bar = SuggestionBar(theme: .system(dark: true))
		bar.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        bar.setSuggestions(["this", "thus", "might"])
        bar.setGlideResult("Might", alternatives: ["Night", "Right", "Light"])

        let left = try #require(suggestionButton("suggestion.left", in: bar))
        let primary = try #require(suggestionButton("suggestion.primary", in: bar))
        let right = try #require(suggestionButton("suggestion.right", in: bar))
        #expect(left.title(for: .normal) == "Night")
        #expect(primary.title(for: .normal) == "Might")
        #expect(right.title(for: .normal) == "Right")
        #expect(!primary.isEnabled)

		bar.setGlidePreview("More", alternatives: ["Move", "Mode"])
		#expect(left.title(for: .normal) == "Move")
		#expect(primary.title(for: .normal) == "More")
		#expect(right.title(for: .normal) == "Mode")
        bar.setGlidePreview(nil)
        #expect(left.title(for: .normal) == "Night")
        #expect(primary.title(for: .normal) == "Might")
        #expect(right.title(for: .normal) == "Right")
    }

    @Test func glideDisplayCaseCapitalizesOnlyWhenRequested() {
        #expect(KBWordCase.sentenceDisplay("might", capitalized: true) == "Might")
        #expect(KBWordCase.sentenceDisplay("might", capitalized: false) == "might")
        #expect(KBWordCase.sentenceDisplay("i'm", capitalized: true) == "I'm")
        #expect(KBWordCase.sentenceDisplay("", capitalized: true).isEmpty)
    }

	private static let capturedGlidePath: [CGPoint] = ([
		(0.998, -0.035), (1.495, -0.073), (1.991, -0.013), (2.484, 0.07), (2.98, 0.126), (3.479, 0.166),
		(3.978, 0.19), (4.477, 0.216), (4.977, 0.244), (5.472, 0.306), (5.959, 0.411), (5.548, 0.471),
		(5.049, 0.505), (4.553, 0.562), (4.057, 0.626), (3.565, 0.717), (3.073, 0.804), (2.579, 0.885),
		(2.082, 0.93), (1.583, 0.947), (1.083, 0.947), (0.628, 0.947), (1.108, 0.821), (1.568, 0.625),
		(2.048, 0.484), (2.528, 0.344), (3.007, 0.202), (3.487, 0.061), (3.975, -0.046), (4.464, -0.151),
		(4.056, -0.127), (3.57, -0.013), (3.105, 0.173), (2.638, 0.351), (2.171, 0.528), (1.766, 0.822),
		(1.444, 1.202), (1.371, 1.248),
	] as [(Double, Double)]).map { CGPoint(x: $0.0, y: $0.1) }

	private func gridLayout() -> GlideLayout {
		let centers: [(letter: Character, point: CGPoint)] = KB.rows.joined().compactMap { letter in
			guard let ascii = letter.asciiValue, let grid = KB.pos[ascii] else { return nil }
			return (letter, CGPoint(x: grid.0, y: grid.1))
		}
		return GlideLayout(centers: centers, xPitch: 1, yPitch: 1)
	}

    @MainActor @Test func exactGlidePreviewCommitsSynchronouslyWithSameWinner() async throws {
        let layout = gridLayout()
		let path = Self.capturedGlidePath
		let times: [TimeInterval] = []
		let engine = makeEngine()
        let preview = await withCheckedContinuation { continuation in
            engine.glidePreview(path: path, times: times, layout: layout, context: []) {
                continuation.resume(returning: $0)
            }
        }
        let live = try #require(preview)

        var methodReturned = false
        var deliveredInline = false
        var finalWord: String?
        engine.glide(path: path, times: times, layout: layout, context: []) { word, _ in
            deliveredInline = !methodReturned
            finalWord = word
        }
        methodReturned = true

        #expect(deliveredInline)
        #expect(finalWord == live.word)
    }

	@MainActor @Test func streamingGlideUsesMonotonicSessionAndOneFinalRanking() async throws {
		let layout = gridLayout()
		let path = Self.capturedGlidePath
		let engine = makeEngine()
		let session = engine.beginGlideSession(context: [])
		let midpoint = max(2, path.count / 2)
		let first = await withCheckedContinuation { continuation in
			engine.updateGlideSession(session, path: Array(path.prefix(midpoint)), times: [],
				layout: layout) { continuation.resume(returning: $0) }
		}
		let second = await withCheckedContinuation { continuation in
			engine.updateGlideSession(session, path: path, times: [], layout: layout) {
				continuation.resume(returning: $0)
			}
		}
		let firstUpdate = try #require(first)
		let finalUpdate = try #require(second)
		#expect(finalUpdate.sessionID == firstUpdate.sessionID)
		#expect(finalUpdate.revision > firstUpdate.revision)

		let final = await withCheckedContinuation { continuation in
			engine.finishGlideSession(session, path: path, times: [], layout: layout) { word, alternatives in
				continuation.resume(returning: (word, alternatives))
			}
		}
		#expect(final.0 == finalUpdate.prediction.word)
	}

	@MainActor private func suggestionButton(_ id: String, in bar: SuggestionBar) -> UIButton? {
		bar.subviews
			.compactMap { $0 as? UIButton }
			.first { $0.accessibilityIdentifier == id }
	}

	@MainActor @Test func visualLetterCentersMatchSpatialModel() throws {
		let keyboard = KeyboardView(theme: .system(dark: false), showsGlobe: false)
		keyboard.frame = CGRect(x: 0, y: 0, width: 390, height: keyboard.keyboardHeight)
		keyboard.layoutIfNeeded()
		let q = try #require(keyboard.letterCenter(for: "q"))
		let w = try #require(keyboard.letterCenter(for: "w"))
		let a = try #require(keyboard.letterCenter(for: "a"))
		let z = try #require(keyboard.letterCenter(for: "z"))
		let pitch = w.x - q.x
		#expect(abs((a.x - q.x) / pitch - CGFloat(KB.rowOffset[1])) < 0.001)
		#expect(abs((z.x - q.x) / pitch - CGFloat(KB.rowOffset[2])) < 0.001)
	}

	@Test func layoutProfilesCoverSupportedFormFactors() {
		#expect(KeyboardLayoutMetrics.resolve(width: 320, idiom: .phone).profile == .compactPhone)
		#expect(KeyboardLayoutMetrics.resolve(width: 390, idiom: .phone).profile == .phone)
		#expect(KeyboardLayoutMetrics.resolve(width: 440, idiom: .phone).profile == .largePhone)
		#expect(KeyboardLayoutMetrics.resolve(width: 700, idiom: .phone).profile == .landscapePhone)
		#expect(KeyboardLayoutMetrics.resolve(width: 700, idiom: .pad).profile == .pad)
	}

	@MainActor @Test func fieldSpecificLayoutsExposeExpectedKeys() {
		let keyboard = KeyboardView(theme: .system(dark: false), showsGlobe: false)
		keyboard.frame = CGRect(x: 0, y: 0, width: 390, height: keyboard.keyboardHeight)
		keyboard.layoutIfNeeded()

		keyboard.setInputKind(.email)
		let email = Set(keyboard.keyAccessibilityLabels())
		#expect(email.contains("@") && email.contains("."))

		keyboard.setInputKind(.url)
		let url = Set(keyboard.keyAccessibilityLabels())
		#expect(url.contains("/") && url.contains("."))

		keyboard.setInputKind(.numberPad)
		let numeric = Set(keyboard.keyAccessibilityLabels())
		#expect(numeric.contains("0") && numeric.contains("9"))
		#expect(!numeric.contains("Q"))
	}

	@Test func decodeIdentityRejectsEveryStaleRevision() {
		func request(field: UInt64 = 1, document: UInt64 = 2, word: UInt64 = 3,
					 generation: UInt64 = 4, layout: UInt64 = 5,
					 current: String = "might", context: [String] = ["they"]) -> DecodeRequest {
			DecodeRequest(fieldRevision: field, documentRevision: document,
				wordSessionID: word, generation: generation, layoutRevision: layout,
				currentWord: current, context: context, taps: nil)
		}
		let base = request()
		let snapshot = DecodeSnapshot(request: base, suggestions: ["might"], candidates: [],
			correction: nil, confidence: 0, nextCharacterPriors: [:],
			completedAtUptime: 1)
		#expect(snapshot.isValid(for: base))
		#expect(!snapshot.isValid(for: request(field: 2)))
		#expect(!snapshot.isValid(for: request(document: 3)))
		#expect(!snapshot.isValid(for: request(word: 4)))
		#expect(!snapshot.isValid(for: request(generation: 5)))
		#expect(!snapshot.isValid(for: request(layout: 6)))
		#expect(!snapshot.isValid(for: request(current: "night")))
		#expect(!snapshot.isValid(for: request(context: ["at"])))
	}

	@Test func wordNeuralSearchSpaceDecodesInTheSharedEngine() async throws {
		let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("native/tests/fixtures/nss/cifg-tied.nsslm")
		let engine = KeyboardEngine(languageDataURL: langdataURL(), neuralWordModelURL: fixture)
		_ = await decode(engine, word: "hel", context: [])
		#expect(engine.isReady)
		let tiny = await decode(engine, word: "teh", context: ["i", "saw"])
		let shipped = await decode(makeEngine(), word: "teh", context: ["i", "saw"])
		#expect(!tiny.candidates.isEmpty)
		#expect(tiny.candidates.map(\.logLanguageProbability) != shipped.candidates.map(\.logLanguageProbability))
		let prediction = await decode(engine, word: "", context: ["i", "saw"])
		#expect(!prediction.suggestions.isEmpty)
		let plain = KeyboardEngine(languageDataURL: langdataURL(), neuralWordModelURL: nil)
		let typed = await decode(plain, word: "hel", context: [])
		#expect(!plain.isReady)
		#expect(typed.suggestions == ["hel"])
		#expect(typed.correction == nil)
	}

	@Test func suffixReplacementStopsAtTheSamePrefixForGraphemeAndScalarHosts() throws {
		let original = "Before అంతే "
		let plan = try #require(HostSuffixReplacementPlan(
			contextBeforeInput: original, suffix: "అంతే ", replacement: "anthe"))
		#expect(plan.prefix == "Before ")

		var graphemeHost = original
		var graphemeDeletes = 0
		while plan.state(for: graphemeHost) == .deleteBackward {
			graphemeHost.removeLast()
			graphemeDeletes += 1
		}
		#expect(plan.state(for: graphemeHost) == .readyToInsert)
		#expect(graphemeHost + plan.replacement == "Before anthe")
		#expect(graphemeDeletes < plan.maximumDeleteCount)

		var scalarHost = original
		var scalarDeletes = 0
		while plan.state(for: scalarHost) == .deleteBackward {
			var scalars = scalarHost.unicodeScalars
			scalars.removeLast()
			scalarHost = String(scalars)
			scalarDeletes += 1
			#expect(scalarDeletes <= plan.maximumDeleteCount)
		}
		#expect(plan.state(for: scalarHost) == .readyToInsert)
		#expect(scalarHost + plan.replacement == "Before anthe")
	}

	private func applyPlan(_ plan: HostSuffixReplacementPlan, host: String)
		-> (ok: Bool, host: String) {
		var host = host
		let ok = plan.apply(initialContext: host,
			deleteBackward: {
				host.removeLast()
				return host.isEmpty ? nil : host
			},
			insert: { host += $0 })
		return (ok, host)
	}

	@Test func suffixReplacementCompletesWhenTheFieldEmptiesForAFirstWord() throws {
		let pick = try #require(HostSuffixReplacementPlan(
			contextBeforeInput: "Helo", suffix: "Helo", replacement: "Hello "))
		#expect(pick.prefix == "")
		let picked = applyPlan(pick, host: "Helo")
		#expect(picked.ok)
		#expect(picked.host == "Hello ")

		let undo = try #require(HostSuffixReplacementPlan(
			contextBeforeInput: "Hello ", suffix: "Hello ", replacement: "Helo"))
		#expect(undo.prefix == "")
		let reverted = applyPlan(undo, host: "Hello ")
		#expect(reverted.ok)
		#expect(reverted.host == "Helo")
	}

	@Test func suffixReplacementStillReplacesAWordThatFollowsOtherText() throws {
		let plan = try #require(HostSuffixReplacementPlan(
			contextBeforeInput: "foo helo", suffix: "helo", replacement: "hello "))
		#expect(plan.prefix == "foo ")
		let result = applyPlan(plan, host: "foo helo")
		#expect(result.ok)
		#expect(result.host == "foo hello ")
	}

	@Test func diagnosticsSnapshotDecodesLegacyDataAndComputesBenchmarkRatios() throws {
		let legacy = #"{"updated":0,"warningCount":2,"criticalCount":0,"peakFootprintMB":18.5,"minAvailableMB":40,"limitMB":58.5}"#
		let old = try JSONDecoder().decode(KBDiagnostics.Snapshot.self, from: Data(legacy.utf8))
		#expect(old.warningCount == 2)
		#expect(old.peakFootprintMB == 18.5)
		#expect(old.wordsCommitted == nil)
		#expect(old.physicalTaps == nil)
		#expect(old.peakCPUPercent == nil)
		#expect(old.initLatencyBins == nil)

		var snap = KBDiagnostics.Snapshot()
		snap.wordsCommitted = 100
		snap.wordsModified = 7
		snap.wordsAutocorrected = 22
		snap.correctionsReverted = 3
		snap.nwpOpportunities = 40
		snap.nwpHits = 18
		snap.activeTypingMs = 120_000
		snap.committedChars = 520
		snap.physicalTaps = 430
		snap.peakCPUPercent = 63.5
		snap.initLatencyBins = [0, 1, 2, 3]
		let round = try JSONDecoder().decode(KBDiagnostics.Snapshot.self,
			from: JSONEncoder().encode(snap))
		#expect(round.wordsCommitted == 100)
		#expect(round.nwpHits == 18)
		#expect(round.physicalTaps == 430)
		#expect(round.peakCPUPercent == 63.5)
		#expect(round.initLatencyBins == [0, 1, 2, 3])

		#expect(abs(Double(round.wordsModified!) / Double(round.wordsCommitted!) - 0.07) < 1e-9)
		#expect(abs(Double(round.nwpHits!) / Double(round.nwpOpportunities!) - 0.45) < 1e-9)
		#expect(abs(Double(round.wordsCommitted!) / (round.activeTypingMs! / 60_000) - 50) < 1e-9)
		#expect(Double(round.physicalTaps!) / Double(round.committedChars!) < 1.0)
	}

	@Test func commercialPolicyRejectsCashRewardedAdsAndUnsafeClicks() throws {
		let rewardedCash = CommercialCampaign(id: "cash-ad", title: "Cash",
			subtitle: "", merchantID: nil, interest: nil, source: .rewardedAd,
			reward: .cashback, destination: nil)
		#expect(!rewardedCash.isPolicyCompatible)

		let affiliate = CommercialCampaign(id: "merchant-offer", title: "Offer",
			subtitle: "", merchantID: "merchant", interest: .shopping,
			source: .affiliate, reward: .cashback, destination: nil)
		#expect(affiliate.isPolicyCompatible)
		let valid = AuthenticatedOfferClick(campaignID: affiliate.id,
			merchantID: "merchant",
			oneTimeToken: "one-time", destination: URL(string: "https://merchant.example")!,
			expiresAt: .now.addingTimeInterval(60))
		#expect(try valid.validated(for: affiliate).scheme == "https")

		let unsafe = AuthenticatedOfferClick(campaignID: affiliate.id,
			merchantID: "merchant",
			oneTimeToken: "one-time", destination: URL(string: "http://merchant.example")!,
			expiresAt: .now.addingTimeInterval(60))
		#expect(throws: CommercialPolicyError.self) { try unsafe.validated(for: affiliate) }
	}

	@Test func touchProfileLearnsBoundedRowOffsetsWithoutRawHistory() throws {
		let suite = "touch-profile-tests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let profile = TouchSpatialProfile(defaults: defaults)
		let sample = KeyTap(dx: 0.18, dy: -0.12)
		for _ in 0..<8 {
			profile.observe(word: "asdf", taps: Array(repeating: sample, count: 4),
				defaults: defaults)
		}
		let adjusted = try #require(profile.adjusted([Optional(sample)], typed: "a"))
		let value = try #require(adjusted[0])
		#expect(abs(value.dx) < 0.02)
		#expect(abs(value.dy) < 0.02)
		profile.reset(defaults: defaults)
		let reset = try #require(profile.adjusted([Optional(sample)], typed: "a"))
		#expect(reset[0] == sample)
	}

	@Test func shippedVocabularyCoversContractionsAndCurrentRegister() throws {
		let data = try #require(LangData(url: langdataURL()))
		#expect(data.wordCount >= 60_000)
		for word in ["should've", "shouldn't've", "might've", "prolly", "idk",
					 "rizz", "doomscrolling", "situationship", "haptic"] {
			#expect(data.trieContains(word), "\(word) is missing from langdata.bin")
		}
	}

	@Test func expandedEnglishFormsReachTheTrie() throws {
		let data = try #require(LangData(url: langdataURL()))
		for word in ["colour", "favourite", "organise", "travelling", "cancelled",
			"reproducibility", "epistemology", "hermeneutics", "unsubscribed",
			"screenshots", "livestreaming", "brb", "ttyl", "tysm", "covid",
			"passkeys", "prepone", "bengaluru"] {
			#expect(data.trieContains(word), "expanded vocabulary missing: \(word)")
		}
		for word in ["dont", "im", "youre", "cant"] {
			#expect(!data.trieContains(word))
		}
	}

	@Test func expandedEnglishLiteralWordsAreNotDestructivelyCorrected() async {
		let engine = makeEngine()
		for word in ["colour", "favourite", "organise", "brb", "ttyl", "tysm",
			"screenshots", "passkeys", "epistemology", "bengaluru"] {
			let snapshot = await decode(engine, word: word, context: [])
			#expect(snapshot.correction == nil || snapshot.correction == word,
				"\(word) replaced by \(snapshot.correction ?? "nil")")
			#expect(snapshot.suggestions.contains(word), "literal missing: \(word)")
		}
	}

	@Test func coldStartDoesNotSurfaceCorpusCharacterNames() async {
		let engine = makeEngine()
		let snapshot = await decode(engine, word: "", context: [])
		#expect(!snapshot.suggestions.map { $0.lowercased() }.contains("tom"))
	}

	@Test func multiwordAndSevereGoldensUseOneAuthoritativeRanking() async {
		let engine = makeEngine()
		let split = await decode(engine, word: "thisbis", context: [])
		#expect(split.suggestions.first == "this is")
		#expect(split.correction == "this is")
		let severe = await decode(engine, word: "coeevitjkn", context: [])
		#expect(severe.suggestions.first == "coeevitjkn")
		#expect(severe.correction == nil)
	}

	@Test func suggestionPrimaryAndCorrectionShareOneDecision() async throws {
		let engine = makeEngine()
		for (typed, context) in [("might", ["they"]), ("whats", ["you", "know"]),
								   ("teh", ["in"]), ("prolly", ["i"])] {
			let snapshot = await decode(engine, word: typed, context: context)
			if let correction = snapshot.correction {
				#expect(snapshot.suggestions.first?.caseInsensitiveCompare(correction) == .orderedSame)
			}
			#expect(snapshot.correction?.lowercased() != "night" || typed != "might")
		}
	}

	@Test func personalizationRollbackReversesALearnedUse() {
		let user = UserModel()
		user.learn(word: "might")
		user.learn(word: "might")
		#expect(user.uniCount("might") == 2)
		user.demote("might")
		#expect(user.uniCount("might") == 1)
		user.demote("might")
		#expect(user.uniCount("might") == 0)
		#expect(user.unigramsSnapshot()["might"] == nil)
	}

	@Test func personalWordsRequireExplicitAdoptionEvidence() throws {
		let lexicon = Lexicon()
		lexicon.load(from: langdataURL())
		let spelling = "qzvaxon"
		#expect(!lexicon.contains(spelling))
		lexicon.noteUse(of: spelling, timesUsed: 20, adoptAfter: 8, allowAdoption: false)
		#expect(!lexicon.contains(spelling))
		lexicon.noteUse(of: spelling, timesUsed: 8, adoptAfter: 8, allowAdoption: true)
		#expect(lexicon.contains(spelling))
	}

	@Test func unknownWordsAdoptAfterSixteenUsesOrEightWithAConfirmedSpelling() throws {
		let storage = FileManager.default.temporaryDirectory
			.appendingPathComponent("adoption-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: storage) }
		let engine = makeEngine(userModel: UserModel(storageURL: storage))
		engine.initializationGroup.wait()
		func use(_ word: String, times: Int) {
			for _ in 0..<times { engine.learn(word: word) }
			engine.queue.sync {}
		}
		use("qzvaxon", times: 15)
		#expect(!engine.lexicon.contains("qzvaxon"))
		use("qzvaxon", times: 1)
		#expect(engine.lexicon.contains("qzvaxon"))

		engine.dontCorrect("zqvoxan")
		use("zqvoxan", times: 7)
		#expect(!engine.lexicon.contains("zqvoxan"))
		use("zqvoxan", times: 1)
		#expect(engine.lexicon.contains("zqvoxan"))

		use("helo", times: 40)
		#expect(!engine.lexicon.contains("helo"))
		#expect(!engine.allowsPersonalAdoption(of: "helo", count: 40))
	}
	@Test func userModelPersistsAndRecoversFromCorruption() throws {
		let root = FileManager.default.temporaryDirectory
		let validURL = root.appendingPathComponent("user-model-\(UUID().uuidString).json")
		let corruptURL = root.appendingPathComponent("user-model-\(UUID().uuidString).json")
		defer {
			try? FileManager.default.removeItem(at: validURL)
			try? FileManager.default.removeItem(at: corruptURL)
		}
		let writer = UserModel(storageURL: validURL)
		writer.learn(word: "might")
		writer.save()
		writer.waitForPendingIO()
		let reader = UserModel(storageURL: validURL)
		reader.load()
		#expect(reader.uniCount("might") == 1)

		try Data("not-json".utf8).write(to: corruptURL)
		let corrupt = UserModel(storageURL: corruptURL)
		corrupt.load()
		#expect(corrupt.uniCount("might") == 0)
		#expect(!FileManager.default.fileExists(atPath: corruptURL.path))
	}

	@Test func userModelRewritesVersionTwoFilesAsUnigramOnly() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("user-model-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: url) }
		let legacy = #"{"version":2,"tri":{"they really":{"might":1}},"bi":{"really":{"might":2}},"uni":{"might":3},"confirmed":{"qzvaxon":1}}"#
		try Data(legacy.utf8).write(to: url)
		let model = UserModel(storageURL: url)
		model.load()
		model.waitForPendingIO()
		#expect(model.uniCount("might") == 3)
		let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
		#expect(stored["version"] as? Int == 3)
		#expect(stored["bi"] == nil && stored["tri"] == nil)
		#expect((stored["uni"] as? [String: Int]) == ["might": 3])
		#expect((stored["confirmed"] as? [String: Int]) == ["qzvaxon": 1])
	}

	@Test func glideTransformIsAffineAcrossRows() throws {
		let pitchX: CGFloat = 31
		let pitchY: CGFloat = 43
		let origin = CGPoint(x: 17, y: 9)
		let centers: [(letter: Character, point: CGPoint)] = KB.rows.joined().compactMap { letter in
			guard let ascii = letter.asciiValue, let grid = KB.pos[ascii] else { return nil }
			return (letter, CGPoint(x: origin.x + CGFloat(grid.0) * pitchX,
				y: origin.y + CGFloat(grid.1) * pitchY))
		}
		let layout = GlideLayout(centers: centers, xPitch: pitchX, yPitch: pitchY)
		for sample in centers {
			let mapped = GlidePreprocess.toGrid(sample.point, layout: layout)
			let expected = try #require(sample.letter.asciiValue.flatMap { KB.pos[$0] })
			#expect(abs(Double(mapped.x) - expected.0) < 1e-6)
			#expect(abs(Double(mapped.y) - expected.1) < 1e-6)
		}
		let a = GlidePreprocess.toGrid(CGPoint(x: 100, y: 80), layout: layout)
		let b = GlidePreprocess.toGrid(CGPoint(x: 100.1, y: 80.1), layout: layout)
		#expect(abs(b.x - a.x) < 0.01 && abs(b.y - a.y) < 0.01)
	}

	@Test func approvedAccentRolesMeetTextContrast() {
		for accent in KBPalette.all {
			let pair = KBCustomThemePair.defaults(accent: accent)
			for custom in [pair.light, pair.dark] {
				let theme = KeyboardTheme.custom(custom)
				#expect(KeyboardTheme.contrastRatio(theme.accentKeyText, theme.accentStart) >= 4.5)
				#expect(KeyboardTheme.contrastRatio(theme.accentKeyText, theme.accentEnd) >= 4.5)
			}
		}
	}

	@Test func emojiSkinToneVariantsUseUnicodeModifiers() {
		let variants = KBEmojiVariants.skinToneVariants(of: "👍")
		#expect(variants.count == 5)
		#expect(variants.allSatisfy { $0 != "👍" })
		#expect(KBEmojiVariants.skinToneVariants(of: "👍🏽").isEmpty)
		#expect(KBEmojiVariants.skinToneVariants(of: "🚗").isEmpty)
	}

	@MainActor @Test func emojiCategoryHighlightFollowsEveryTap() async throws {
		let store = try #require(EmojiStore.bundled ?? EmojiStore(url: emojiBinaryURL()))
		let palette = EmojiKeyboardView(theme: .system(dark: true), showsGlobe: false,
			store: store)
		palette.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
		palette.layoutIfNeeded()
		let tabs = recursiveSubviews(palette).compactMap { view -> (Int, UIButton)? in
			guard let button = view as? UIButton,
				  let identifier = button.accessibilityIdentifier,
				  identifier.hasPrefix("emoji.category."),
				  let index = Int(identifier.dropFirst("emoji.category.".count)) else { return nil }
			return (index, button)
		}.sorted { $0.0 < $1.0 }
		#expect(tabs.count >= 3)
		#expect(tabs.allSatisfy { $0.1.buttonType == .custom })

		for target in [2, 1] {
			tabs[target].1.sendActions(for: .touchUpInside)
			#expect(tabs[target].1.accessibilityTraits.contains(.selected))
			await Task.yield()
			palette.layoutIfNeeded()
			#expect(tabs[target].1.isSelected)
			#expect((tabs[target].1.backgroundColor?.cgColor.alpha ?? 0) <= 0.08)
			for (index, button) in tabs where index != target {
				#expect(!button.isSelected)
				#expect(!button.accessibilityTraits.contains(.selected))
			}
		}
	}

	@MainActor @Test func panelHeaderArmsLayOutTheirSwitch() throws {
		for style in PanelHeaderStyle.allCases {
			let header = PanelHeaderView(theme: .system(dark: false), selected: .gifs, style: style)
			header.frame = CGRect(x: 0, y: 0, width: 390, height: header.height)
			header.layoutIfNeeded()
			let views = recursiveSubviews(header)
			let search = try #require(views.compactMap { $0 as? UIButton }
				.first { $0.accessibilityIdentifier == "media.search" })
			let tabs = ["emoji", "gifs", "stickers"].compactMap { id in
				views.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "panel.tab.\(id)" }
			}
			#expect(tabs.map { $0.accessibilityLabel } == ["Emoji", "GIFs", "Stickers"])
			#expect(tabs[1].accessibilityTraits.contains(.selected))
			let track = try #require(tabs[0].superview)
			let trackFrame = track.convert(track.bounds, to: header)
			switch style {
			case .unified:
				#expect(header.height == 44)
				#expect(search.frame == CGRect(x: 8, y: 3, width: 374, height: 38))
				#expect(trackFrame.width == 118)
				#expect(trackFrame.maxX == search.frame.maxX - 3)
				#expect(trackFrame.midY == search.frame.midY)
				#expect(tabs[0].image(for: .normal) != nil && tabs[2].image(for: .normal) != nil)
				#expect(tabs[1].title(for: .normal) == "GIF")
				#expect((search.configuration?.contentInsets.trailing ?? 0) >= 118)
			case .stacked:
				#expect(header.height == 86)
				#expect(search.frame == CGRect(x: 8, y: 6, width: 374, height: 36))
				#expect(trackFrame == CGRect(x: 8, y: 48, width: 374, height: 32))
				#expect(tabs.map { $0.title(for: .normal) } == ["Emoji", "GIFs", "Stickers"])
			}
		}
		#expect(KBExperiments.arm(forDraw: 0) == .stacked)
		#expect(KBExperiments.arm(forDraw: 0.49) == .stacked)
		#expect(KBExperiments.arm(forDraw: 0.5) == .unified)
		#expect(KBExperiments.arm(forDraw: 0.99) == .unified)
		#expect(KBExperiments.panelHeader == .unified)
	}

	@MainActor @Test func emojiGridScrollsHorizontallyOnly() async throws {
		let store = try #require(EmojiStore.bundled ?? EmojiStore(url: emojiBinaryURL()))
		let palette = EmojiKeyboardView(theme: .system(dark: true), showsGlobe: false, store: store)
		palette.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
		palette.layoutIfNeeded()
		let grid = try #require(recursiveSubviews(palette).compactMap { $0 as? UICollectionView }.first)
		grid.layoutIfNeeded()
		#expect(grid.contentSize.height <= grid.bounds.height + 0.5)
		#expect(grid.contentSize.width > grid.bounds.width * 4)
		#expect(!grid.alwaysBounceVertical)

		let first = try #require(grid.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
		#expect(first.frame.minX == 0)
		let second = try #require(grid.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
		#expect(second.frame.minX == first.frame.minX)
		#expect(second.frame.minY > first.frame.minY)
		#expect(abs(first.frame.width - first.frame.height) < 0.5)

		let tab = try #require(recursiveSubviews(palette).compactMap { $0 as? UIButton }
			.first { $0.accessibilityIdentifier == "emoji.category.3" })
		tab.sendActions(for: .touchUpInside)
		let target = try #require(grid.layoutAttributesForItem(at: IndexPath(item: 0, section: 3)))
		#expect(grid.contentOffset.y == 0)
		#expect(abs(grid.contentOffset.x - min(target.frame.minX,
			grid.contentSize.width - grid.bounds.width)) < 0.5)
	}

	@Test func clipboardStoreDedupesCapsAndHardensPrivacy() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("clip-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: url) }

		#expect(KBClipboard.add("hello", at: url))
		#expect(KBClipboard.add("world", at: url))
		#expect(KBClipboard.add("hello", at: url))
		let items = KBClipboard.all(at: url)
		#expect(items.map(\.text) == ["hello", "world"])

		#expect(ClipboardPanelView.displayText("line one\n\tline two\n\n  line three  ")
			== "line one line two line three")

		#expect(!KBClipboard.isSensitive("hello world"))
		#expect(KBClipboard.isSensitive("123456"))
		#expect(KBClipboard.isSensitive("4242 4242 4242 4242"))
		#expect(!KBClipboard.isSensitive("4242 4242 4242 4241"))
		#expect(!KBClipboard.add("008041", at: url))
		#expect(!KBClipboard.all(at: url).contains { $0.text == "008041" })

		let old = Date().addingTimeInterval(-(KBClipboard.retentionInterval + 60))
		let seeded = [KBClipboardItem(text: "stale", pinned: false, date: old),
					  KBClipboardItem(text: "kept", pinned: true, date: old)]
		try JSONEncoder().encode(seeded).write(to: url)
		let live = KBClipboard.all(at: url)
		#expect(live.map(\.text) == ["kept"])
		let reencoded = try JSONDecoder().decode([KBClipboardItem].self,
			from: Data(contentsOf: url))
		#expect(!reencoded.contains { $0.text == "stale" })

		for i in 0..<(KBClipboard.maxItems + 20) { KBClipboard.add("row\(i)", at: url) }
		let capped = KBClipboard.all(at: url)
		#expect(capped.filter { !$0.pinned }.count <= KBClipboard.maxItems)
		#expect(capped.contains { $0.text == "kept" && $0.pinned })
	}

	@Test func safetyArtifactUsesExactNormalizedMatches() throws {
		let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
			.deletingLastPathComponent().appendingPathComponent("keyboard/safety.kbguard")
		let safety = try #require(KBSafetyLexicon(url: url))
		#expect(safety.entryCount == 997)
		#expect(safety.isBlocked("FUCK"))
		#expect(safety.isBlocked("5H1T"))
		#expect(safety.isBlocked("  2 GIRLS   1 CUP "))
		#expect(safety.isBlocked("XXX"))
		#expect(safety.isBlocked("దెంగు"))
		#expect(safety.language(for: "దెంగు") == .telugu)
		#expect(safety.action(for: "కుక్క") == .demote)
		#expect(safety.language(for: "కుక్క") == .telugu)
		#expect(!safety.isBlocked("కుక్క"))
		#expect(!safety.isBlocked("class"))
		#expect(!safety.isBlocked("Meher"))
		#expect(!safety.isBlocked("Telangana"))
		#expect(!safety.isBlocked("prolly"))
		#expect(safety.action(for: "kukka") == .allow)
		#expect(KBSafetyLexicon.normalize("  It’s   Fine ") == "it's fine")
	}

	@Test func everyRequestedProfanityTermIsBlockedAtRuntime() throws {
		let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
			.deletingLastPathComponent()
		let safety = try #require(KBSafetyLexicon(
			url: root.appendingPathComponent("keyboard/safety.kbguard")))
		let list = try String(contentsOf:
			root.appendingPathComponent("tools/data/google_profanity_shidouuu_en.txt"),
			encoding: .utf8)
		let words = list.split(whereSeparator: \.isNewline)
			.map(String.init).filter { !$0.isEmpty }
		#expect(words.count == 451)
		let unblocked = words.filter { !(safety.isBlocked($0) && safety.isBlocked($0.uppercased())) }
		#expect(unblocked.count == 0, "\(unblocked.count) requested profanity terms are not blocked")
	}

	@Test func looseCandidatesCannotBeatCloseChannelMatches() async {
		let engine = makeEngine()
		let cases: [(typed: String, context: [String], want: String)] = [
			("sebd", ["can", "you"], "send"),
			("coudl", ["this", "work", "running"], "could"),
			("recieve", ["running", "for", "definitely"], "receive"),
		]
		for c in cases {
			let s = await decode(engine, word: c.typed, context: c.context)
			#expect(s.correction == c.want,
				"\(c.typed) after \(c.context): correction=\(s.correction ?? "nil") sugg=\(s.suggestions)")
			#expect(s.suggestions.first == c.want,
				"\(c.typed) after \(c.context): primary=\(s.suggestions.first ?? "nil")")
		}
		let severe = await decode(engine, word: "coeevitjkn",
			context: ["for", "definitely", "decided"])
		#expect(severe.suggestions.first == "coeevitjkn",
			"severe: sugg=\(severe.suggestions)")
		#expect(severe.correction == nil,
			"severe: correction=\(severe.correction ?? "nil")")
		let liveContext = await decode(engine, word: "coeevitjkn",
			context: ["could", "definitely", "receive"])
		let liveEvidence = liveContext.candidates.map {
			"\($0.word){\($0.source.rawValue),s=\($0.score),c=\($0.spatialCost),lm=\($0.logLanguageProbability)}"
		}.joined(separator: ", ")
		#expect(liveContext.suggestions.first == "coeevitjkn",
			"live severe context: sugg=\(liveContext.suggestions); candidates=\(liveEvidence)")
		#expect(liveContext.correction == nil,
			"live severe context: correction=\(liveContext.correction ?? "nil"); candidates=\(liveEvidence)")
	}

	@Test func contractionTyposAndIdFollowTheNSSRanking() async {
		let engine = makeEngine()
		let thads = await decode(engine, word: "thads", context: [])
		#expect(thads.correction == "that's",
			"thads: correction=\(thads.correction ?? "nil") sugg=\(thads.suggestions)")
		#expect(thads.suggestions.first == thads.correction)
		let idStart = await decode(engine, word: "id", context: [])
		#expect(idStart.correction == "i'd",
			"id at start: correction=\(idStart.correction ?? "nil")")
		let idNoun = await decode(engine, word: "id", context: ["send", "your"])
		#expect(idNoun.correction != "is",
			"id after determiner must not become is: correction=\(idNoun.correction ?? "nil")")
		let idContext = await decode(engine, word: "id", context: ["this"])
		#expect(idContext.correction == "is",
			"id after 'this' should be context-corrected to is: correction=\(idContext.correction ?? "nil")")
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

	@MainActor @Test func emojiAtlasRoundTripAndRender() throws {
		let store = try #require(EmojiStore(url: emojiBinaryURL()))
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("emoji-atlas-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let url = try #require(EmojiAtlas.generateIfNeeded(store: store, scale: 2, in: directory))
		let bytes = try #require((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize)
		let tile = Int((EmojiAtlas.pointSize * 2).rounded())
		#expect(bytes > 0 && bytes % (tile * tile * 4) == 0)
		#expect(EmojiAtlas.generateIfNeeded(store: store, scale: 2, in: directory) == url)

		let atlas = try #require(EmojiAtlas.load(store: store, scale: 2, in: directory))
		#expect(atlas.image(for: store.emoji(0, 0)) != nil)
		#expect(atlas.image(for: "not an emoji") == nil)
		#expect(EmojiAtlas.load(store: store, scale: 1, in: directory) == nil)

		let palette = EmojiKeyboardView(theme: .system(dark: false), showsGlobe: true,
			store: store, atlas: atlas)
		palette.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
		palette.backgroundColor = UIColor(hex: 0xE8E6EC)
		palette.layoutIfNeeded()
		try writePNG(of: palette, name: "emoji_palette_atlas")
	}

	@MainActor @Test func renderClipboardPanel() throws {
		let items = [
			KBClipboardItem(text: "meeting at 3pm tomorrow", pinned: true, date: Date()),
			KBClipboardItem(text: "https://example.com/very/long/link/that/wraps", pinned: false, date: Date()),
			KBClipboardItem(text: "call the dentist", pinned: false, date: Date()),
		]
		for dark in [false, true] {
			let theme = KeyboardTheme.system(dark: dark)
			let panel = ClipboardPanelView(theme: theme, showsGlobe: true,
				hasFullAccess: true, items: items)
			panel.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
			panel.backgroundColor = dark ? UIColor(hex: 0x2A2A2E) : UIColor(hex: 0xE8E6EC)
			panel.layoutIfNeeded()
			try writePNG(of: panel, name: dark ? "clipboard_panel_dark" : "clipboard_panel_light")
		}
		let empty = ClipboardPanelView(theme: .system(dark: false), showsGlobe: true,
			hasFullAccess: false, items: [])
		empty.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
		empty.backgroundColor = UIColor(hex: 0xE8E6EC)
		empty.layoutIfNeeded()
		try writePNG(of: empty, name: "clipboard_panel_empty")
	}

    @MainActor @Test func renderEmojiPalette() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        for dark in [false, true] {
            let theme = KeyboardTheme.system(dark: dark)
            let v = EmojiKeyboardView(theme: theme, showsGlobe: true, store: store)
            v.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
            v.backgroundColor = dark ? UIColor(hex: 0x2A2A2E) : UIColor(hex: 0xE8E6EC)
            v.layoutIfNeeded()
            try writePNG(of: v, name: dark ? "emoji_palette_dark" : "emoji_palette_light")
        }
    }

    @MainActor @Test func renderEmojiSearchHeader() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let theme = KeyboardTheme.system(dark: false)

        let hits = EmojiSearchHeader(theme: theme)
        hits.frame = CGRect(x: 0, y: 0, width: 390, height: EmojiSearchHeader.height)
        hits.backgroundColor = UIColor(hex: 0xE8E6EC)
        hits.update(query: "smile", results: store.search("smile"), showingRecents: false)
        hits.layoutIfNeeded()
        try writePNG(of: hits, name: "emoji_search_results")
        #expect(!store.search("smile").isEmpty)

        let miss = EmojiSearchHeader(theme: theme)
        miss.frame = hits.frame
        miss.backgroundColor = hits.backgroundColor
        miss.update(query: "zzzzqq", results: [], showingRecents: false)
        miss.layoutIfNeeded()
        try writePNG(of: miss, name: "emoji_search_empty")

        let placeholder = EmojiSearchHeader(theme: theme)
        placeholder.frame = hits.frame
        placeholder.backgroundColor = hits.backgroundColor
        placeholder.update(query: "smile", results: store.search("smile"), showingRecents: false)
        placeholder.update(query: "", results: [], showingRecents: true)
        placeholder.layoutIfNeeded()
        try writePNG(of: placeholder, name: "emoji_search_placeholder")
    }

    @MainActor private func writePNG(of view: UIView, name: String) throws {
        let img = UIGraphicsImageRenderer(bounds: view.bounds).image { ctx in
            view.layer.render(in: ctx.cgContext)
        }
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("renders", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #require(img.pngData()).write(to: dir.appendingPathComponent("\(name).png"))
    }
}
