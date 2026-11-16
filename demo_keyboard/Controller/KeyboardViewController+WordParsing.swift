import UIKit

extension KeyboardViewController {

	func isWordChar(_ c: Character) -> Bool {
		c.isLetter || c == "'" || c == "\u{2019}" || c == "\u{02BC}"
	}
	func canonical(_ c: Character) -> Character {
		(c == "\u{2019}" || c == "\u{02BC}") ? "'" : c
	}

	func trailingWord(_ s: String) -> String {
		var w = ""
		for c in s.reversed() { if isWordChar(c) { w.insert(canonical(c), at: w.startIndex) } else { break } }
		return w
	}

	func lastCompleteWord(_ s: String) -> String? {
		var chars = Array(s)
		while let last = chars.last, !isWordChar(last) { chars.removeLast() }
		var w = ""
		while let last = chars.last, isWordChar(last) { w.insert(canonical(last), at: w.startIndex); chars.removeLast() }
		return w.isEmpty ? nil : w
	}

	func contextWords(_ s: String, max: Int) -> [String] {
		let sentenceEnd = Set<Character>(".!?\n")
		var chars = Array(s)
		while let last = chars.last, isWordChar(last) { chars.removeLast() }
		var words: [String] = []
		outer: while words.count < max {
			while let last = chars.last, !isWordChar(last) {
				if sentenceEnd.contains(last) { break outer }
				chars.removeLast()
			}
			if chars.isEmpty { break }
			var w = ""
			while let last = chars.last, isWordChar(last) { w.insert(canonical(last), at: w.startIndex); chars.removeLast() }
			if w.isEmpty { break }
			words.insert(w, at: 0)
		}
		return words
	}
}
