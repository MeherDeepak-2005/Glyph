import UIKit
import Darwin

enum KBWordCase {
	static func sentenceDisplay(_ word: String, capitalized: Bool) -> String {
		guard capitalized, !word.isEmpty else { return word }
		return word.prefix(1).uppercased() + word.dropFirst()
	}
}

struct KBGradient: Hashable {
	let start: UInt32
	let end: UInt32
	var startColor: UIColor { UIColor(hex: start) }
	var endColor: UIColor { UIColor(hex: end) }
}

struct KBAccent: Identifiable, Hashable {
	let id: String
	let name: String
	let light: KBGradient
	let dark: KBGradient

	func gradient(dark: Bool) -> KBGradient { dark ? self.dark : self.light }
	func tint(dark: Bool) -> UIColor { gradient(dark: dark).endColor }
}

enum KBPalette {
	static let `default` = system

    static let system = KBAccent(id: "system", name: "System",
        light: KBGradient(start: 0x007AFF, end: 0x007AFF),
        dark: KBGradient(start: 0x0A84FF, end: 0x0A84FF))

	static let emerald = KBAccent(id: "emerald", name: "Emerald",
		light: KBGradient(start: 0x37C26B, end: 0x1E9E5A),
		dark:  KBGradient(start: 0x33B566, end: 0x18854C))

	static let groups: [(title: String, accents: [KBAccent])] = [
        ("System", [system]),
		("Greens", [
			emerald,
			KBAccent(id: "leaf", name: "Leaf",
				light: KBGradient(start: 0x6FB544, end: 0x4E8E2E),
				dark:  KBGradient(start: 0x78C84E, end: 0x57A338)),
			KBAccent(id: "mint", name: "Mint",
				light: KBGradient(start: 0x44CFA0, end: 0x21B287),
				dark:  KBGradient(start: 0x53DCAB, end: 0x2FC795)),
			KBAccent(id: "teal", name: "Teal",
				light: KBGradient(start: 0x16A89B, end: 0x0B7C76),
				dark:  KBGradient(start: 0x1CB4A6, end: 0x108A82)),
			KBAccent(id: "forest", name: "Forest",
				light: KBGradient(start: 0x4C9E45, end: 0x2C6E30),
				dark:  KBGradient(start: 0x4F9E45, end: 0x357A38)),
		]),
		("Blues", [
			KBAccent(id: "sky", name: "Sky",
				light: KBGradient(start: 0x55B4FF, end: 0x2F97EC),
				dark:  KBGradient(start: 0x63BCFF, end: 0x39A4F5)),
			KBAccent(id: "ocean", name: "Ocean",
				light: KBGradient(start: 0x3A7BF0, end: 0x2056D6),
				dark:  KBGradient(start: 0x4585F0, end: 0x2A60D9)),
			KBAccent(id: "indigo", name: "Indigo",
				light: KBGradient(start: 0x5560E0, end: 0x3A44C6),
				dark:  KBGradient(start: 0x5F69E8, end: 0x434FD6)),
		]),
		("Purples", [
			KBAccent(id: "lavender", name: "Lavender",
				light: KBGradient(start: 0xAE9BFF, end: 0x8E78FA),
				dark:  KBGradient(start: 0xBBA6FF, end: 0x9C84FF)),
			KBAccent(id: "plum", name: "Plum",
				light: KBGradient(start: 0x9A4FD0, end: 0x7733AE),
				dark:  KBGradient(start: 0xA75FE0, end: 0x8642C2)),
		]),
		("Warm", [
			KBAccent(id: "coral", name: "Coral",
				light: KBGradient(start: 0xFF8C76, end: 0xF2654E),
				dark:  KBGradient(start: 0xFF9079, end: 0xF56A52)),
			KBAccent(id: "rose", name: "Rose",
				light: KBGradient(start: 0xFF87B0, end: 0xE5588C),
				dark:  KBGradient(start: 0xFF92B8, end: 0xF56AA0)),
			KBAccent(id: "amber", name: "Amber",
				light: KBGradient(start: 0xFFC24B, end: 0xF5A11F),
				dark:  KBGradient(start: 0xFFC85A, end: 0xF7AE2E)),
			KBAccent(id: "rust", name: "Rust",
				light: KBGradient(start: 0xE2682E, end: 0xBE4C1A),
				dark:  KBGradient(start: 0xE87238, end: 0xCC5A22)),
		]),
		("Neutral", [
			KBAccent(id: "graphite", name: "Graphite",
				light: KBGradient(start: 0x70757E, end: 0x474B52),
				dark:  KBGradient(start: 0x7A7F88, end: 0x4E535A)),
			KBAccent(id: "slate", name: "Slate",
				light: KBGradient(start: 0x78828F, end: 0x566070),
				dark:  KBGradient(start: 0x6E7889, end: 0x4C5666)),
		]),
	]

	static var all: [KBAccent] { groups.flatMap { $0.accents } }
	static func accent(id: String) -> KBAccent { all.first { $0.id == id } ?? `default` }
}

struct KBCustomTheme: Codable, Equatable {
	var keys: UInt32        = 0xFFFFFF
	var special: UInt32     = 0xDDE1EA
	var accentStart: UInt32 = 0x37C26B
	var accentEnd: UInt32   = 0x1E9E5A
	var text: UInt32        = 0x1B1B1D
	var bgStart: UInt32     = 0xF2F0F4
	var bgEnd: UInt32       = 0xE4E1E9
	var dark = false
}

struct KBCustomThemePair: Codable, Equatable {
	var light: KBCustomTheme
	var dark: KBCustomTheme

	static func defaults(accent: KBAccent) -> KBCustomThemePair {
		let lightGradient = accent.gradient(dark: false)
		let darkGradient = accent.gradient(dark: true)
		var light = KBCustomTheme()
		light.accentStart = lightGradient.start
		light.accentEnd = lightGradient.end
		var dark = KBCustomTheme(
			keys: 0x343439,
			special: 0x29292E,
			accentStart: darkGradient.start,
			accentEnd: darkGradient.end,
			text: 0xF2F2F4,
			bgStart: 0x242428,
			bgEnd: 0x1B1B1F,
			dark: true
		)
		dark.dark = true
		return KBCustomThemePair(light: light, dark: dark)
	}
}

enum KBSettings {
	nonisolated static let appGroup = "group.com.meherdeepak.glyph"
	nonisolated(unsafe) static let sharedDefaults = UserDefaults(suiteName: appGroup) ?? .standard
	private static var store: UserDefaults { sharedDefaults }
	private static let configurationNotification = CFNotificationName(
		"com.swiftuimasterclass.keyboard.configuration-changed" as CFString
	)

	private enum Key {
		static let accent   = "kb.accent"
		static let haptics  = "kb.haptics"
		static let glideCap = "kb.glidecapture"
		static let hasUsed  = "kb.hasused"
		static let lastSeen = "kb.keyboard.lastSeen"
		static let fullAccess = "kb.fullaccess"
		static let fullAccessObservedAt = "kb.fullaccess.observedAt"
	}
	static var klipyAPIKey: String {
		let value = Bundle.main.object(forInfoDictionaryKey: "KLIPYAPIKey") as? String ?? ""
		return value.contains("$(") ? "" : value.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	static var klipyContentFilterApproved: Bool {
		let value = Bundle.main.object(forInfoDictionaryKey: "KLIPYContentFilterApproved")
		if let enabled = value as? Bool { return enabled }
		guard let raw = value as? String, !raw.contains("$(") else { return false }
		return ["1", "true", "yes"].contains(raw.lowercased())
	}
	static var klipyMediaEnabled: Bool {
		let value = Bundle.main.object(forInfoDictionaryKey: "KLIPYMediaEnabled")
		if let enabled = value as? Bool { return enabled }
		guard let raw = value as? String, !raw.contains("$(") else { return false }
		return ["1", "true", "yes"].contains(raw.lowercased())
	}

	static var accentID: String {
		get { resolvedAccentID(in: store) }
		set { store.set(newValue, forKey: Key.accent) }
	}
    static func resolvedAccentID(in defaults: UserDefaults) -> String {
        KBPalette.accent(id: defaults.string(forKey: Key.accent) ?? "system").id
    }
	static var accent: KBAccent { KBPalette.accent(id: accentID) }
	static var haptics: Bool {
		get { store.object(forKey: Key.haptics) as? Bool ?? true }
		set {
			store.set(newValue, forKey: Key.haptics)
			postConfigurationChange()
		}
	}
	static var hasUsedKeyboard: Bool {
		get { store.bool(forKey: Key.hasUsed) }
		set { store.set(newValue, forKey: Key.hasUsed) }
	}
	static var keyboardLastSeenAt: Date? {
		let value = store.double(forKey: Key.lastSeen)
		return value > 0 ? Date(timeIntervalSince1970: value) : nil
	}
	static func markKeyboardObserved(fullAccess: Bool) {
		let now = Date().timeIntervalSince1970
		store.set(true, forKey: Key.hasUsed)
		store.set(now, forKey: Key.lastSeen)
		store.set(fullAccess, forKey: Key.fullAccess)
		store.set(now, forKey: Key.fullAccessObservedAt)
	}
	static var lastFullAccess: Bool {
		get { store.bool(forKey: Key.fullAccess) }
		set {
			store.set(newValue, forKey: Key.fullAccess)
			store.set(Date().timeIntervalSince1970, forKey: Key.fullAccessObservedAt)
		}
	}
	static var lastFullAccessObservedAt: Date? {
		let value = store.double(forKey: Key.fullAccessObservedAt)
		return value > 0 ? Date(timeIntervalSince1970: value) : nil
	}
	static var glideCapture: Bool {
		get { store.object(forKey: Key.glideCap) as? Bool ?? false }
		set { store.set(newValue, forKey: Key.glideCap) }
	}

	static var customThemes: KBCustomThemePair? {
		get {
			guard let data = store.data(forKey: "kb.customtheme") else { return nil }
			if let pair = try? JSONDecoder().decode(KBCustomThemePair.self, from: data) {
				return pair
			}
			guard let legacy = try? JSONDecoder().decode(KBCustomTheme.self, from: data) else { return nil }
			var pair = KBCustomThemePair.defaults(accent: accent)
			if legacy.dark { pair.dark = legacy } else { pair.light = legacy }
			return pair
		}
		set {
			if let newValue, let data = try? JSONEncoder().encode(newValue) {
				store.set(data, forKey: "kb.customtheme")
			} else {
				store.removeObject(forKey: "kb.customtheme")
			}
		}
	}
	static func customTheme(dark: Bool) -> KBCustomTheme? {
		guard let themes = customThemes else { return nil }
		return dark ? themes.dark : themes.light
	}
	static var customThemeEnabled: Bool {
		get { store.bool(forKey: "kb.customtheme.on") }
		set { store.set(newValue, forKey: "kb.customtheme.on") }
	}
	static func applyAppearance(accentID: String, customThemes: KBCustomThemePair?, enabled: Bool) {
		store.set(accentID, forKey: Key.accent)
		if let customThemes, let data = try? JSONEncoder().encode(customThemes) {
			store.set(data, forKey: "kb.customtheme")
		} else {
			store.removeObject(forKey: "kb.customtheme")
		}
		store.set(enabled, forKey: "kb.customtheme.on")
		postConfigurationChange()
	}

	private static func postConfigurationChange() {
		store.set(store.integer(forKey: "kb.configuration.revision") + 1,
				  forKey: "kb.configuration.revision")
		store.synchronize()
		CFNotificationCenterPostNotification(
			CFNotificationCenterGetDarwinNotifyCenter(),
			configurationNotification,
			nil,
			nil,
			true
		)
	}

	fileprivate static func addConfigurationObserver(_ observer: UnsafeRawPointer) {
		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			observer,
			{ _, rawObserver, _, _, _ in
				guard let rawObserver else { return }
				Unmanaged<KBConfigurationObserver>.fromOpaque(rawObserver)
					.takeUnretainedValue().receiveChange()
			},
			configurationNotification.rawValue,
			nil,
			.deliverImmediately
		)
	}

	fileprivate static func removeConfigurationObserver(_ observer: UnsafeRawPointer) {
		CFNotificationCenterRemoveObserver(
			CFNotificationCenterGetDarwinNotifyCenter(), observer,
			configurationNotification, nil
		)
	}
}

final class KBConfigurationObserver {
	private let handler: () -> Void

	init(handler: @escaping () -> Void) {
		self.handler = handler
		KBSettings.addConfigurationObserver(Unmanaged.passUnretained(self).toOpaque())
	}

	deinit {
		KBSettings.removeConfigurationObserver(Unmanaged.passUnretained(self).toOpaque())
	}

	fileprivate func receiveChange() { handler() }
}
