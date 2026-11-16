import Foundation

struct KBClipboardItem: Codable, Equatable {
	var text: String
	var pinned: Bool
	var date: Date
}

enum KBClipboard {
	static let maxItems = 50
	static let maxPins = 10
	static let maxItemLength = 10_000
	static let retentionInterval: TimeInterval = 3600

	private static var store: UserDefaults { KBSettings.sharedDefaults }

	static func fileURL(_ override: URL? = nil) -> URL {
		if let override { return override }
		let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KBSettings.appGroup)
			?? FileManager.default.temporaryDirectory
		return dir.appendingPathComponent("clipboard.json")
	}

	static func all(at url: URL? = nil, now: Date = Date()) -> [KBClipboardItem] {
		let stored = decode(at: url)
		let live = stored.filter { $0.pinned || now.timeIntervalSince($0.date) < retentionInterval }
		if live.count != stored.count { save(live, at: url) }
		return live
	}

	private static func decode(at url: URL?) -> [KBClipboardItem] {
		guard let data = try? Data(contentsOf: fileURL(url)),
			  let items = try? JSONDecoder().decode([KBClipboardItem].self, from: data) else { return [] }
		return items
	}

	private static func save(_ items: [KBClipboardItem], at url: URL?) {
		guard let data = try? JSONEncoder().encode(items) else { return }
		try? data.write(to: fileURL(url), options: .atomic)
	}

	@discardableResult
	static func add(_ text: String, at url: URL? = nil, now: Date = Date()) -> Bool {
		let t = String(text.prefix(maxItemLength))
		guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSensitive(t) else { return false }
		var items = all(at: url, now: now)
		var pinned = false
		if let i = items.firstIndex(where: { $0.text == t }) {
			pinned = items[i].pinned
			items.remove(at: i)
		}
		items.insert(KBClipboardItem(text: t, pinned: pinned, date: now), at: 0)
		var unpinned = 0
		items = items.filter { item in
			if item.pinned { return true }
			unpinned += 1
			return unpinned <= maxItems
		}
		save(items, at: url)
		return true
	}

	@discardableResult
	static func togglePin(_ text: String, at url: URL? = nil) -> [KBClipboardItem] {
		var items = all(at: url)
		guard let i = items.firstIndex(where: { $0.text == text }) else { return items }
		if !items[i].pinned, items.filter(\.pinned).count >= maxPins { return items }
		items[i].pinned.toggle()
		items[i].date = Date()
		save(items, at: url)
		return items
	}

	@discardableResult
	static func remove(_ text: String, at url: URL? = nil) -> [KBClipboardItem] {
		let items = all(at: url).filter { $0.text != text }
		save(items, at: url)
		return items
	}

	static func isSensitive(_ text: String) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if (4...8).contains(trimmed.count), trimmed.allSatisfy(\.isNumber) { return true }
		let digits = trimmed.filter(\.isNumber)
		if (13...19).contains(digits.count),
		   trimmed.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }),
		   luhnValid(digits) {
			return true
		}
		return false
	}

	private static func luhnValid(_ digits: String) -> Bool {
		var sum = 0
		for (offset, ch) in digits.reversed().enumerated() {
			guard let d = ch.wholeNumberValue else { return false }
			if offset % 2 == 1 {
				let doubled = d * 2
				sum += doubled > 9 ? doubled - 9 : doubled
			} else {
				sum += d
			}
		}
		return sum % 10 == 0
	}

	static var consumedChangeCount: Int {
		get { store.integer(forKey: "kb.clip.consumed") }
		set { store.set(newValue, forKey: "kb.clip.consumed") }
	}
}
