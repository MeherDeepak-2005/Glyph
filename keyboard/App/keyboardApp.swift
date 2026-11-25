
import SwiftUI

@main
struct keyboardApp: App {
	init() {
		#if RESEARCH_BETA
		ResearchUploader.registerBackgroundRefresh()
		if !ProcessInfo.processInfo.arguments.contains("-keyboard-runtime-host"),
		   NSClassFromString("XCTestCase") == nil, KBTypingRecorder.enableByDefaultUnlessOptedOut() {
			ResearchUploader.scheduleBackgroundRefresh()
		}
		#endif
		#if DEBUG
		if ProcessInfo.processInfo.arguments.contains("-ui-testing-used-keyboard") {
			KBSettings.hasUsedKeyboard = true
		}
		let arguments = ProcessInfo.processInfo.arguments
		if let flag = arguments.firstIndex(of: "-panel-header"), arguments.indices.contains(flag + 1) {
			KBExperiments.panelHeaderOverride = PanelHeaderStyle(rawValue: arguments[flag + 1])
		}
		#endif
	}

    var body: some Scene {
        WindowGroup {
			#if DEBUG
			if ProcessInfo.processInfo.arguments.contains("-keyboard-runtime-send") {
				KeyboardRuntimeSendHostView()
			} else if ProcessInfo.processInfo.arguments.contains("-keyboard-runtime-host") {
				KeyboardRuntimeHostView()
			} else {
				ContentView()
			}
			#else
			ContentView()
			#endif
        }
    }
}

#if DEBUG
private struct KeyboardRuntimeSendHostView: View {
	@State private var sent = 0

	var body: some View {
		VStack(spacing: 16) {
			Text("Sent \(sent)").accessibilityIdentifier("runtime.sent")
			SendField { sent += 1 }
				.frame(height: 44)
				.padding(24)
		}
	}

	private struct SendField: UIViewRepresentable {
		let onSend: () -> Void

		func makeUIView(context: Context) -> UITextView {
			let view = UITextView()
			view.font = .preferredFont(forTextStyle: .body)
			view.layer.borderWidth = 1
			view.layer.borderColor = UIColor.separator.cgColor
			view.layer.cornerRadius = 8
			view.returnKeyType = .send
			view.enablesReturnKeyAutomatically = true
			view.accessibilityIdentifier = "runtime.text"
			view.delegate = context.coordinator
			DispatchQueue.main.async { view.becomeFirstResponder() }
			return view
		}

		func updateUIView(_ view: UITextView, context: Context) { context.coordinator.onSend = onSend }
		func makeCoordinator() -> Coordinator { Coordinator(onSend: onSend) }

		final class Coordinator: NSObject, UITextViewDelegate {
			var onSend: () -> Void
			init(onSend: @escaping () -> Void) { self.onSend = onSend }
			func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
				guard text == "\n" else { return true }
				if view.hasText { onSend(); view.text = "" }
				return false
			}
		}
	}
}

private struct KeyboardRuntimeHostView: View {
	@State private var text = ""
	@State private var contextIndex = 0
	@FocusState private var isFocused: Bool
	private let contexts: [String] = ProcessInfo.processInfo.environment["KB_RUNTIME_CONTEXTS"]
		.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []

	var body: some View {
        VStack {
            HStack {
                Button("Send / clear") { text = ""; isFocused = true }
                    .accessibilityIdentifier("runtime.clear")
                Button("Copy sample") { UIPasteboard.general.string = "Clipboard sample" }
                    .accessibilityIdentifier("runtime.copy")
                Button("Next context") {
                    let context = contexts.isEmpty ? "" : contexts[contextIndex % contexts.count]
                    text = context.isEmpty ? "" : context + " "
                    contextIndex += 1
                    isFocused = true
                }
                .accessibilityIdentifier("runtime.next")
            }
            TextField("Type", text: $text)
                .keyboardType(ProcessInfo.processInfo.arguments.contains("-keyboard-runtime-url") ? .URL : .default)
                .autocorrectionDisabled(ProcessInfo.processInfo.arguments.contains("-keyboard-runtime-url"))
                .textFieldStyle(.roundedBorder)
                .padding(24)
                .accessibilityIdentifier("runtime.text")
                .focused($isFocused)
        }
        .onAppear { DispatchQueue.main.async { isFocused = true } }

	}
}
#endif
