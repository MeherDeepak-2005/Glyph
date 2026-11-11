import SwiftUI
import UIKit

#if DEBUG
private struct KeyboardMetricsPreview: UIViewRepresentable {
	let dark: Bool
	let width: CGFloat

	func makeUIView(context: Context) -> KeyboardView {
		let view = KeyboardView(theme: .system(dark: dark))
		view.setSuggestions(["the", "keyboard", "layout"])
		return view
	}

	func updateUIView(_ uiView: KeyboardView, context: Context) {}

	func sizeThatFits(_ proposal: ProposedViewSize, uiView: KeyboardView,
		context: Context) -> CGSize? {
		uiView.frame = CGRect(x: 0, y: 0, width: width, height: 320)
		uiView.layoutIfNeeded()
		return CGSize(width: width, height: uiView.keyboardHeight)
	}
}

#Preview("English 393pt") {
	KeyboardMetricsPreview(dark: false, width: 393)
		.frame(width: 393)
		.background(Color(white: 0.55))
}

#Preview("English Dark 430pt") {
	KeyboardMetricsPreview(dark: true, width: 430)
		.frame(width: 430)
		.background(Color(white: 0.18))
}
#endif
