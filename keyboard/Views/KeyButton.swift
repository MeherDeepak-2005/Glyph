import UIKit

final class KeyButton: UIView {
	let widthKind: KeyWidth
	let action: () -> Void
	let repeats: Bool
	let letterBase: String?
	let committedText: String?
	let isShift: Bool
	let isInputModeSwitch: Bool
	let isSpace: Bool
	private(set) var alternatives: [String]
	let role: KeyRole
	private let canPopup: Bool
	private let dark: Bool
	private let gradient: CAGradientLayer?
	private let dim = UIView()
	private let dimColor: UIColor
	private let baseRadius: CGFloat
	private var label: UILabel?
	private var iconView: UIImageView?
	private var contentView: UIView?
	private let recessColor: UIColor
	private let spokenLabelWasExplicit: Bool
	private let foregroundColor: UIColor
	private(set) var acceptsInput = true

	var popupText: String? { canPopup ? label?.text : nil }

	init(spec: KeySpec, theme: KeyboardTheme) {
		self.widthKind = spec.width
		self.action = spec.action
		self.repeats = spec.repeats
		self.letterBase = spec.letterBase
		self.committedText = spec.committedText
		self.isShift = spec.isShift
		self.isInputModeSwitch = spec.isInputModeSwitch
		self.isSpace = spec.isSpace
		self.alternatives = spec.alternatives
		self.role = spec.role
		self.canPopup = spec.popup
		self.dark = theme.isDark
		self.gradient = spec.role == .accent ? CAGradientLayer() : nil
		self.dimColor = theme.pressedOverlay
		self.recessColor = theme.isDark ? UIColor(white: 0, alpha: 0.34) : UIColor(white: 0, alpha: 0.16)
		self.baseRadius = theme.cornerRadius
		self.spokenLabelWasExplicit = spec.accessibilityLabel != nil
		self.foregroundColor = {
			switch spec.role {
			case .normal: return theme.keyText
			case .special: return theme.specialKeyText
			case .accent: return theme.accentKeyText
			case .accentSoft: return theme.accentSoftText
			}
		}()
		super.init(frame: .zero)
		isUserInteractionEnabled = false
		isAccessibilityElement = true
		accessibilityLabel = spec.accessibilityLabel ?? spec.label ?? Self.spokenName(for: spec.symbol)
		accessibilityTraits = .keyboardKey
		if spec.isSpace { accessibilityHint = "Hold and drag to move the cursor" }

		let fg = foregroundColor

		if let gradient {
			gradient.colors = [theme.accentStart.cgColor, theme.accentEnd.cgColor]
			gradient.startPoint = CGPoint(x: 0, y: 0)
			gradient.endPoint   = CGPoint(x: 1, y: 1)
			gradient.cornerRadius = theme.cornerRadius
			gradient.cornerCurve = .continuous
			layer.addSublayer(gradient)
		} else {
			switch spec.role {
			case .special:    backgroundColor = theme.specialKey
			case .accentSoft: backgroundColor = theme.accentSoft
			default:          backgroundColor = theme.key
			}
		}

		dim.isUserInteractionEnabled = false
		dim.backgroundColor = .clear
		dim.layer.cornerRadius = theme.cornerRadius
		dim.layer.cornerCurve = .continuous
		addSubview(dim)

		let content: UIView
		if let symbol = spec.symbol {
			let iv = UIImageView(image: UIImage(systemName: symbol, withConfiguration: Self.symbolConfig))
			iv.tintColor = fg
			content = iv
			iconView = iv
		} else {
			let lbl = UILabel()
			lbl.text = spec.label
			lbl.textColor = fg
			lbl.font = legendFont(spec.label ?? "")
			lbl.textAlignment = .center
			content = lbl
			label = lbl
		}
		content.translatesAutoresizingMaskIntoConstraints = false
		contentView = content
		addSubview(content)
		NSLayoutConstraint.activate([
			content.centerXAnchor.constraint(equalTo: centerXAnchor),
			content.centerYAnchor.constraint(equalTo: centerYAnchor)
		])

		layer.cornerRadius = theme.cornerRadius
		layer.cornerCurve = .continuous
		if UIAccessibility.shouldDifferentiateWithoutColor,
		   spec.role == .accent || spec.role == .accentSoft {
			layer.borderWidth = 1.25
			layer.borderColor = foregroundColor.withAlphaComponent(0.48).cgColor
		}
		layer.shadowColor = theme.shadowColor.cgColor
		layer.shadowOpacity = theme.shadowOpacity
		layer.shadowRadius = 2.5
		layer.shadowOffset = CGSize(width: 0, height: 1)
        if isShift, let symbol = spec.symbol { setSymbol(symbol) }
	}
	required init?(coder: NSCoder) { fatalError() }

	override func accessibilityActivate() -> Bool {
		guard acceptsInput else { return false }
		action()
		return true
	}

	func trigger() {
		guard acceptsInput else { return }
		action()
	}

	func setInputEnabled(_ enabled: Bool) {
		guard acceptsInput != enabled else { return }
		acceptsInput = enabled
		alpha = enabled ? 1 : 0.42
		isAccessibilityElement = true
		if enabled { accessibilityTraits.remove(.notEnabled) }
		else { accessibilityTraits.insert(.notEnabled) }
	}

	private var alternativeActivation: ((String) -> Void)?
	private var builtCustomActions: [UIAccessibilityCustomAction]?

	func setAlternatives(_ values: [String], activation: @escaping (String) -> Void) {
		alternatives = values
		alternativeActivation = values.isEmpty ? nil : activation
		builtCustomActions = nil
	}

	override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
		get {
			guard let activation = alternativeActivation else { return super.accessibilityCustomActions }
			if let builtCustomActions { return builtCustomActions }
			let actions = alternatives.map { value in
				UIAccessibilityCustomAction(name: value) { _ in
					activation(value)
					return true
				}
			}
			builtCustomActions = actions
			return actions
		}
		set { super.accessibilityCustomActions = newValue }
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		let r = baseRadius
		CATransaction.begin(); CATransaction.setDisableActions(true)
		layer.cornerRadius = r
		gradient?.cornerRadius = r
		gradient?.frame = bounds
		dim.layer.cornerRadius = r
		dim.frame = bounds
		CATransaction.commit()
		layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: r).cgPath
	}

	private var covered = false
	func setHighlighted(_ on: Bool) {
		guard !covered else { return }
		dim.backgroundColor = on ? dimColor : .clear
	}

	func setCovered(_ on: Bool) {
		covered = on
		contentView?.isHidden = on
		dim.backgroundColor = on ? recessColor : .clear
	}

	private func legendFont(_ text: String) -> UIFont {
		if text.count > 1 { return KeyboardTypography.keyWord() }
		let lowercase = letterBase != nil && text == text.lowercased() && text != text.uppercased()
		return KeyboardTypography.keyCharacter(lowercase: lowercase)
	}

	static let symbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)

    func setActionAppearance(active: Bool, theme: KeyboardTheme) {
        guard theme.isSystemAppearance else { return }
        let fill = active ? theme.accentStart : theme.specialKey
        gradient?.colors = [fill.cgColor, fill.cgColor]
        let text = active ? theme.accentKeyText : theme.specialKeyText
        label?.textColor = text
        iconView?.tintColor = text
    }

	func setTitle(_ text: String) {
		if label == nil {
			let newLabel = UILabel()
			newLabel.textColor = foregroundColor
			installContent(newLabel)
			label = newLabel
		}
		label?.font = legendFont(text)
		label?.textAlignment = .center
		label?.text = text
		label?.isHidden = covered
		iconView?.isHidden = true
		contentView = label
		if !spokenLabelWasExplicit { accessibilityLabel = text }
	}
	func setSymbol(_ name: String) {
		if iconView == nil {
			let newIcon = UIImageView()
			newIcon.tintColor = foregroundColor
			installContent(newIcon)
			iconView = newIcon
		}
		iconView?.image = UIImage(systemName: name, withConfiguration: Self.symbolConfig)
		iconView?.isHidden = false
		label?.isHidden = true
		contentView = iconView
		if isShift {
			accessibilityLabel = name == "capslock.fill" ? "Caps Lock" : "Shift"
			accessibilityValue = name == "shift" ? "Off" : "On"
		}
	}

	private func installContent(_ view: UIView) {
		view.translatesAutoresizingMaskIntoConstraints = false
		addSubview(view)
		NSLayoutConstraint.activate([
			view.centerXAnchor.constraint(equalTo: centerXAnchor),
			view.centerYAnchor.constraint(equalTo: centerYAnchor)
		])
	}

	private static func spokenName(for symbol: String?) -> String? {
		switch symbol {
		case "delete.left": return "Delete"
		case "return": return "Return"
		case "shift", "shift.fill": return "Shift"
		case "capslock.fill": return "Caps Lock"
		case "face.smiling": return "Emoji"
		case "globe", "keyboard": return "Next Keyboard"
		default: return nil
		}
	}
}
