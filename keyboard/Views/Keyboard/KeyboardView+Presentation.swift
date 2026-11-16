import UIKit

extension KeyboardView {
	@objc func reduceTransparencyDidChange() {
		updateBackdrop()
	}

	func updateBackdrop() {
		let useFallback = theme.usesSystemTransparency
			&& (UIAccessibility.isReduceTransparencyEnabled || UIAccessibility.isDarkerSystemColorsEnabled)
		let top = useFallback ? theme.fallbackBackgroundTop : theme.backgroundTop
		let bottom = useFallback ? theme.fallbackBackgroundBottom : theme.backgroundBottom
		CATransaction.begin(); CATransaction.setDisableActions(true)
		deckLayer.colors = [top.cgColor, bottom.cgColor]
		CATransaction.commit()
	}

	func setSuggestions(_ s: [String], typedPrefix: String? = nil, highlightPrimary: Bool = false) {
		suggestionBar.setSuggestions(s, typedPrefix: typedPrefix, highlightPrimary: highlightPrimary)
	}

    func dismissTools() { suggestionBar.dismissTools() }

	func setGlidePreview(_ word: String?, alternatives: [String] = [],
		confident: Bool = true) {
		suggestionBar.setGlidePreview(word, alternatives: alternatives, confident: confident)
	}

	func setGlideResult(_ word: String, alternatives: [String]) {
		suggestionBar.setGlideResult(word, alternatives: alternatives)
	}

	func setAutoShift(_ on: Bool) {
		guard shift != .locked, !isEmojiSearching else { return }
		applyShiftState(on ? .on : .off)
	}

	func applyShiftState(_ new: ShiftState) {
		guard shift != new else { return }
		shift = new
		guard page == .letters else { return }
		for (base, key) in letterKeys {
			key.setTitle(shifted(base))
			key.setAlternatives(accentAlternatives(for: base)) { [weak self] value in
				guard let self else { return }
				self.routeInsert(value, nil)
				if self.shift == .on { self.applyShiftState(.off) }
			}
		}
		shiftKey?.setSymbol(shiftSymbol)
	}

	func setActionTitle(_ title: String?) {
		guard title != actionTitle else { return }
		actionTitle = title
		applyActionKeyState()
	}

	func setActionEnabled(_ enabled: Bool) {
		guard enabled != actionEnabled else { return }
		actionEnabled = enabled
		applyActionKeyState()
	}

	func applyActionKeyState() {
		guard let actionKey else { return }
		let title = displayedActionTitle
		if let title, !title.isEmpty {
			actionKey.setTitle(title)
			actionKey.accessibilityLabel = title
		} else {
			actionKey.setSymbol("return")
			actionKey.accessibilityLabel = "Return"
		}
        actionKey.setActionAppearance(active: title?.isEmpty == false, theme: theme)
		actionKey.setInputEnabled(displayedActionEnabled)
	}

}
