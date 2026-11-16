import Foundation

nonisolated struct HostSuffixReplacementPlan: Equatable, Sendable {
	enum State: Equatable, Sendable {
		case deleteBackward
		case readyToInsert
		case invalid
	}

	let prefix: String
	let replacement: String
	let maximumDeleteCount: Int

	init?(contextBeforeInput: String, suffix: String, replacement: String) {
		guard !suffix.isEmpty, contextBeforeInput.hasSuffix(suffix) else { return nil }
		prefix = String(contextBeforeInput.dropLast(suffix.count))
		self.replacement = replacement
		maximumDeleteCount = max(suffix.count, suffix.unicodeScalars.count,
			suffix.utf16.count)
	}

	func state(for contextBeforeInput: String) -> State {
		if contextBeforeInput == prefix { return .readyToInsert }
		guard contextBeforeInput.hasPrefix(prefix) else { return .invalid }
		return .deleteBackward
	}

	func apply(initialContext: String,
		 deleteBackward: () -> String?,
		 insert: (String) -> Void) -> Bool {
		var context = initialContext
		for deleted in 0...maximumDeleteCount {
			switch state(for: context) {
			case .readyToInsert:
				if !replacement.isEmpty { insert(replacement) }
				return true
			case .invalid:
				return false
			case .deleteBackward:
				guard deleted < maximumDeleteCount else { return false }
				let updated = deleteBackward() ?? ""
				guard updated.utf16.count < context.utf16.count else { return false }
				context = updated
			}
		}
		return false
	}
}
