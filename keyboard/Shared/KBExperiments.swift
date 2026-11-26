import Foundation

nonisolated enum PanelHeaderStyle: String, CaseIterable, Sendable {
	case unified
	case stacked

	var arm: String { self == .unified ? "C" : "A" }
	var displayName: String { self == .unified ? "C · Unified capsule" : "A · Stacked" }
}

enum KBExperiments {
	static let defaultPanelHeader: PanelHeaderStyle = .unified

	private static let overrideKey = "kb.exp.panelHeader.override"
	private static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
		|| NSClassFromString("XCTestCase") != nil
	private static var store: UserDefaults { KBSettings.sharedDefaults }

	static var panelHeader: PanelHeaderStyle {
		if isTestHost { return defaultPanelHeader }
		return panelHeaderOverride ?? defaultPanelHeader
	}

	static var panelHeaderOverride: PanelHeaderStyle? {
		get { store.string(forKey: overrideKey).flatMap(PanelHeaderStyle.init(rawValue:)) }
		set { store.set(newValue?.rawValue, forKey: overrideKey) }
	}
}
