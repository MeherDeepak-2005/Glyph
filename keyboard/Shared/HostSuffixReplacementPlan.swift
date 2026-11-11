import Foundation

/// A host-independent plan for replacing text immediately before the cursor.
/// Some text hosts delete an extended grapheme (an emoji sequence, a letter with
/// combining marks) in one call while others remove it one unit at a time. Callers
/// therefore inspect the document after every deletion and stop at `prefix` instead of
/// assuming `String.count` matches the host's deletion unit.
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
		// UTF-16 is the most conservative bound used by UIKit hosts. The state check
		// below stops immediately when a host removes a complete grapheme at once.
		maximumDeleteCount = max(suffix.count, suffix.unicodeScalars.count,
			suffix.utf16.count)
	}

	func state(for contextBeforeInput: String) -> State {
		if contextBeforeInput == prefix { return .readyToInsert }
		guard contextBeforeInput.hasPrefix(prefix) else { return .invalid }
		return .deleteBackward
	}

	/// Drives the plan against a host. `deleteBackward` removes one unit and returns the
	/// new text before the cursor — `nil` when the field is now empty, matching
	/// `UITextDocumentProxy.documentContextBeforeInput`. `insert` commits the replacement.
	/// Returns whether the replacement completed.
	///
	/// An empty field (nil context) is the LEGITIMATE terminal state when replacing a
	/// suffix at the very start of the document — i.e. the first word, whose `prefix` is
	/// empty. Coalescing nil → "" here (instead of treating it as a failure) is what lets
	/// a first-word pick or first-word correction-undo insert its replacement instead of
	/// deleting the word and stopping.
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
				let updated = deleteBackward() ?? ""   // nil = now-empty field, not a failure
				guard updated.utf16.count < context.utf16.count else { return false }
				context = updated
			}
		}
		return false
	}
}
