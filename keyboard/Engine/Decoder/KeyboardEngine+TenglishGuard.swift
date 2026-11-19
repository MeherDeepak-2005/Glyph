import Foundation

/// Roman Telugu (Tenglish) typed on the English keyboard. A word in the memory-mapped
/// Tenglish unigram list (`tenglish_guard.bin`) is kept exactly as typed: no autocorrect
/// and no spelling corrections in the strip. The builder leaves out words English owns:
/// English words likelier than their Telugu reading, spellings one keyboard slip from a
/// common English word or from a far more frequent one, attested misspellings of more
/// frequent English words, and English loanwords. English correction of those is unchanged.
extension KeyboardEngine {
	/// A Telugu completion is offered only once this many letters are typed...
	static let tenglishCompletionMinimumTyped = 4
	/// ...and at least this share of the completion's letters.
	static let tenglishCompletionTypedShare = 0.6

	func isGuardedTenglish(_ typed: String) -> Bool {
		typed.count >= 2 && tenglishGuard.contains(typed)
	}

	/// Applied to every published English decode. For a known Tenglish word, the typed word
	/// takes the middle slot (what Space commits) and only completions of it stay beside it,
	/// in the English decoder's order. Telugu completions then fill slots English left empty;
	/// they never displace or reorder an English suggestion.
	func applyTenglishGuard(typed lw: String, shown currentWord: String, suggestions: [String],
		decision: String?, confidence: Double) -> ([String], String?, Double) {
		guard !lw.isEmpty, tenglishGuard.isAvailable else { return (suggestions, decision, confidence) }
		var suggestions = suggestions
		var decision = decision
		var confidence = confidence
		if isGuardedTenglish(lw) {
			decision = nil
			confidence = 0
			suggestions = [currentWord] + suggestions.filter {
				let word = $0.lowercased()
				return word != lw && word.hasPrefix(lw)
			}
		}
		if suggestions.count < 3 {
			for word in tenglishCompletions(of: lw, limit: 3 - suggestions.count)
				where !suggestions.contains(where: { $0.lowercased() == word }) {
				suggestions.append(word)
			}
		}
		return (Array(suggestions.prefix(3)), decision, confidence)
	}

	/// The most frequent Tenglish words that extend `lw`, once most of the word is typed.
	func tenglishCompletions(of lw: String, limit: Int) -> [String] {
		guard limit > 0, lw.count >= Self.tenglishCompletionMinimumTyped else { return [] }
		let typed = Double(lw.count)
		return Array(tenglishGuard.suggestions(prefix: lw, context: [], limit: 8).filter {
			$0 != lw && typed >= Self.tenglishCompletionTypedShare * Double($0.count)
				&& !lexicon.isProfane($0)
		}.prefix(limit))
	}
}
