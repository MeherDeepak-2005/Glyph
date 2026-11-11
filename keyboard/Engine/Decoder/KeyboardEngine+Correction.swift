import Foundation

extension KeyboardEngine {
	// MARK: Autocorrect feedback and key-target priors

	/// Context-aware next-character priors for key-target resizing (Plan 1). The
	/// context-free trie prior (`base`) is lifted wherever the in-context ranking already
	/// favours a completion extending the current prefix: the character each higher-ranked
	/// completion adds gets a rank-decayed weight, normalized, and folded in with MAX so
	/// context can only ENLARGE a likely key, never shrink one below its lexical baseline.
	func contextualCharPriors(evidence: [DecodeCandidateEvidence], prefix lw: String,
									  base: [Character: Double]) -> [Character: Double] {
		guard !lw.isEmpty else { return base }
        let letters = evidence.compactMap { candidate -> String? in
            guard candidate.word.count > lw.count, candidate.word.hasPrefix(lw) else { return nil }
            return String(candidate.word[candidate.word.index(candidate.word.startIndex, offsetBy: lw.count)])
        }
        var keys = Array(base.keys)
        for letter in letters { let c = Character(letter); if !keys.contains(c) { keys.append(c) } }
        let values = KBNumericPolicy.contextualPriors(letters, baseLetters: keys.map(String.init),
            values: keys.map { NSNumber(value: base[$0] ?? 0) })
        return Dictionary(uniqueKeysWithValues: zip(keys, values.map(\.doubleValue)))
	}

	/// The user undid an autocorrect of `word`: keep it as typed for this session and
	/// count the confirmation (a confirmed spelling adopts sooner).
	func dontCorrect(_ word: String) {
		let lw = word.lowercased()
		queue.async { [weak self] in
			guard let self else { return }
			self.user.confirmSpelling(lw)
			self.scheduleSave()
		}
	}

	/// The user let an autocorrect of `original` stand (typed on instead of undoing).
	/// Acceptance is counter-evidence against an earlier rejection this session —
	/// lift the keep so correction resumes. Nothing persists; keeps are session-scoped.
	func correctionStood(_ original: String) {
		let lw = original.lowercased()
		queue.async { [weak self] in self?.user.releaseKeep(lw) }
	}

	/// The user actively replaced `original` with a different word (picked a suggestion
	/// over their typed word, undid a correction back out of `original`, or erased it
	/// and retyped something else by hand). Strong evidence `original` was a mistake:
	/// lift its session keep — so autocorrect resumes immediately — and walk back one
	/// learned use, so repeated hand-fixes keep it from adopting into the dictionary.
	func wordReplaced(original: String, with replacement: String) {
		let lw = original.lowercased()
		guard lw != replacement.lowercased() else { return }
		queue.async { [weak self] in
			guard let self else { return }
			self.user.releaseKeep(lw)
			self.user.demote(lw)
			self.scheduleSave()
		}
	}
}
