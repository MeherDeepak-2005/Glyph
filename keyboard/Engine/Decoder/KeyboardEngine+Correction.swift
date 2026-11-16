import Foundation

extension KeyboardEngine {

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

	func dontCorrect(_ word: String) {
		let lw = word.lowercased()
		queue.async { [weak self] in
			guard let self else { return }
			self.user.confirmSpelling(lw)
			self.scheduleSave()
		}
	}

	func correctionStood(_ original: String) {
		let lw = original.lowercased()
		queue.async { [weak self] in self?.user.releaseKeep(lw) }
	}

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
