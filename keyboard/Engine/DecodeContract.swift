import Foundation

struct DecodeRequest: Equatable {
	let fieldRevision: UInt64
	let documentRevision: UInt64
	let wordSessionID: UInt64
	let generation: UInt64
	let layoutRevision: UInt64
	let currentWord: String
	let context: [String]
	let taps: [KeyTap?]?

	init(fieldRevision: UInt64, documentRevision: UInt64, wordSessionID: UInt64,
		 generation: UInt64, layoutRevision: UInt64, currentWord: String,
		 context: [String], taps: [KeyTap?]?) {
		self.fieldRevision = fieldRevision
		self.documentRevision = documentRevision
		self.wordSessionID = wordSessionID
		self.generation = generation
		self.layoutRevision = layoutRevision
		self.currentWord = currentWord
		self.context = context
		self.taps = taps
	}
}

enum DecodeCandidateSource: String, Codable, Equatable {
	case typed
	case fuzzyLexicon
	case splitCorrection
}

struct DecodeCandidateEvidence: Equatable {
	let word: String
	let score: Double
	let spatialCost: Double
	let logFrequency: Double
	let logLanguageProbability: Double
	let neuralLogProbability: Double?
	let source: DecodeCandidateSource
	let typedWordMargin: Double

	init(word: String, score: Double, spatialCost: Double, logFrequency: Double,
		 logLanguageProbability: Double, neuralLogProbability: Double? = nil,
		 source: DecodeCandidateSource = .fuzzyLexicon, typedWordMargin: Double = 0) {
		self.word = word
		self.score = score
		self.spatialCost = spatialCost
		self.logFrequency = logFrequency
		self.logLanguageProbability = logLanguageProbability
		self.neuralLogProbability = neuralLogProbability
		self.source = source
		self.typedWordMargin = typedWordMargin
	}
}

struct DecodeSnapshot: Equatable {
	let request: DecodeRequest
	let suggestions: [String]
	let candidates: [DecodeCandidateEvidence]
	let correction: String?
	let confidence: Double
	let nextCharacterPriors: [Character: Double]
	let completedAtUptime: TimeInterval

	func isValid(for current: DecodeRequest) -> Bool {
		request == current
	}
}

struct PresentedSuggestion: Equatable {
	let canonicalText: String
	let text: String
	let isExactTypedCandidate: Bool
}

struct PresentedDecodeSnapshot: Equatable {
	let canonical: DecodeSnapshot
	let suggestions: [PresentedSuggestion]
	let correction: String?

	var primaryText: String? { suggestions.first?.text }

	func isValid(for request: DecodeRequest) -> Bool {
		canonical.isValid(for: request)
	}
}

enum SuggestionCasePolicy {
	static func present(_ snapshot: DecodeSnapshot, sentenceStart: Bool)
		-> PresentedDecodeSnapshot {
		let typed = snapshot.request.currentWord
		let suggestions = snapshot.suggestions.map { candidate in
			let exact = !typed.isEmpty
				&& candidate.caseInsensitiveCompare(typed) == .orderedSame
			return PresentedSuggestion(canonicalText: candidate,
				text: display(candidate, typedWord: typed, sentenceStart: sentenceStart),
				isExactTypedCandidate: exact)
		}
		let correction = snapshot.correction.map { canonical -> String in
			if let displayed = suggestions.first(where: {
				$0.canonicalText.caseInsensitiveCompare(canonical) == .orderedSame
			})?.text {
				return displayed
			}
			return display(canonical, typedWord: typed, sentenceStart: sentenceStart)
		}
		return PresentedDecodeSnapshot(canonical: snapshot, suggestions: suggestions,
			correction: correction)
	}

	static func display(_ candidate: String, typedWord: String? = nil,
		sentenceStart: Bool) -> String {
		let intrinsic = intrinsicEnglishCase(candidate)
		guard let typedWord, !typedWord.isEmpty else {
			return sentenceStart ? initialCapital(intrinsic) : intrinsic
		}
		if candidate.caseInsensitiveCompare(typedWord) == .orderedSame {
			return isIForm(candidate) ? intrinsic : typedWord
		}
		let letters = typedWord.filter(\.isLetter)
		if letters.count > 1, letters.allSatisfy(\.isUppercase) {
			return intrinsic.uppercased()
		}
		if let first = letters.first, first.isUppercase,
			letters.dropFirst().allSatisfy(\.isLowercase) {
			return initialCapital(intrinsic)
		}
		if letters.allSatisfy(\.isLowercase) { return intrinsic }
		return intrinsic
	}

	private static func intrinsicEnglishCase(_ value: String) -> String {
		let lower = value.lowercased()
		guard isIForm(lower) else { return value }
		return "I" + lower.dropFirst()
	}

	private static func isIForm(_ value: String) -> Bool {
		let lower = value.lowercased()
		return lower == "i" || lower == "i'm" || lower == "i'll"
			|| lower == "i've" || lower == "i'd"
	}

	private static func initialCapital(_ value: String) -> String {
		guard let first = value.first else { return value }
		return first.uppercased() + value.dropFirst()
	}
}
