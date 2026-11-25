import Foundation

extension KeyboardEngine {
	static let contactNameMaximumWordFrequency = 5_000
	static let contactNameMinimumTenglishRank = 1_000

	func isCommonWord(_ lw: String) -> Bool {
		if let frequency = lexicon.staticFrequency(lw), frequency >= Self.contactNameMaximumWordFrequency { return true }
		if let rank = tenglishGuard.rank(of: lw), rank < Self.contactNameMinimumTenglishRank { return true }
		return false
	}

	func importContactNames(_ names: [String]) {
		queue.async { [weak self] in
			guard let self else { return }
			for name in names where KBContactNames.isNameToken(name) {
				let lw = name.lowercased()
				guard self.contactNames[lw] == nil, !self.isCommonWord(lw),
					  self.lexicon.isSafeToLearn(lw) else { continue }
				let display = name.prefix(1).uppercased() + name.dropFirst()
				self.contactNames[lw] = display
				if !self.lexicon.contains(lw) { self.lexicon.insert(lw, freq: 80) }
			}
		}
	}

	func isContactName(_ lw: String) -> Bool { contactNames[lw] != nil }

	func applyContactNames(typed lw: String, shown currentWord: String, suggestions: [String],
		decision: String?, confidence: Double) -> ([String], String?, Double) {
		guard !lw.isEmpty, !contactNames.isEmpty else { return (suggestions, decision, confidence) }
		func display(_ word: String) -> String {
			guard let name = contactNames[word.lowercased()], word == word.lowercased() else { return word }
			return name
		}
		var suggestions = suggestions.map(display)
		var decision = decision.map(display)
		var confidence = confidence
		if let name = contactNames[lw] {
			let typedName = currentWord == lw ? name : currentWord
			decision = typedName == currentWord ? nil : typedName
			confidence = decision == nil ? 0 : max(confidence, 1)
			suggestions = [typedName] + suggestions.filter { $0.lowercased() != lw }
		}
		var seen = Set<String>()
		suggestions = suggestions.filter { seen.insert($0.lowercased()).inserted }
		return (Array(suggestions.prefix(3)), decision, confidence)
	}
}
