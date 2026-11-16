import UIKit

enum KeyboardTypography {
	private static var bold: Bool { UIAccessibility.isBoldTextEnabled }

	private static func system(_ size: CGFloat, _ weight: UIFont.Weight, bolder: UIFont.Weight) -> UIFont {
		.systemFont(ofSize: size, weight: bold ? bolder : weight)
	}

	private static func scaled(_ size: CGFloat, _ weight: UIFont.Weight, bolder: UIFont.Weight,
		style: UIFont.TextStyle, cap: CGFloat) -> UIFont {
		UIFontMetrics(forTextStyle: style).scaledFont(for: system(size, weight, bolder: bolder),
			maximumPointSize: (size * cap).rounded())
	}

	static func keyCharacter(lowercase: Bool) -> UIFont {
		system(lowercase ? 25.3 : 23, .regular, bolder: .medium)
	}

	static func keyWord() -> UIFont {
		system(16, .medium, bolder: .semibold)
	}

	static func keyBalloon(headHeight: CGFloat, word: Bool) -> UIFont {
		system(min(word ? 30 : 38, headHeight * 0.72), .regular, bolder: .medium)
	}

	static var keyAlternative: UIFont { system(24, .regular, bolder: .medium) }

	static var suggestion: UIFont { scaled(17, .regular, bolder: .semibold, style: .body, cap: 21 / 17) }

	static var searchField: UIFont { scaled(16, .regular, bolder: .medium, style: .callout, cap: 1.2) }
	static var panelTab: UIFont { scaled(13, .semibold, bolder: .bold, style: .footnote, cap: 1.2) }
	static var panelButton: UIFont { scaled(15, .semibold, bolder: .bold, style: .subheadline, cap: 1.2) }
	static var panelAction: UIFont { scaled(14, .medium, bolder: .semibold, style: .subheadline, cap: 1.2) }
	static var panelTitle: UIFont { scaled(14, .semibold, bolder: .bold, style: .subheadline, cap: 1.2) }
	static var status: UIFont { scaled(14, .medium, bolder: .semibold, style: .subheadline, cap: 1.2) }
	static var emptyState: UIFont { scaled(15, .medium, bolder: .semibold, style: .subheadline, cap: 1.2) }
	static var listItem: UIFont { scaled(15, .regular, bolder: .medium, style: .subheadline, cap: 1.2) }
	static var sectionHeader: UIFont { scaled(11, .semibold, bolder: .bold, style: .caption2, cap: 1.2) }
	static var toast: UIFont { scaled(14, .semibold, bolder: .bold, style: .subheadline, cap: 1.2) }
	static var caption: UIFont { scaled(9, .medium, bolder: .semibold, style: .caption2, cap: 1.2) }
}
