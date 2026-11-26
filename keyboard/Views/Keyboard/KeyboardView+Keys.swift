import UIKit

extension KeyboardView {

	func reload() {
		let oldRowCount = rows.count
		endCursorHold()
		alternativeTimers.values.forEach { $0.invalidate() }
		alternativeTimers.removeAll(keepingCapacity: false)
		alternativePopups.values.forEach { $0.removeFromSuperview() }
		alternativePopups.removeAll(keepingCapacity: false)
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = specs().map { row in
			row.map { spec -> KeyButton in
				let b = KeyButton(spec: spec, theme: theme)
				addSubview(b)
				return b
			}
		}
		let all = rows.flatMap { $0 }
		letterKeys = all.compactMap { k in k.letterBase.map { (base: $0, key: k) } }
		for key in all where !key.alternatives.isEmpty {
			let values = key.alternatives
			key.setAlternatives(values) { [weak self, weak key] value in
				guard let self else { return }
				self.routeInsert(value, nil)
				if key?.letterBase != nil, self.shift == .on { self.applyShiftState(.off) }
			}
		}
		shiftKey = all.first { $0.isShift }
		actionKey = all.first { $0.role == .accent }
		applyActionKeyState()
		var orderedAccessibilityElements: [Any] = [suggestionBar]
		let searchViews: [UIView?] = [emojiSearchHeader, mediaSearchHeader, mediaSearchStrip]
		orderedAccessibilityElements.append(contentsOf: searchViews.compactMap { $0 })
		for row in rows { orderedAccessibilityElements.append(contentsOf: row) }
		accessibilityElements = orderedAccessibilityElements
		bringSubviewToFront(suggestionBar)
		touchPopups.values.forEach { bringSubviewToFront($0) }
		layer.addSublayer(trailLayer)
		layer.addSublayer(trailHeadLayer)
		setNeedsLayout()
		if oldRowCount > 0, oldRowCount != rows.count {
			DispatchQueue.main.async { [weak self] in self?.onHeightChange?(false) }
		}
	}

	func letterCenter(for letter: Character) -> CGPoint? {
		guard let frame = letterKeys.first(where: { $0.base.first == letter })?.key.frame else { return nil }
		return CGPoint(x: frame.midX, y: frame.midY)
	}

	func keyAccessibilityLabels() -> [String] {
		rows.flatMap { $0 }.compactMap(\.accessibilityLabel)
	}

    func keyLabelForTesting(at point: CGPoint) -> String? { key(at: point)?.accessibilityLabel }

	func recordedGeometry() -> KBTypingRecorder.Layout {
		func tenth(_ value: CGFloat) -> Double { (Double(value) * 10).rounded() / 10 }
		let keys = rows.joined().prefix(128).map { key in
			KBTypingRecorder.Key(label: String((key.popupText ?? key.committedText ?? key.accessibilityLabel ?? "").prefix(16)),
				x: tenth(key.frame.minX), y: tenth(key.frame.minY), w: tenth(key.frame.width), h: tenth(key.frame.height))
		}
		let screen = window?.windowScene?.screen
		return KBTypingRecorder.Layout(width: tenth(bounds.width), height: tenth(bounds.height),
			xPitch: tenth(unitPitch), yPitch: tenth(rowHeight + rowSpacing), keys: Array(keys),
			page: "\(page)", profile: "\(metrics.profile)",
			screenWidth: tenth(screen?.bounds.width ?? 0), screenHeight: tenth(screen?.bounds.height ?? 0),
			screenScale: Double(screen?.scale ?? 0))
	}

	func keyFramesForTesting() -> [CGRect] {
		rows.flatMap { $0 }.map(\.frame)
	}

	func shifted(_ c: String) -> String { shift == .off ? c : c.uppercased() }

	var latinLayout: LatinLayoutPack { .english }

	func accentAlternatives(for base: String) -> [String] {
		let values = latinLayout.alternatives[base.lowercased()] ?? []
		return shift == .off ? values : values.map { $0.uppercased() }
	}

	private func characterSpec(_ text: String, width: LayoutKey.Width?, accessibilityLabel: String?,
		variants: Bool = true) -> KeySpec {
		if page == .numbers, inputKind.usesDedicatedNumberPad {
			return KeySpec(label: text, accessibilityLabel: accessibilityLabel, width: keyWidth(width, default: .flex),
				subtitle: Self.padLetters[text]) { [weak self] in
				self?.routeInsert(text, nil)
			}
		}
		if page == .letters, text.count == 1, text.first?.isLetter == true {
			return KeySpec(label: shifted(text), accessibilityLabel: accessibilityLabel,
				width: keyWidth(width), popup: true, letterBase: text,
				alternatives: accentAlternatives(for: text)) { [weak self] in
				guard let self else { return }
				self.routeInsert(self.shifted(text), self.activeTap)
				if self.shift == .on { self.applyShiftState(.off) }
			}
		}
		return KeySpec(label: text, accessibilityLabel: accessibilityLabel, width: keyWidth(width),
			popup: true, alternatives: variants ? latinLayout.alternatives[text] ?? [] : []) { [weak self] in
			self?.routeInsert(text, nil)
		}
	}
	private func keyWidth(_ width: LayoutKey.Width?, default fallback: KeyWidth = .unit) -> KeyWidth {
		switch width {
		case .unit?: return .unit
		case .flex?: return .flex
		case .modifier?: return .modifier
		case .utility?: return .utility
		case .return?: return .ret
		case nil: return fallback
		}
	}

	private var fieldExtraKeys: [String] {
		let kind: String
		switch inputKind {
		case .email: kind = "email"
		case .url: kind = "url"
		case .webSearch: kind = "webSearch"
		case .twitter: kind = "twitter"
		default: return []
		}
		return latinLayout.fieldExtras[kind] ?? []
	}

	private func specs() -> [[KeySpec]] {
		switch page {
		case .letters:
			return pageSpecs(latinLayout.letters)
		case .numbers:
			if inputKind.usesDedicatedNumberPad { return pageSpecs(latinLayout.numberPad) }
			return pageSpecs(latinLayout.numbers)
		case .symbols:
			return pageSpecs(latinLayout.symbols)
		case .emoji, .media, .clipboard:
			return []
		}
	}

	private func pageSpecs(_ layoutPage: LayoutPage) -> [[KeySpec]] {
		let currency = LatinLayoutPack.currencySymbol(for: latinLayout.locale)
		func specs(_ row: [LayoutKey]) -> [KeySpec] {
			row.flatMap { key -> [KeySpec] in
				switch key {
				case let .character(text, width, label):
					return [characterSpec(text, width: width, accessibilityLabel: label,
						variants: layoutPage.longPressVariants)]
				case let .control(control, width, target, label):
					return controlSpecs(control, width: width, target: target, label: label,
						currency: currency, variants: layoutPage.longPressVariants)
				}
			}
		}
		var rows = layoutPage.rows.map(specs)
		if let bottom = layoutPage.bottomRow { rows.append(specs(bottom)) }
		return rows
	}

	private func controlSpecs(_ control: LayoutKey.Control, width: LayoutKey.Width?,
		target: LayoutKey.PageTarget?, label: String?, currency: String,
		variants: Bool) -> [KeySpec] {
		switch control {
		case .shift: return [shiftKeySpec(width: keyWidth(width, default: .modifier))]
		case .delete: return [deleteKeySpec(width: keyWidth(width, default: .modifier))]
		case .return: return [returnKeySpec()]
		case .space: return [spaceKeySpec()]
		case .emoji:
			return [KeySpec(symbol: "face.smiling", accessibilityLabel: "Emoji",
				role: .special, width: keyWidth(width, default: .utility)) { [weak self] in self?.showEmoji() }]
		case .globe:
			guard showsGlobe else { return [] }
			return [KeySpec(symbol: "keyboard", accessibilityLabel: "Next Keyboard",
				role: .special, width: keyWidth(width, default: .utility), isInputModeSwitch: true) { [weak self] in
				self?.onNextKeyboard?()
			}]
		case .page:
			guard let target, let label else { return [] }
			let surface: KeyboardSurfacePage
			let spoken: String
			switch target {
			case .letters: surface = .letters; spoken = "Letters"
			case .numbers: surface = .numbers; spoken = "Numbers"
			case .symbols: surface = .symbols; spoken = "Symbols"
			}
			return [KeySpec(label: label, accessibilityLabel: spoken, role: .special,
				width: keyWidth(width, default: .utility)) { [weak self] in
				self?.page = surface; self?.reload()
			}]
		case .fieldExtras:
			return fieldExtraKeys.map { characterSpec($0, width: .unit, accessibilityLabel: nil) }
		case .padAuxiliary:
			let value: String
			switch inputKind {
			case .decimalPad: value = Locale.current.decimalSeparator ?? "."
			case .phonePad: value = "+"
			case .numberPad:
				return [KeySpec(accessibilityLabel: nil, width: keyWidth(width, default: .flex), isSpacer: true) {}]
			default: return []
			}
			return [characterSpec(value, width: width ?? .flex, accessibilityLabel: nil, variants: variants)]
		case .currency:
			return [characterSpec(currency, width: width, accessibilityLabel: nil, variants: variants)]
		}
	}

	static let padLetters: [String: String] = ["2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL",
		"6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ"]

	private func deleteKeySpec(width: KeyWidth = .modifier) -> KeySpec {
		KeySpec(symbol: "delete.left", accessibilityLabel: "Delete",
			role: .special, width: width, repeats: true) { [weak self] in self?.routeDelete() }
	}

	private func returnKeySpec() -> KeySpec {
		if let t = displayedActionTitle, !t.isEmpty {
			return KeySpec(label: t, accessibilityLabel: t, role: .accent, width: .ret) { [weak self] in self?.routeReturn() }
		}
		return KeySpec(symbol: "return", accessibilityLabel: "Return",
			role: .accent, width: .ret) { [weak self] in self?.routeReturn() }
	}

	private func spaceKeySpec() -> KeySpec {
		KeySpec(label: spaceTitle, accessibilityLabel: "Space", width: .flex,
			isSpace: true) { [weak self] in
			self?.routeInsert(" ", nil)
			self?.returnToLettersFromSymbolPage()
		}
	}

	private func shiftKeySpec(width: KeyWidth) -> KeySpec {
		KeySpec(symbol: shiftSymbol, accessibilityLabel: "Shift",
			role: .special, width: width, isShift: true) { [weak self] in
			guard let self else { return }
			let now = ProcessInfo.processInfo.systemUptime
			let isDoubleTap = now - self.lastShiftTapAt <= 0.35
			self.lastShiftTapAt = now
			let next: ShiftState
			if self.shift == .locked {
				next = .off
			} else if isDoubleTap {
				next = .locked
			} else {
				next = self.shift == .off ? .on : .off
			}
			self.applyShiftState(next)
		}
	}
}
