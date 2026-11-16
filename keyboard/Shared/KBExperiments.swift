import Foundation

nonisolated enum PanelHeaderStyle: String, CaseIterable, Sendable {
	case unified
	case stacked

	var arm: String { self == .unified ? "C" : "A" }
	var displayName: String { self == .unified ? "C · Unified capsule" : "A · Stacked" }
}

enum KBExperiments {
	static let stackedShare = 0.5

	private static let assignedKey = "kb.exp.panelHeader.assigned"
	private static let overrideKey = "kb.exp.panelHeader.override"
	private static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
		|| NSClassFromString("XCTestCase") != nil
	private static var store: UserDefaults { KBSettings.sharedDefaults }

	static var panelHeader: PanelHeaderStyle {
		if isTestHost { return .unified }
		return panelHeaderOverride ?? assignedPanelHeader
	}

	static var panelHeaderOverride: PanelHeaderStyle? {
		get { store.string(forKey: overrideKey).flatMap(PanelHeaderStyle.init(rawValue:)) }
		set { store.set(newValue?.rawValue, forKey: overrideKey) }
	}

	static var assignedPanelHeader: PanelHeaderStyle {
		if let raw = store.string(forKey: assignedKey), let style = PanelHeaderStyle(rawValue: raw) {
			return style
		}
		let style = arm(forDraw: Double.random(in: 0..<1))
		store.set(style.rawValue, forKey: assignedKey)
		return style
	}

	static func arm(forDraw draw: Double) -> PanelHeaderStyle {
		draw < stackedShare ? .stacked : .unified
	}
}
