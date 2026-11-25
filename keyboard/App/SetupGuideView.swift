import Combine
import SwiftUI
import UIKit

@MainActor
final class KeyboardSetupStatus: ObservableObject {
	static let extensionBundleID = "com.keypointtech.glyph.keyboard"

	@Published private(set) var isEnabled = false
	@Published private(set) var hasOpened = false
	@Published private(set) var fullAccess = false
	@Published private(set) var lastSeen: Date?

	init() { refresh() }

	func refresh() {
		let keyboards = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] ?? []
		let enabled = keyboards.contains(Self.extensionBundleID) || KBSettings.hasUsedKeyboard
		if enabled != isEnabled { isEnabled = enabled }
		if KBSettings.hasUsedKeyboard != hasOpened { hasOpened = KBSettings.hasUsedKeyboard }
		if KBSettings.lastFullAccess != fullAccess { fullAccess = KBSettings.lastFullAccess }
		if KBSettings.keyboardLastSeenAt != lastSeen { lastSeen = KBSettings.keyboardLastSeenAt }
	}
}

enum SetupStep: Int, CaseIterable, Identifiable {
	case welcome, enable, fullAccess, contacts, switchTo, mainKeyboard, done
	var id: Int { rawValue }

	var title: String {
		switch self {
		case .welcome: "Meet Glyph"
		case .enable: "Turn on Glyph"
		case .fullAccess: "Allow Full Access"
		case .contacts: "Spell names right"
		case .switchTo: "Switch to Glyph"
		case .mainKeyboard: "Make Glyph your main keyboard"
		case .done: "You're all set"
		}
	}

	var detail: String {
		switch self {
		case .welcome:
			"Smarter corrections, glide typing and themes in every app. Setup takes about a minute."
		case .enable:
			"Tap Open Settings, tap Keyboards, then switch Glyph on. Come back here when you're done."
		case .fullAccess:
			"Optional. Turn on Allow Full Access in the same place, then tap Allow. It unlocks GIFs, clipboard history and haptics."
		case .contacts:
			"Optional. Let Glyph read your contacts' names so it never autocorrects them and capitalizes them for you. Names stay on your iPhone."
		case .switchTo:
			"Tap the box below. Then touch and hold the globe key under the keyboard and pick Glyph."
		case .mainKeyboard:
			"iOS opens the keyboard you used last. To see Glyph every time, go to General › Keyboard › Keyboards, tap Edit and drag Glyph to the top."
		case .done:
			"Glyph learns how you type, so it gets better the more you use it."
		}
	}
}

struct SetupGuideView: View {
	let onFinish: () -> Void
	var onClose: (() -> Void)? = nil
	@State private var step: SetupStep
	@StateObject private var status = KeyboardSetupStatus()
	@StateObject private var contacts = ContactNamesSync()
	@Environment(\.scenePhase) private var scenePhase
	@State private var tryText = ""
	@FocusState private var tryFocused: Bool

	init(start: SetupStep = .welcome, onClose: (() -> Void)? = nil, onFinish: @escaping () -> Void) {
		self.onFinish = onFinish
		self.onClose = onClose
		_step = State(initialValue: start)
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			ScrollView {
				VStack(spacing: 22) {
					illustration
						.frame(maxWidth: 360)
						.frame(height: 300)
						.id(step)
						.transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
							removal: .move(edge: .leading).combined(with: .opacity)))
					VStack(spacing: 10) {
						Text(step.title)
							.font(.system(size: 28, weight: .bold))
							.multilineTextAlignment(.center)
						Text(step.detail)
							.font(.system(size: 17))
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
							.fixedSize(horizontal: false, vertical: true)
					}
					.padding(.horizontal, 28)
					statusPill
					if step == .switchTo { tryField }
				}
				.padding(.top, 8)
				.padding(.bottom, 24)
				.frame(maxWidth: .infinity)
			}
			.scrollDismissesKeyboard(.interactively)
			footer
		}
		.background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
		.toolbar(.hidden, for: .navigationBar)
		.onChange(of: scenePhase) { _, phase in
			if phase == .active { status.refresh(); contacts.refresh() }
		}
		.onChange(of: contacts.nameCount) { _, count in
			if count > 0, step == .contacts { advance(after: 1.2) }
		}
		.task {
			while !Task.isCancelled {
				status.refresh()
				try? await Task.sleep(for: .seconds(1))
			}
		}
		.onChange(of: status.isEnabled) { _, on in
			if on, step == .enable { advance(after: 0.9) }
		}
		.onChange(of: status.lastSeen) { _, _ in
			if step == .switchTo, status.hasOpened { advance(after: 1.4) }
		}
	}

	private var header: some View {
		HStack(spacing: 14) {
			HStack(spacing: 6) {
				ForEach(SetupStep.allCases.dropFirst().dropLast()) { s in
					Capsule()
						.fill(s.rawValue <= step.rawValue ? Color.accentColor : Color(uiColor: .systemFill))
						.frame(height: 4)
				}
			}
			.opacity(step == .welcome || step == .done ? 0 : 1)
			.animation(.easeInOut, value: step)
			.accessibilityElement()
			.accessibilityLabel("Step \(step.rawValue) of \(SetupStep.allCases.count - 2)")
			.accessibilityIdentifier("onboarding.firstRun")
			if let onClose {
				Button(action: onClose) {
					Image(systemName: "xmark")
						.font(.system(size: 14, weight: .bold))
						.foregroundStyle(.secondary)
						.frame(width: 30, height: 30)
						.background(Color(uiColor: .tertiarySystemFill), in: Circle())
				}
				.accessibilityLabel("Close")
				.accessibilityIdentifier("setup.close")
			}
		}
		.padding(.horizontal, 24)
		.padding(.top, 10)
		.padding(.bottom, 8)
	}

	@ViewBuilder private var illustration: some View {
		switch step {
		case .welcome: WelcomeIllustration()
		case .enable: EnableIllustration(fullAccess: false)
		case .fullAccess: EnableIllustration(fullAccess: true)
		case .contacts: ContactsIllustration()
		case .switchTo: GlobeMenuIllustration()
		case .mainKeyboard: ReorderIllustration()
		case .done: DoneIllustration()
		}
	}

	@ViewBuilder private var statusPill: some View {
		switch step {
		case .enable:
			pill(done: status.isEnabled, on: "Glyph is turned on", off: "Waiting for Glyph to be turned on")
		case .fullAccess:
			if status.hasOpened {
				pill(done: status.fullAccess, on: "Full Access is on", off: "Full Access is off")
			}
		case .contacts:
			if contacts.isDenied {
				Label("Contacts access is off in Settings", systemImage: "exclamationmark.circle")
					.font(.subheadline.weight(.medium))
					.foregroundStyle(.secondary)
			} else if contacts.isAuthorized && contacts.enabled {
				pill(done: true, on: "\(contacts.nameCount) names added", off: "")
			}
		case .switchTo:
			pill(done: status.hasOpened, on: "Glyph is working", off: "Waiting for Glyph to open")
		default:
			EmptyView()
		}
	}

	private func pill(done: Bool, on: String, off: String) -> some View {
		HStack(spacing: 8) {
			if done {
				Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
			} else {
				ProgressView().controlSize(.small)
			}
			Text(done ? on : off)
		}
		.font(.subheadline.weight(.medium))
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
		.background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
		.animation(.spring(duration: 0.35), value: done)
		.accessibilityIdentifier("setup.status")
	}

	private var tryField: some View {
		TextField("Tap here, then switch to Glyph", text: $tryText)
			.textFieldStyle(.plain)
			.padding(14)
			.background(Color(uiColor: .secondarySystemGroupedBackground),
				in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
				.stroke(Color.accentColor.opacity(tryFocused ? 0.8 : 0.25), lineWidth: 1.5))
			.padding(.horizontal, 24)
			.focused($tryFocused)
			.accessibilityIdentifier("setup.try")
	}

	private var footer: some View {
		VStack(spacing: 10) {
			Button(action: primaryAction) {
				Text(primaryTitle)
					.font(.headline)
					.frame(maxWidth: .infinity, minHeight: 50)
			}
			.buttonStyle(.borderedProminent)
			.accessibilityIdentifier("onboarding.continue")
			if let secondary = secondaryTitle {
				Button(secondary, action: secondaryAction)
					.font(.subheadline.weight(.medium))
					.frame(minHeight: 30)
					.accessibilityIdentifier("setup.secondary")
			}
		}
		.padding(.horizontal, 24)
		.padding(.top, 10)
		.padding(.bottom, 12)
		.background(.bar)
	}

	private var primaryTitle: String {
		switch step {
		case .welcome: "Set up Glyph"
		case .enable: status.isEnabled ? "Next" : "Open Settings"
		case .fullAccess: "Open Settings"
		case .contacts: contactsDone ? "Next" : (contacts.isDenied ? "Open Settings" : "Allow Contacts")
		case .switchTo: status.hasOpened ? "Next" : "Show me the box"
		case .mainKeyboard: "Open Settings"
		case .done: "Start typing"
		}
	}

	private var secondaryTitle: String? {
		switch step {
		case .welcome: nil
		case .enable: status.isEnabled ? nil : "I've turned it on"
		case .fullAccess: "Skip for now"
		case .contacts: contactsDone ? nil : "Skip for now"
		case .switchTo: status.hasOpened ? nil : "Skip"
		case .mainKeyboard: "I've done this"
		case .done: nil
		}
	}

	private func primaryAction() {
		switch step {
		case .welcome: go(.enable)
		case .enable: status.isEnabled ? go(.fullAccess) : openSettings()
		case .fullAccess, .mainKeyboard: openSettings()
		case .contacts:
			if contactsDone { go(.switchTo) }
			else if contacts.isDenied { openSettings() }
			else { Task { await contacts.requestAndSync() } }
		case .switchTo: status.hasOpened ? go(.mainKeyboard) : (tryFocused = true)
		case .done: onFinish()
		}
	}

	private func secondaryAction() {
		switch step {
		case .enable: go(.fullAccess)
		case .fullAccess: go(.contacts)
		case .contacts: go(.switchTo)
		case .switchTo: go(.mainKeyboard)
		case .mainKeyboard: go(.done)
		default: break
		}
	}

	private var contactsDone: Bool { contacts.isAuthorized && contacts.enabled }

	private func go(_ next: SetupStep) {
		tryFocused = false
		withAnimation(.spring(duration: 0.45)) { step = next }
	}

	private func advance(after delay: Double) {
		let from = step
		Task {
			try? await Task.sleep(for: .seconds(delay))
			guard step == from, let next = SetupStep(rawValue: from.rawValue + 1) else { return }
			go(next)
		}
	}

	private func openSettings() {
		guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
		UIApplication.shared.open(url)
	}
}

private struct LoopingPhase: ViewModifier {
	let count: Int
	let interval: Double
	@Binding var phase: Int
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func body(content: Content) -> some View {
		content.task {
			if reduceMotion { phase = count - 1; return }
			phase = 0
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(interval))
				withAnimation(.spring(duration: 0.55)) { phase = (phase + 1) % count }
			}
		}
	}
}

private extension View {
	func looping(_ phase: Binding<Int>, count: Int, every interval: Double = 1.2) -> some View {
		modifier(LoopingPhase(count: count, interval: interval, phase: phase))
	}
}

private struct MockScreen<Content: View>: View {
	var title: String? = nil
	var back: String? = nil
	var trailing: String? = nil
	var trailingID: Bool = false
	@ViewBuilder var content: Content

	var body: some View {
		VStack(spacing: 0) {
			if title != nil || back != nil {
				ZStack {
					if let title { Text(title).font(.system(size: 15, weight: .semibold)) }
					HStack {
						if let back {
							Label(back, systemImage: "chevron.left")
								.labelStyle(.titleAndIcon)
								.font(.system(size: 14))
								.foregroundStyle(Color.accentColor)
						}
						Spacer()
						if let trailing {
							Text(trailing).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
								.id(trailingID)
								.transition(.opacity.animation(.easeInOut(duration: 0.15)))
						}
					}
				}
				.padding(.horizontal, 14)
				.frame(height: 44)
			}
			content
			Spacer(minLength: 0)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(uiColor: .systemGroupedBackground))
		.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
			.stroke(Color(uiColor: .separator).opacity(0.6), lineWidth: 1))
		.shadow(color: .black.opacity(0.12), radius: 18, y: 8)
		.padding(.horizontal, 24)
		.accessibilityHidden(true)
	}
}

private struct MockGroup<Content: View>: View {
	@ViewBuilder var content: Content
	var body: some View {
		VStack(spacing: 0) { content }
			.background(Color(uiColor: .secondarySystemGroupedBackground),
				in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.padding(.horizontal, 14)
	}
}

private struct MockRow<Trailing: View>: View {
	var icon: String? = nil
	var tint: Color = .gray
	let title: String
	var highlighted = false
	var divider = true
	@ViewBuilder var trailing: Trailing

	var body: some View {
		HStack(spacing: 10) {
			if let icon {
				Image(systemName: icon)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(.white)
					.frame(width: 24, height: 24)
					.background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
			}
			Text(title).font(.system(size: 15))
			Spacer()
			trailing
		}
		.padding(.horizontal, 12)
		.frame(height: 42)
		.background(highlighted ? Color(uiColor: .systemGray4) : .clear)
		.overlay(alignment: .bottom) {
			if divider { Divider().padding(.leading, icon == nil ? 12 : 46) }
		}
	}
}

private struct Chevron: View {
	var body: some View {
		Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
	}
}

private struct MockToggle: View {
	let isOn: Bool
	var body: some View {
		Capsule()
			.fill(isOn ? Color.green : Color(uiColor: .systemGray4))
			.frame(width: 46, height: 28)
			.overlay(alignment: isOn ? .trailing : .leading) {
				Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.15), radius: 2, y: 1)
			}
	}
}

private struct TapRing: View {
	let active: Bool
	var body: some View {
		Circle()
			.fill(Color.accentColor.opacity(active ? 0.28 : 0))
			.overlay(Circle().stroke(Color.accentColor.opacity(active ? 0.9 : 0), lineWidth: 2))
			.frame(width: active ? 34 : 54, height: active ? 34 : 54)
			.allowsHitTesting(false)
	}
}

private struct WelcomeIllustration: View {
	@State private var phase = 0
	private let word = Array("glyph")

	var body: some View {
		MockScreen {
			VStack(spacing: 14) {
				HStack(spacing: 0) {
					Text(String(word.prefix(min(phase, word.count))))
						.font(.system(size: 22, weight: .medium))
					Rectangle().fill(Color.accentColor).frame(width: 2, height: 24)
						.opacity(phase % 2 == 0 ? 1 : 0.2)
					Spacer()
				}
				.padding(14)
				.background(Color(uiColor: .secondarySystemGroupedBackground),
					in: RoundedRectangle(cornerRadius: 12, style: .continuous))
				.padding(.horizontal, 14)
				.padding(.top, 18)
				HStack(spacing: 0) {
					ForEach(["glyph", "glyphs", "Glyph's"], id: \.self) { s in
						Text(s).font(.system(size: 14, weight: s == "glyph" ? .semibold : .regular))
							.frame(maxWidth: .infinity)
							.opacity(phase >= word.count ? 1 : 0)
					}
				}
				.padding(.top, 6)
				MiniKeyboard(highlight: phase > 0 && phase <= word.count ? word[phase - 1] : nil)
					.padding(.horizontal, 10)
			}
		}
		.looping($phase, count: word.count + 3, every: 0.45)
	}
}

private struct MiniKeyboard: View {
	var highlight: Character? = nil
	private let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

	var body: some View {
		VStack(spacing: 7) {
			ForEach(rows, id: \.self) { row in
				HStack(spacing: 4) {
					ForEach(Array(row), id: \.self) { ch in
						Text(String(ch).uppercased())
							.font(.system(size: 13, weight: .medium))
							.frame(maxWidth: 26, minHeight: 32)
							.frame(maxWidth: .infinity)
							.background(highlight == ch ? Color.accentColor : Color(uiColor: .systemGray5),
								in: RoundedRectangle(cornerRadius: 5, style: .continuous))
							.foregroundStyle(highlight == ch ? .white : .primary)
							.scaleEffect(highlight == ch ? 1.12 : 1)
					}
				}
				.padding(.horizontal, row.count == 9 ? 12 : row.count == 7 ? 34 : 0)
			}
		}
	}
}

private struct EnableIllustration: View {
	let fullAccess: Bool
	@State private var phase = 0

	var body: some View {
		ZStack {
			if !onKeyboardsPage {
				MockScreen(title: "Glyph", back: "Settings") {
					MockGroup {
						MockRow(icon: "keyboard", tint: .gray, title: "Keyboards", highlighted: phase == 1, divider: true) { Chevron() }
						MockRow(icon: "bell.badge.fill", tint: .red, title: "Notifications", divider: false) { Chevron() }
					}
					.overlay(alignment: .topTrailing) {
						TapRing(active: phase == 1).offset(x: -60, y: 4)
					}
					.padding(.top, 12)
				}
				.transition(.move(edge: .leading).combined(with: .opacity))
			} else {
				MockScreen(title: "Keyboards", back: "Glyph") {
					MockGroup {
						MockRow(title: "Glyph") { MockToggle(isOn: glyphOn) }
							.overlay(alignment: .trailing) { TapRing(active: tappingGlyph).offset(x: -14) }
						MockRow(title: "Allow Full Access", divider: false) { MockToggle(isOn: accessOn) }
							.overlay(alignment: .trailing) { TapRing(active: tappingAccess).offset(x: -14) }
					}
					.padding(.top, 12)
					.opacity(showAlert ? 0.35 : 1)
				}
				.overlay { if showAlert { FullAccessAlert(pressed: phase >= 6) } }
				.transition(.move(edge: .trailing).combined(with: .opacity))
			}
		}
		.looping($phase, count: fullAccess ? 8 : 5)
	}

	private var onKeyboardsPage: Bool { fullAccess || phase >= 2 }
	private var tappingGlyph: Bool { !fullAccess && phase == 3 }
	private var glyphOn: Bool { fullAccess || phase >= 3 }
	private var tappingAccess: Bool { fullAccess && phase == 2 }
	private var showAlert: Bool { fullAccess && (phase == 3 || phase == 4 || phase == 5 || phase == 6) }
	private var accessOn: Bool { fullAccess && phase >= 7 }
}

private struct FullAccessAlert: View {
	let pressed: Bool
	var body: some View {
		VStack(spacing: 0) {
			VStack(spacing: 6) {
				Text("Allow Full Access for \u{201C}Glyph\u{201D} Keyboards?")
					.font(.system(size: 14, weight: .semibold))
					.multilineTextAlignment(.center)
				Text("Full access lets the keyboard use GIFs, clipboard history and haptics.")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
			.padding(14)
			Divider()
			HStack(spacing: 0) {
				Text("Don't Allow").frame(maxWidth: .infinity)
				Divider()
				Text("Allow").fontWeight(.semibold).frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(pressed ? Color(uiColor: .systemGray4) : .clear)
			}
			.font(.system(size: 14))
			.foregroundStyle(Color.accentColor)
			.frame(height: 40)
		}
		.frame(width: 230)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
		.shadow(color: .black.opacity(0.2), radius: 16, y: 6)
		.transition(.scale(scale: 1.1).combined(with: .opacity))
	}
}

private struct GlobeMenuIllustration: View {
	@State private var phase = 0

	var body: some View {
		MockScreen {
			VStack(spacing: 0) {
				Spacer()
				ZStack(alignment: .bottomLeading) {
					MiniKeyboard()
						.padding(.horizontal, 10)
						.padding(.bottom, 52)
					HStack {
						Image(systemName: "globe")
							.font(.system(size: 22))
							.padding(10)
							.background(Circle().fill(phase >= 1 ? Color(uiColor: .systemGray4) : .clear))
							.overlay(TapRing(active: phase >= 1 && phase <= 3))
						Spacer()
						Image(systemName: "mic").font(.system(size: 20))
					}
					.padding(.horizontal, 22)
					.padding(.bottom, 8)
					if phase >= 2 {
						VStack(alignment: .leading, spacing: 0) {
							menuRow("Keyboard Settings…", selected: false)
							Divider()
							menuRow("English (US)", selected: false)
							menuRow("Emoji", selected: false)
							menuRow("Glyph", selected: phase >= 3)
						}
						.frame(width: 200)
						.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
						.shadow(color: .black.opacity(0.2), radius: 14, y: 4)
						.padding(.leading, 18)
						.padding(.bottom, 54)
						.transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
					}
				}
			}
		}
		.looping($phase, count: 5, every: 1.1)
	}

	private func menuRow(_ title: String, selected: Bool) -> some View {
		HStack {
			Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
			Spacer()
			if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
		}
		.padding(.horizontal, 14)
		.frame(height: 36)
		.background(selected ? Color.accentColor.opacity(0.18) : .clear)
	}
}

private struct ReorderIllustration: View {
	@State private var phase = 0

	var body: some View {
		MockScreen(title: "Keyboards", back: "Keyboard", trailing: editing ? "Done" : "Edit", trailingID: editing) {
			MockGroup {
				ForEach(order, id: \.self) { name in
					MockRow(title: name, divider: name != order.last) {
						Image(systemName: "line.3.horizontal")
							.foregroundStyle(.secondary)
							.opacity(editing ? 1 : 0)
							.overlay(TapRing(active: name == "Glyph" && phase == 2))
					}
					.background(name == "Glyph" && phase == 2 ? Color.accentColor.opacity(0.12) : .clear)
					.scaleEffect(name == "Glyph" && phase == 2 ? 1.03 : 1)
					.zIndex(name == "Glyph" ? 1 : 0)
				}
			}
			.padding(.top, 12)
			Text("The keyboard at the top opens first.")
				.font(.system(size: 12))
				.foregroundStyle(.secondary)
				.padding(.top, 10)
		}
		.overlay(alignment: .topTrailing) {
			TapRing(active: phase == 1 || phase == 4).padding(.top, 4).padding(.trailing, 30)
		}
		.looping($phase, count: 6, every: 1.1)
	}

	private var editing: Bool { phase >= 1 && phase <= 3 }
	private var order: [String] {
		phase >= 3 ? ["Glyph", "English (US)", "Emoji"] : ["English (US)", "Emoji", "Glyph"]
	}
}

private struct DoneIllustration: View {
	@State private var appeared = false
	var body: some View {
		ZStack {
			Circle().fill(Color.green.opacity(0.15)).frame(width: 200, height: 200)
				.scaleEffect(appeared ? 1 : 0.6)
			Image(systemName: "checkmark.circle.fill")
				.font(.system(size: 96))
				.foregroundStyle(.green)
				.scaleEffect(appeared ? 1 : 0.3)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.45)) { appeared = true } }
		.accessibilityHidden(true)
	}
}

private struct ContactsIllustration: View {
	@State private var phase = 0

	var body: some View {
		MockScreen {
			ZStack {
				VStack(spacing: 12) {
					HStack(spacing: 0) {
						Text(phase >= 4 ? "Hi Meher " : phase >= 2 ? "Hi mehr" : "Hi ")
							.font(.system(size: 20))
						Rectangle().fill(Color.accentColor).frame(width: 2, height: 22)
						Spacer()
					}
					.padding(14)
					.background(Color(uiColor: .secondarySystemGroupedBackground),
						in: RoundedRectangle(cornerRadius: 12, style: .continuous))
					.padding(.horizontal, 14)
					.padding(.top, 18)
					HStack(spacing: 0) {
						ForEach(["mehr", "Meher", "Meera"], id: \.self) { word in
							Text(word)
								.font(.system(size: 15, weight: word == "Meher" ? .semibold : .regular))
								.frame(maxWidth: .infinity, minHeight: 34)
								.background(word == "Meher" && phase == 3 ? Color.accentColor.opacity(0.2) : .clear,
									in: RoundedRectangle(cornerRadius: 8, style: .continuous))
						}
					}
					.opacity(phase >= 2 && phase < 4 ? 1 : 0)
					.padding(.horizontal, 10)
					MiniKeyboard(highlight: phase == 2 ? "r" : nil)
						.padding(.horizontal, 10)
				}
				.opacity(phase < 2 ? 0.3 : 1)
				if phase < 2 {
					VStack(spacing: 0) {
						VStack(spacing: 6) {
							Image(systemName: "person.crop.circle.fill").font(.system(size: 28)).foregroundStyle(.secondary)
							Text("\u{201C}Glyph\u{201D} Would Like to Access Your Contacts")
								.font(.system(size: 14, weight: .semibold))
								.multilineTextAlignment(.center)
							Text("Names stay on your iPhone.")
								.font(.system(size: 11)).foregroundStyle(.secondary)
						}
						.padding(14)
						Divider()
						HStack(spacing: 0) {
							Text("Don't Allow").frame(maxWidth: .infinity)
							Divider()
							Text("Continue").fontWeight(.semibold)
								.frame(maxWidth: .infinity, maxHeight: .infinity)
								.background(phase == 1 ? Color(uiColor: .systemGray4) : .clear)
						}
						.font(.system(size: 14))
						.foregroundStyle(Color.accentColor)
						.frame(height: 40)
					}
					.frame(width: 240)
					.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
					.shadow(color: .black.opacity(0.2), radius: 16, y: 6)
					.transition(.scale(scale: 1.1).combined(with: .opacity))
				}
			}
		}
		.looping($phase, count: 6, every: 1.1)
	}
}

struct MainKeyboardCard: View {
	let showGuide: () -> Void
	let done: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .top, spacing: 12) {
				Image(systemName: "keyboard.badge.ellipsis")
					.font(.system(size: 20, weight: .semibold))
					.foregroundStyle(.white)
					.frame(width: 40, height: 40)
					.background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
				VStack(alignment: .leading, spacing: 4) {
					Text("Make Glyph your main keyboard").font(.headline)
					Text("Drag Glyph to the top of your keyboard list so it opens first, every time.")
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			HStack {
				Button("Show me how", action: showGuide)
					.buttonStyle(.borderedProminent)
				Spacer()
				Button("Done", action: done)
					.buttonStyle(.bordered)
			}
		}
		.padding(.vertical, 6)
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("prompt.mainKeyboard")
	}
}

#Preview("Setup guide") {
	SetupGuideView {}
}
