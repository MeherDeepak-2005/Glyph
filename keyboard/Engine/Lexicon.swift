import Foundation

// Lexicon: the vocabulary the shared engine decodes over — the mapped dictionary
// (langdata.bin), the platform's supplementary words and the user's adopted words — plus
// the bundled safety policy.

final class Lexicon {

	/// Supplementary and learned words are separate layers, so resetting personalization
	/// drops only learned words, not contact/text-replacement words imported for this process.
	private var supplementaryTrie = Trie()
	private var personalTrie = Trie()
	/// The mmap'd bundle dictionary; nil until loaded, or when it failed to load.
	private(set) var langData: LangData?
	private lazy var nativeVocabulary = KBVocabularyState(safety: safety?.native)

	/// Mutable trie layers and load-time state are written by the engine queue and read by
	/// dedicated decode/Glide queues. Every method below takes this lock; the mmap'd
	/// dictionary itself is immutable, and no disk or model work is performed while the
	/// lock is held. (isProfane needs no lock: the safety map is immutable.)
	private let lock = NSLock()
	private var vocabularyEpoch: UInt64 = 0
	var vocabularyRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return vocabularyEpoch }

	// The project-reviewed exact-match policy lives in the bundled `safety.kbguard`
	// binary, memory-mapped and hash-indexed. It filters generated candidates only;
	// typed input is never censored. nil only if the resource is missing in tests.
	private let safety = KBSafetyLexicon.bundled()

	/// The native safety lexicon: the shared engine and vocabulary state read their
	/// penalties and blocked terms from it directly.
	var nativeSafety: KBNativeSafetyLexicon? { safety?.native }

	/// Retain immutable native views under the lock; the decode runs after unlocking.
	/// Learning uses copy-on-write if a Glide/decode still holds a view.
	func nativeGenerationView() -> KBGenerationLexicon {
		lock.lock()
		let view = KBGenerationLexicon(packed: langData?.nativeCandidateLexicon,
			supplementary: supplementaryTrie.native, personal: personalTrie.native,
			snapshot: nativeVocabulary.snapshot)
		lock.unlock()
		return view
	}

	func isProfane(_ w: String) -> Bool {
		safety?.isBlocked(w.lowercased()) == true
	}

	func safetyPenalty(_ word: String) -> Double {
		safety?.penalty(for: word) ?? 0
	}

	func isSafeToLearn(_ word: String) -> Bool {
		(safety?.action(for: word) ?? .allow) == .allow
	}

	func contains(_ lw: String) -> Bool {
		lock.lock(); defer { lock.unlock() }
		return langData?.trieContains(lw) == true
			|| supplementaryTrie.contains(lw) || personalTrie.contains(lw)
	}
	/// True only for words in the shipped dictionary (the mmap trie), not adopted or
	/// supplementary words.
	func isStaticWord(_ lw: String) -> Bool {
		lock.lock(); defer { lock.unlock() }
		return langData?.trieContains(lw) == true
	}
	func insert(_ lw: String, freq: Int) {
		lock.lock(); defer { lock.unlock() }
		supplementaryTrie.insert(lw, freq: freq)
		vocabularyEpoch &+= 1
        nativeVocabulary.supplementary(lw, frequency: freq, glide: Self.isGlideSpelling(lw))
	}

	func glideDynamicWords(limit: Int) -> [String] {
		lock.lock(); defer { lock.unlock() }
        return nativeVocabulary.dynamicWords(UInt(max(0, limit)))
	}

	private static func isGlideSpelling(_ word: String) -> Bool {
		word.count >= 2 && word.utf8.allSatisfy {
			($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || $0 == KB.apostrophe
		}
	}
	func wordID(_ lw: String) -> Int32? {
		lock.lock(); defer { lock.unlock() }
		return langData?.trieWordID(lw)
	}

	/// Next-character priors under the current prefix, for key-target resizing:
	/// log-scaled subtree max frequency, normalized to [0, 1] of the strongest child.
	/// Read straight off the mmap trie — no heap tables, no language-model call.
	func nextCharPriors(prefix lw: String) -> [Character: Double] {
		lock.lock(); let ld0 = langData; lock.unlock()
		guard let ld = ld0 else { return [:] }
		let kids = ld.trieChildren(after: lw)
        let values = KBNumericPolicy.characterPriors(kids.map { NSNumber(value: $0.maxFreq) })
        return Dictionary(uniqueKeysWithValues: zip(kids.map { Character(UnicodeScalar($0.label)) }, values.map(\.doubleValue)).filter { $0.1 > 0 })
	}

	/// Adoption: known words get their frequency bumped; unknown words enter the
	/// dynamic trie once the user has typed them `adoptAfter` times.
	func noteUse(of lw: String, timesUsed: Int, adoptAfter: Int,
				 allowAdoption: Bool = false) {
		lock.lock(); defer { lock.unlock() }
        if nativeVocabulary.note(lw, count: timesUsed, allowAdoption: allowAdoption, threshold: adoptAfter,
            glide: Self.isGlideSpelling(lw), packed: langData?.nativeCandidateLexicon,
            supplementary: supplementaryTrie.native, personal: personalTrie.native) { vocabularyEpoch &+= 1 }
	}

	func resetPersonalization() {
		lock.lock()
		vocabularyEpoch &+= 1
		personalTrie = Trie()
        nativeVocabulary.resetPersonalization()
		lock.unlock()
	}

	func loadFromBundle() {
		load(from: Bundle.main.url(forResource: "langdata", withExtension: "bin"))
	}

	/// Explicit resource seam for deterministic engine tests and offline tools. The
	/// shipping engine calls `loadFromBundle()` and follows the same implementation.
	/// Without a valid dictionary the shared engine is not built and the keyboard types
	/// without suggestions.
	func load(from url: URL?) {
		guard let url, let ld = LangData(url: url) else {
			KBDiagnostics.recorder.storageFailure(operation: "langdata-load")
			return
		}
		// Exclude blocked words from the search before any decode can run.
		if let safety { ld.nativeCandidateLexicon.installBlocked(fromSafety: safety.native) }
		lock.lock(); langData = ld; lock.unlock()
	}
}
