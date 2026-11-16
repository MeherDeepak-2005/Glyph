import UIKit

struct KeyboardTheme {
	let name: String
	let backgroundTop, backgroundBottom: UIColor
	let fallbackBackgroundTop, fallbackBackgroundBottom: UIColor
	let usesSystemTransparency: Bool
	let key, keyText, specialKey, specialKeyText, accentKeyText: UIColor
	let accentStart, accentEnd: UIColor
	let accentSoft, accentSoftText: UIColor
	let pressedOverlay: UIColor
	let popupFill, popupText: UIColor
	let shadowColor: UIColor
	let shadowOpacity: Float
	let cornerRadius: CGFloat
	let isDark: Bool
    var isSystemAppearance: Bool = false

	static func system(dark: Bool) -> KeyboardTheme {
		if KBSettings.customThemeEnabled, let c = KBSettings.customTheme(dark: dark) {
			return custom(c)
		}
		return accentTheme(dark: dark, accent: KBSettings.accent)
	}

	static func preview(dark: Bool, accent: KBAccent,
		customTheme: KBCustomTheme?) -> KeyboardTheme {
		if let customTheme { return custom(customTheme) }
		return accentTheme(dark: dark, accent: accent)
	}

	private static func accentTheme(dark: Bool, accent: KBAccent) -> KeyboardTheme {
        let system = accent.id == KBPalette.system.id
		let g = accent.gradient(dark: dark)
		let accentHSL = KBHSL(g.endColor)
		let highContrast = UIAccessibility.isDarkerSystemColorsEnabled
		let specialFill = system
            ? UIColor(white: dark ? 0.32 : 0.67, alpha: highContrast ? 1 : 0.65)
            : accentHSL.color(
			saturation: accentHSL.saturation * (dark ? 0.58 : 0.48),
			lightness: dark ? min(accentHSL.lightness + 0.18, 0.72) : max(accentHSL.lightness - 0.08, 0.34),
			alpha: highContrast ? (dark ? 0.44 : 0.32) : (dark ? 0.18 : 0.14)
		)
		let accentSoftFill = system ? specialFill : accentHSL.color(
			saturation: accentHSL.saturation * (dark ? 0.78 : 0.68),
			lightness: dark ? min(accentHSL.lightness + 0.22, 0.76) : max(accentHSL.lightness - 0.03, 0.38),
			alpha: highContrast ? (dark ? 0.58 : 0.44) : (dark ? 0.34 : 0.24)
		)
		let proposedActionStart = KBHSL(g.startColor).color(
			saturation: KBHSL(g.startColor).saturation * 0.88,
			lightness: dark ? min(KBHSL(g.startColor).lightness + 0.06, 0.64)
				: max(KBHSL(g.startColor).lightness - 0.02, 0.38),
			alpha: 0.94)
		let proposedActionEnd = KBHSL(g.endColor).color(
			saturation: KBHSL(g.endColor).saturation * 0.90,
			lightness: dark ? min(KBHSL(g.endColor).lightness + 0.08, 0.62)
				: max(KBHSL(g.endColor).lightness, 0.36),
			alpha: 0.96)
		let actionText = bestContrastingText(over: [proposedActionStart, proposedActionEnd])
        let actionStart = ensuringContrast(system ? g.startColor : proposedActionStart, against: actionText)
        let actionEnd = ensuringContrast(system ? g.endColor : proposedActionEnd, against: actionText)
		if dark {
			return KeyboardTheme(name: "Dark",
				backgroundTop: .clear,
				backgroundBottom: .clear,
				fallbackBackgroundTop: UIColor(hex: 0x29292E),
				fallbackBackgroundBottom: UIColor(hex: 0x202025),
				usesSystemTransparency: true,
				key: UIColor(white: 1, alpha: highContrast ? 0.34 : 0.165), keyText: UIColor(hex: 0xF4F4F6),
				specialKey: specialFill, specialKeyText: UIColor(hex: 0xECECF0),
				accentKeyText: actionText,
				accentStart: actionStart, accentEnd: actionEnd,
				accentSoft: accentSoftFill, accentSoftText: UIColor(hex: 0xECECF0),
				pressedOverlay: UIColor.white.withAlphaComponent(highContrast ? 0.25 : 0.18),
				popupFill: UIColor(hex: highContrast ? 0x55555C : 0x48484E),
				popupText: UIColor(hex: 0xFAFAFC),
					shadowColor: .white, shadowOpacity: 0, cornerRadius: 8, isDark: true, isSystemAppearance: system)
		} else {
			return KeyboardTheme(name: "Light",
				backgroundTop: .clear,
				backgroundBottom: .clear,
				fallbackBackgroundTop: UIColor(hex: 0xE1E2E6),
				fallbackBackgroundBottom: UIColor(hex: 0xD4D6DB),
				usesSystemTransparency: true,
				key: UIColor(white: 1, alpha: highContrast ? 0.78 : 0.48), keyText: UIColor(hex: 0x161618),
				specialKey: specialFill, specialKeyText: UIColor(hex: 0x1B1B1D),
				accentKeyText: actionText,
				accentStart: actionStart, accentEnd: actionEnd,
				accentSoft: accentSoftFill, accentSoftText: UIColor(hex: 0x1B1B1D),
				pressedOverlay: UIColor.black.withAlphaComponent(highContrast ? 0.18 : 0.11),
				popupFill: .white,
				popupText: UIColor(hex: 0x151517),
					shadowColor: UIColor(white: 0, alpha: 1), shadowOpacity: 0, cornerRadius: 8, isDark: false, isSystemAppearance: system)
		}
	}

	static func custom(_ c: KBCustomTheme) -> KeyboardTheme {
		let text = UIColor(hex: c.text)
		let keyFill = UIColor(hex: c.keys)
		let specialFill = UIColor(hex: c.special)
		let proposedAccentStart = UIColor(hex: c.accentStart)
		let proposedAccentEnd = UIColor(hex: c.accentEnd)
		let accentGlyph = bestContrastingText(over: [proposedAccentStart, proposedAccentEnd])
		let accentStart = ensuringContrast(proposedAccentStart, against: accentGlyph)
		let accentEnd = ensuringContrast(proposedAccentEnd, against: accentGlyph)
		let softAccent = mix(specialFill, accentEnd, accentAmount: 0.30)
		return KeyboardTheme(name: "Custom",
			backgroundTop: UIColor(hex: c.bgStart),
			backgroundBottom: UIColor(hex: c.bgEnd),
			fallbackBackgroundTop: UIColor(hex: c.bgStart),
			fallbackBackgroundBottom: UIColor(hex: c.bgEnd),
			usesSystemTransparency: false,
			key: keyFill, keyText: text,
			specialKey: specialFill, specialKeyText: text,
			accentKeyText: accentGlyph,
			accentStart: accentStart, accentEnd: accentEnd,
			accentSoft: softAccent, accentSoftText: bestContrastingText(over: [softAccent]),
			pressedOverlay: c.dark ? UIColor.white.withAlphaComponent(0.18) : UIColor.black.withAlphaComponent(0.11),
			popupFill: c.dark ? UIColor(hex: 0x48484E) : .white,
			popupText: c.dark ? UIColor(hex: 0xFAFAFC) : UIColor(hex: 0x151517),
				shadowColor: c.dark ? .white : UIColor(white: 0, alpha: 1),
				shadowOpacity: 0, cornerRadius: 8, isDark: c.dark)
	}

	static func luminance(_ hex: UInt32) -> Double {
		func linear(_ encoded: Double) -> Double {
			encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
		}
		let r = linear(Double((hex >> 16) & 0xFF) / 255)
		let g = linear(Double((hex >> 8) & 0xFF) / 255)
		let b = linear(Double(hex & 0xFF) / 255)
		return 0.2126 * r + 0.7152 * g + 0.0722 * b
	}

	static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
		let lighter = max(luminance(a), luminance(b))
		let darker = min(luminance(a), luminance(b))
		return (lighter + 0.05) / (darker + 0.05)
	}

	private static func bestContrastingText(over fills: [UIColor]) -> UIColor {
		let black = UIColor.black
		let white = UIColor.white
		func worstContrast(_ foreground: UIColor) -> Double {
			fills.map { contrastRatio(foreground, $0) }.min() ?? 1
		}
		return worstContrast(black) >= worstContrast(white) ? black : white
	}

	private static func ensuringContrast(_ fill: UIColor, against foreground: UIColor,
		minimum: Double = 4.55) -> UIColor {
		guard contrastRatio(fill, foreground) < minimum else { return fill }
		let foregroundIsBlack = contrastRatio(foreground, .black) < 2
		let target: UIColor = foregroundIsBlack ? .white : .black
		var low: CGFloat = 0
		var high: CGFloat = 1
		for _ in 0..<18 {
			let amount = (low + high) / 2
			if contrastRatio(mix(fill, target, accentAmount: amount), foreground) >= minimum {
				high = amount
			} else {
				low = amount
			}
		}
		return mix(fill, target, accentAmount: high)
	}

	static func contrastRatio(_ a: UIColor, _ b: UIColor) -> Double {
		func lum(_ color: UIColor) -> Double {
			var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, alpha: CGFloat = 0
			guard color.getRed(&r, green: &g, blue: &bl, alpha: &alpha) else { return 0 }
			func linear(_ x: CGFloat) -> Double {
				let v = Double(x)
				return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
			}
			return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(bl)
		}
		let l1 = lum(a), l2 = lum(b)
		return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
	}

	private static func mix(_ base: UIColor, _ accent: UIColor, accentAmount: CGFloat) -> UIColor {
		var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
		var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
		guard base.getRed(&br, green: &bg, blue: &bb, alpha: &ba),
			  accent.getRed(&ar, green: &ag, blue: &ab, alpha: &aa) else { return base }
		let t = min(max(accentAmount, 0), 1)
		return UIColor(red: br + (ar - br) * t, green: bg + (ag - bg) * t,
			blue: bb + (ab - bb) * t, alpha: ba + (aa - ba) * t)
	}
}

private struct KBHSL {
	let hue: CGFloat
	let saturation: CGFloat
	let lightness: CGFloat

	init(_ color: UIColor) {
		var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
		guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
			hue = 0; saturation = 0; lightness = 0.5
			return
		}
		let maximum = max(red, green, blue)
		let minimum = min(red, green, blue)
		let delta = maximum - minimum
		lightness = (maximum + minimum) / 2
		if delta == 0 {
			hue = 0
			saturation = 0
			return
		}
		saturation = delta / (1 - abs(2 * lightness - 1))
		let rawHue: CGFloat
		if maximum == red {
			rawHue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
		} else if maximum == green {
			rawHue = (blue - red) / delta + 2
		} else {
			rawHue = (red - green) / delta + 4
		}
		hue = (rawHue / 6 + 1).truncatingRemainder(dividingBy: 1)
	}

	func color(saturation: CGFloat, lightness: CGFloat, alpha: CGFloat) -> UIColor {
		let s = min(max(saturation, 0), 1)
		let l = min(max(lightness, 0), 1)
		let chroma = (1 - abs(2 * l - 1)) * s
		let sector = hue * 6
		let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
		let rgb: (CGFloat, CGFloat, CGFloat)
		switch sector {
		case 0..<1: rgb = (chroma, x, 0)
		case 1..<2: rgb = (x, chroma, 0)
		case 2..<3: rgb = (0, chroma, x)
		case 3..<4: rgb = (0, x, chroma)
		case 4..<5: rgb = (x, 0, chroma)
		default: rgb = (chroma, 0, x)
		}
		let match = l - chroma / 2
		return UIColor(red: rgb.0 + match, green: rgb.1 + match, blue: rgb.2 + match, alpha: alpha)
	}
}

enum KeyboardSurfacePage { case letters, numbers, symbols, emoji, media, clipboard }
enum KeyboardInputKind: Equatable {
	case standard, email, url, webSearch, twitter
	case numbersAndPunctuation, numberPad, decimalPad, phonePad

	var usesDedicatedNumberPad: Bool {
		switch self { case .numberPad, .decimalPad, .phonePad: return true; default: return false }
	}
}
enum ShiftState   { case off, on, locked }
enum KeyRole      { case normal, special, accent, accentSoft }
enum KeyWidth     {
	case unit, modifier, utility, ret, flex

	static let modifierUnits: CGFloat = 1.35
	static let utilityUnits: CGFloat = 1.3
	static let returnUnits: CGFloat = 2.8
}

struct KeySpec {
	var label: String? = nil
	var symbol: String? = nil
	var accessibilityLabel: String? = nil
	var role: KeyRole = .normal
	var width: KeyWidth = .unit
	var repeats: Bool = false
	var popup: Bool = false
	var letterBase: String? = nil
	var committedText: String? = nil
	var isShift: Bool = false
	var isInputModeSwitch: Bool = false
	var isSpace: Bool = false
	var alternatives: [String] = []
	var action: () -> Void
}
