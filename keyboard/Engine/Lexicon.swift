import Foundation

final class Lexicon {

	private var supplementaryTrie = Trie()
	private var personalTrie = Trie()
	private(set) var langData: LangData?
	private lazy var nativeVocabulary = KBVocabularyState(safety: safety?.native)

	private let lock = NSLock()
	private var vocabularyEpoch: UInt64 = 0
	var vocabularyRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return vocabularyEpoch }

	private let safety = KBSafetyLexicon.bundled()

	var nativeSafety: KBNativeSafetyLexicon? { safety?.native }

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

	func nextCharPriors(prefix lw: String) -> [Character: Double] {
		lock.lock(); let ld0 = langData; lock.unlock()
		guard let ld = ld0 else { return [:] }
		let kids = ld.trieChildren(after: lw)
        let values = KBNumericPolicy.characterPriors(kids.map { NSNumber(value: $0.maxFreq) })
        return Dictionary(uniqueKeysWithValues: zip(kids.map { Character(UnicodeScalar($0.label)) }, values.map(\.doubleValue)).filter { $0.1 > 0 })
	}

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

	func load(from url: URL?) {
		guard let url, let ld = LangData(url: url) else {
			KBDiagnostics.recorder.storageFailure(operation: "langdata-load")
			return
		}
		if let safety { ld.nativeCandidateLexicon.installBlocked(fromSafety: safety.native) }
		lock.lock(); langData = ld; lock.unlock()
	}
}
