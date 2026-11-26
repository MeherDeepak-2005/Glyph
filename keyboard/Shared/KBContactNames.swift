import Foundation

nonisolated enum KBContactNames {
	static let fileName = "contact-names.json"

	static var url: URL? { KBPersonalData.containerURL?.appendingPathComponent(fileName) }

	static var modifiedAt: Date? {
		guard let url else { return nil }
		return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
	}

	static func load() -> [String] {
		guard let url, let data = try? Data(contentsOf: url),
			  let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
		return names
	}

	@discardableResult
	static func save(_ names: [String]) -> Bool {
		guard let url, let data = try? JSONEncoder().encode(names) else { return false }
		do {
			try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
			return true
		} catch { return false }
	}

	@discardableResult
	static func remove() -> Bool {
		guard let url, FileManager.default.fileExists(atPath: url.path) else { return true }
		return (try? FileManager.default.removeItem(at: url)) != nil
	}

	static func tokens(from parts: [String]) -> [String] {
		var seen = Set<String>()
		var out: [String] = []
		for part in parts {
			for raw in part.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." || $0 == "," }) {
				let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}"))
				guard isNameToken(word) else { continue }
				let display = word.prefix(1).uppercased() + word.dropFirst()
				if seen.insert(display.lowercased()).inserted { out.append(display) }
			}
		}
		return out
	}

	static func isNameToken(_ word: String) -> Bool {
		guard word.count >= 2, word.count <= 24 else { return false }
		return word.unicodeScalars.allSatisfy { scalar in
			(scalar.properties.isAlphabetic && scalar.value < 0x0250) || scalar == "'"
		}
	}
}
