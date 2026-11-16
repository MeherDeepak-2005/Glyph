import Foundation

nonisolated struct KeyTap: Equatable {
	let dx: Double
	let dy: Double
}

final class TouchSpatialProfile {
	private struct Bucket: Codable, Equatable {
		var count = 0
		var meanX = 0.0
		var meanY = 0.0
		var m2X = 0.0
		var m2Y = 0.0

        var native: [NSNumber] { [Double(count), meanX, meanY, m2X, m2Y].map(NSNumber.init(value:)) }

		mutating func observe(_ tap: KeyTap) {
            let values = KBNumericPolicy.touch(native, x: tap.dx, y: tap.dy, observe: true)
            count = values[0].intValue; meanX = values[1].doubleValue; meanY = values[2].doubleValue
            m2X = values[3].doubleValue; m2Y = values[4].doubleValue
		}
	}

	private struct Stored: Codable, Equatable {
		var version = 1
		var rows = [Bucket(), Bucket(), Bucket()]
	}

	private static let key = "kb.touchprofile"
	private var stored: Stored
	private var unsavedSamples = 0

	init(defaults: UserDefaults = KBSettings.sharedDefaults) {
		if let data = defaults.data(forKey: Self.key),
		   let decoded = try? JSONDecoder().decode(Stored.self, from: data),
		   decoded.version == 1, decoded.rows.count == 3 {
			stored = decoded
		} else {
			stored = Stored()
		}
	}

	func adjusted(_ taps: [KeyTap?]?, typed: String) -> [KeyTap?]? {
		guard let taps, taps.count == typed.utf8.count else { return taps }
		return zip(typed.utf8, taps).map { letter, tap in
			guard let tap, let row = rowIndex(for: letter) else { return tap }
			let bucket = stored.rows[row]
            let values = KBNumericPolicy.touch(bucket.native, x: tap.dx, y: tap.dy, observe: false)
            return KeyTap(dx: values[0].doubleValue, dy: values[1].doubleValue)
		}
	}

	func observe(word: String, taps: [KeyTap?],
				 defaults: UserDefaults = KBSettings.sharedDefaults) {
		guard word.utf8.count == taps.count else { return }
		for (letter, tap) in zip(word.lowercased().utf8, taps) {
			guard let tap, let row = rowIndex(for: letter),
				  abs(tap.dx) <= 0.8, abs(tap.dy) <= 0.8 else { continue }
			stored.rows[row].observe(tap)
			unsavedSamples += 1
		}
		if unsavedSamples >= 32 { save(defaults: defaults) }
	}

	func save(defaults: UserDefaults = KBSettings.sharedDefaults) {
		guard unsavedSamples > 0, let data = try? JSONEncoder().encode(stored) else { return }
		defaults.set(data, forKey: Self.key)
		unsavedSamples = 0
	}

	func reset(defaults: UserDefaults = KBSettings.sharedDefaults) {
		stored = Stored()
		unsavedSamples = 0
		defaults.removeObject(forKey: Self.key)
	}

	private func rowIndex(for letter: UInt8) -> Int? {
		guard let y = KB.pos[letter]?.1 else { return nil }
		return Int(y)
	}
}

nonisolated enum KB {
	static let rows = LatinLayoutPack.english.gridRows
	static let rowOffset = LatinLayoutPack.english.gridRowOffsets
	static let apostrophe = UInt8(ascii: "'")
	static let pos: [UInt8: (Double, Double)] = {
		var m: [UInt8: (Double, Double)] = [:]
		for (r, row) in rows.enumerated() {
			for (c, ch) in row.utf8.enumerated() { m[ch] = (Double(c) + rowOffset[r], Double(r)) }
		}
		return m
	}()
}
