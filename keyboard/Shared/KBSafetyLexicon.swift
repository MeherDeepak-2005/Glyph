import Foundation

final class KBSafetyLexicon {
	enum Action: UInt8 { case allow = 0, demote = 1, suppressSuggest = 2, suppressAlways = 3 }
	enum Language: UInt8 { case english = 1, telugu = 2, tenglish = 3 }

	let native: KBNativeSafetyLexicon
	var entryCount: Int { Int(native.entryCount) }

	static func bundled(name: String = "safety") -> KBSafetyLexicon? {
		guard let url = Bundle.main.url(forResource: name, withExtension: "kbguard") else { return nil }
		return KBSafetyLexicon(url: url)
	}

	init?(url: URL) {
		guard let d = try? Data(contentsOf: url, options: .alwaysMapped),
			  let native = try? KBNativeSafetyLexicon(data: d) else { return nil }
		self.native = native
	}

	private static let foldLocale = Locale(identifier: "en_US_POSIX")

	static func normalize(_ value: String) -> String {
		if isNormalizedASCII(value) { return value }
		if value.unicodeScalars.contains(where: { (0x0C00...0x0C7F).contains($0.value) }) {
			return value.precomposedStringWithCanonicalMapping.split { $0.isWhitespace }.joined(separator: " ")
		}
		let folded = value
			.replacingOccurrences(of: "\u{2019}", with: "'")
			.replacingOccurrences(of: "\u{2018}", with: "'")
			.replacingOccurrences(of: "`", with: "'")
			.folding(options: [.caseInsensitive, .widthInsensitive], locale: foldLocale)
		return folded.split { $0.isWhitespace }.joined(separator: " ")
	}

	private static func isNormalizedASCII(_ value: String) -> Bool {
		for b in value.utf8 {
			switch b {
			case 0x61...0x7A, 0x30...0x39: continue
			case 0x41...0x5A: return false
			case 0x09...0x0D, 0x20: return false
            case 0x60: return false
			case 0x21...0x5F, 0x7B...0x7E: continue
			default: return false
			}
		}
		return true
	}

	func action(for word: String) -> Action {
		Action(rawValue: native.action(forNormalized: Self.normalize(word))) ?? .allow
	}

	func language(for word: String) -> Language? {
		Language(rawValue: native.language(forNormalized: Self.normalize(word)))
	}

	func penalty(for word: String) -> Double {
		native.penalty(forNormalized: Self.normalize(word))
	}

	func isBlocked(_ word: String) -> Bool {
		switch action(for: word) {
		case .suppressSuggest, .suppressAlways: return true
		case .allow, .demote: return false
		}
	}
}
