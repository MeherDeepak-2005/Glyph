import SwiftUI
import Combine
import StoreKit
import os

extension KBAccent {
	func colors(dark: Bool) -> [Color] {
		let g = gradient(dark: dark)
		return [Color(uiColor: g.startColor), Color(uiColor: g.endColor)]
	}
	func linearGradient(dark: Bool) -> LinearGradient {
		LinearGradient(colors: colors(dark: dark), startPoint: .topLeading, endPoint: .bottomTrailing)
	}
	func representative(dark: Bool) -> Color { Color(uiColor: tint(dark: dark)) }
}

final class SettingsStore: ObservableObject {
    private var reloading = false
	@Published var accentID: String { didSet { if !reloading { KBSettings.accentID = accentID } } }
	@Published var haptics:  Bool       { didSet { KBSettings.haptics = haptics } }

	init() {
		accentID = KBSettings.accentID
		haptics  = KBSettings.haptics
	}

	func reload() {
        reloading = true
        defer { reloading = false }
		accentID = KBSettings.accentID
		haptics = KBSettings.haptics
	}

	var accent: KBAccent { KBPalette.accent(id: accentID) }
}

struct ContentView: View {
	@StateObject private var store = SettingsStore()
	@StateObject private var commercial = CommercialStore()
	@Environment(\.colorScheme) private var scheme
	@Environment(\.displayScale) private var displayScale
	@Environment(\.scenePhase) private var scenePhase
	@State private var showResetConfirm = false
	@State private var showDeleteAllConfirm = false
	@State private var hasUsedKeyboard = KBSettings.hasUsedKeyboard
	@AppStorage("kb.onboarding.continued") private var continuedPastOnboarding = false
	@AppStorage("kb.prompt.mainKeyboard.done") private var mainKeyboardPromptDone = false
	@AppStorage("kb.research.launchNoticeShown") private var researchNoticeShown = false
	@State private var showResearchNotice = false

	var body: some View {
		NavigationStack {
			if hasUsedKeyboard || continuedPastOnboarding {
				List {
					Section {
						CommercialHomeCarousel(commercial: commercial)
							.listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
							.listRowBackground(Color.clear)
							.listRowSeparator(.hidden)
					}
					if !mainKeyboardPromptDone {
						Section {
							MainKeyboardPrompt { mainKeyboardPromptDone = true }
						}
					}
					Section("Progress") {
						AchievementBanner()
					}
				Section("Status") {
					NavigationLink {
						SetupSupportView()
					} label: {
						SettingRow(icon: "keyboard",
								   tint: Color(uiColor: .systemBlue),
								   title: "Setup & Support",
								   value: keyboardStatusValue)
					}
				}

				Section {
					NavigationLink {
						ThemeStudioView()
					} label: {
						SettingRow(icon: "paintpalette.fill",
								   tint: Color(uiColor: .systemPurple),
								   title: "Appearance",
								   value: KBSettings.customThemeEnabled ? "Custom" : store.accent.name,
								   trailingGradient: KBSettings.customThemeEnabled ? nil : store.accent.linearGradient(dark: scheme == .dark))
					}
					.accessibilityIdentifier("settings.appearance")
					Toggle(isOn: $store.haptics) {
						iconLabel("hand.tap.fill",
								  tint: Color(uiColor: .systemOrange),
								  title: "Haptic Feedback")
					}
				} header: {
					Text("Keyboard")
				} footer: {
					Text("Haptics require a physical iPhone and follow the device's system haptic settings. The status page shows the last state observed by the keyboard.")
				}

				Section("Rewards") {
					NavigationLink {
						RewardCenterView(store: commercial)
					} label: {
						SettingRow(icon: "gift.fill",
								   tint: Color(uiColor: .systemPink),
								   title: "Offers & Theme Rewards")
					}
				}

				Section("Personalization") {
					Button(role: .destructive) {
						showResetConfirm = true
					} label: {
						iconLabel("trash.fill", tint: .red, title: "Reset learned words")
					}
					Button(role: .destructive) {
						showDeleteAllConfirm = true
					} label: {
						iconLabel("externaldrive.badge.xmark", tint: .red, title: "Delete all keyboard data")
					}
				}

			Section("Privacy") {
				NavigationLink {
					PrivacyDataView()
					} label: {
						SettingRow(icon: "hand.raised.fill",
								   tint: Color(uiColor: .systemIndigo),
								   title: "Privacy & Data")
				}
				#if RESEARCH_BETA
				NavigationLink {
					ResearchView()
				} label: {
					SettingRow(icon: "waveform.badge.magnifyingglass",
							   tint: Color(uiColor: .systemTeal),
							   title: "Typing Research",
							   value: KBTypingRecorder.enabled ? "On" : "Off")
				}
				#endif
				NavigationLink {
					ThirdPartyNoticesView()
				} label: {
					SettingRow(icon: "doc.text.fill",
							   tint: Color(uiColor: .systemGray),
							   title: "Third-Party Notices")
				}
			}

				#if DEBUG
				Section("Developer") {
					NavigationLink {
						DiagnosticsView()
					} label: {
						SettingRow(icon: "waveform.path.ecg",
								   tint: Color(uiColor: .systemGray),
								   title: "Keyboard health")
					}
				}
				#endif
				}
				.listStyle(.insetGrouped)
				.navigationTitle("Glyph")
				.navigationBarTitleDisplayMode(.large)
			} else {
				FirstRunView { continuedPastOnboarding = true }
			}
		}
		.environmentObject(store)
		.tint(Color(uiColor: .systemBlue))
		.task(id: displayScale) {
			let scale = displayScale
			_ = await Task.detached(priority: .utility) {
				EmojiAtlas.generateIfNeeded(scale: scale)
			}.value
		}
		.onAppear { refreshInstallState() }
		.task { await commercial.refresh() }
		.onChange(of: scenePhase) { _, phase in
			if phase == .active { refreshInstallState() }
			#if RESEARCH_BETA
			if phase == .active || phase == .background, KBTypingRecorder.installID != nil {
				Task.detached(priority: .utility) { await ResearchUploader.uploadPending() }
				ResearchUploader.scheduleBackgroundRefresh()
			}
			#endif
		}
		#if RESEARCH_BETA
		.onAppear {
			if !researchNoticeShown && !ProcessInfo.processInfo.arguments.contains("-ui-testing-used-keyboard") {
				showResearchNotice = true
			}
		}
		.alert("Typing Research", isPresented: $showResearchNotice) {
			Button("OK") { researchNoticeShown = true }
		} message: {
			Text("This beta records your typing to improve Glyph. You can turn it off in Typing Research.")
		}
		#endif
		.alert("Reset learned words?", isPresented: $showResetConfirm) {
			Button("Reset", role: .destructive, action: resetUserData)
			Button("Cancel", role: .cancel) { }
		} message: {
			Text("Clears all words you have typed, autocorrect history, and swipe-style adaptations. The base dictionary and other settings are not affected.")
		}
		.alert("Delete all keyboard data?", isPresented: $showDeleteAllConfirm) {
			Button("Delete All", role: .destructive, action: deleteAllData)
			Button("Cancel", role: .cancel) { }
		} message: {
			Text("Deletes learned language data, Glide adaptation, emoji recents, diagnostics, and custom appearance data. This cannot be undone.")
		}
	}

	private func refreshInstallState() {
		hasUsedKeyboard = KBSettings.hasUsedKeyboard
	}

	private var keyboardStatusValue: String {
		guard let seen = KBSettings.keyboardLastSeenAt else { return "Not opened" }
		return Date().timeIntervalSince(seen) < 7 * 24 * 60 * 60 ? "Seen recently" : "Check status"
	}

	private func resetUserData() {
		KBPersonalData.resetLearning()
	}

	private func deleteAllData() {
		KBPersonalData.resetAll()
		store.reload()
	}

}

private struct CommercialHomeCarousel: View {
	@ObservedObject var commercial: CommercialStore

	var body: some View {
		ScrollView(.horizontal) {
			HStack(spacing: 10) {
				NavigationLink {
					RewardCenterView(store: commercial)
				} label: {
					carouselCard(title: "Theme rewards", subtitle: "Offers and unlocks",
						symbol: "gift.fill", colors: [.pink, .purple])
				}
				NavigationLink {
					ThemeStudioView()
				} label: {
					carouselCard(title: "Theme collection", subtitle: "Browse appearance",
						symbol: "paintpalette.fill", colors: [.teal, .blue])
				}
			}
			.padding(.horizontal, 20)
		}
		.scrollIndicators(.hidden)
		.frame(height: 108)
	}

	private func carouselCard(title: String, subtitle: String, symbol: String,
						  colors: [Color]) -> some View {
		HStack(spacing: 14) {
			Image(systemName: symbol)
				.font(.system(size: 24, weight: .semibold))
				.frame(width: 36)
			VStack(alignment: .leading, spacing: 4) {
				Text(title).font(.headline)
				Text(subtitle).font(.subheadline).opacity(0.82)
			}
			Spacer(minLength: 4)
			Image(systemName: "chevron.right").font(.caption.weight(.bold)).opacity(0.7)
		}
		.foregroundStyle(.white)
		.padding(16)
		.frame(width: 270, height: 100)
		.background(
			LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
			in: RoundedRectangle(cornerRadius: 8, style: .continuous)
		)
	}
}

private struct RewardCenterView: View {
	@ObservedObject var store: CommercialStore

	var body: some View {
		List {
			Section("Available") {
				if store.products.isEmpty && store.campaigns.isEmpty {
					Text(store.storeError ?? "No offers available right now.")
						.foregroundStyle(.secondary)
				}
				ForEach(store.products, id: \.id) { product in
					Button {
						Task { await store.purchase(product) }
					} label: {
						HStack {
							VStack(alignment: .leading, spacing: 3) {
								Text(product.displayName).foregroundStyle(.primary)
								Text(product.description).font(.footnote).foregroundStyle(.secondary)
							}
							Spacer()
							Text(store.purchasedProductIDs.contains(product.id)
								 ? "Owned" : product.displayPrice)
								.font(.subheadline.weight(.semibold))
						}
					}
					.disabled(store.purchasedProductIDs.contains(product.id))
				}
			}

			Section {
				ForEach(OfferInterest.allCases) { interest in
					Toggle(isOn: Binding(
						get: { store.interests.contains(interest) },
						set: { store.setInterest(interest, enabled: $0) }
					)) {
						Label(interest.title, systemImage: interest.symbol)
					}
				}
			} header: {
				Text("Interests")
			} footer: {
				Text("Offer matching uses only choices made here, saved merchants, and confirmed offer activity. Typed text, host-app identity, and installed apps are never used.")
			}
		}
		.navigationTitle("Offers & Rewards")
		.navigationBarTitleDisplayMode(.inline)
		.refreshable { await store.refresh() }
	}
}

private struct SetupSupportView: View {
	@State private var access = KBSettings.lastFullAccess
	@State private var observedAt = KBSettings.lastFullAccessObservedAt
	@State private var lastSeen = KBSettings.keyboardLastSeenAt
	@State private var resetStatus = KBPersonalData.resetStatus

	var body: some View {
		List {
			Section("Keyboard") {
				statusRow("Last opened", value: lastSeen?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
				statusRow("Full Access", value: access ? "On" : "Off or unknown")
				if let observedAt {
					statusRow("Last checked", value: observedAt.formatted(date: .abbreviated, time: .shortened))
				}
				if resetStatus.requested > 0 {
					let value = resetStatus.failure != nil
						? "Storage cleanup failed"
						: (resetStatus.acknowledged >= resetStatus.requested
							? "Confirmed" : "Open the keyboard to finish")
					statusRow("Data reset", value: value)
				}
			}
			Section("Setup") {
				Button(action: openSettings) {
					Label("Open Keyboard Settings", systemImage: "gear")
				}
				Text("Add Glyph under Keyboards, then switch to it with the input-mode key. Open Glyph once in any text field to refresh the status above.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Section("Troubleshooting") {
				troubleshooting("Glyph is missing", "Confirm it remains enabled in Keyboard Settings, then reopen the host app.")
				troubleshooting("iOS switches keyboards", "Secure fields and some managed apps can require the system keyboard. This is controlled by iOS.")
				troubleshooting("No haptic feedback", "Confirm Haptic Feedback is on, then test on a physical iPhone. iOS controls whether third-party keyboard feedback is available.")
			}
			Section("About") {
				statusRow("Version", value: version)
			}
		}
		.navigationTitle("Setup & Support")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear(perform: refresh)
	}

	private func refresh() {
		access = KBSettings.lastFullAccess
		observedAt = KBSettings.lastFullAccessObservedAt
		lastSeen = KBSettings.keyboardLastSeenAt
		resetStatus = KBPersonalData.resetStatus
	}

	private func openSettings() {
		guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
		UIApplication.shared.open(url)
	}

	private var version: String {
		let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
		let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
		return "\(short) (\(build))"
	}

	private func statusRow(_ title: String, value: String) -> some View {
		HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
	}

	private func troubleshooting(_ title: String, _ detail: String) -> some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(title).font(.subheadline.weight(.semibold))
			Text(detail).font(.footnote).foregroundStyle(.secondary)
		}
		.padding(.vertical, 2)
	}
}

private struct PrivacyDataView: View {
	var body: some View {
		List {
			Section("Typing") {
				Text("Typing, autocorrect, suggestions, and Glide are processed on your device. Glyph only transmits the text you type through Typing Research, which beta builds turn on.")
			}
			#if RESEARCH_BETA
			Section("Typing Research (beta)") {
				Text("On for beta testers. While it is on, Glyph records the words you type in ordinary text fields, your touches and swipe paths, and what you do with suggestions and corrections, and uploads them automatically, encrypted, to the Glyph developer to improve typing and Glide. Password, email, phone, number, address and code fields are never recorded. You can stop and delete at any time in Typing Research.")
			}
			#endif
			Section("On-device storage") {
				privacyRow("Personalization", "Word and context counts used to improve suggestions. Stored in the shared app container until reset.")
				privacyRow("Appearance", "Theme choices remain on this device until changed or deleted.")
				privacyRow("Diagnostics", "Aggregate latency, memory, and storage-health counters. Typed text is never included. With Typing Research on, these counters are uploaded with your recordings.")
			}
			Section("Full Access") {
				Text("The keyboard remains usable without Full Access. Full Access enables shared settings, on-device learning persistence, and media search. Haptics stay local. Only a GIF or Sticker query you explicitly submit is sent to KLIPY; surrounding typed text is never included.")
			}
			Section("Control") {
				Text("Use Reset learned words to remove language personalization, or Delete all keyboard data to remove all user-generated data in the shared container. You can revoke Full Access at any time in iOS Settings.")
			}
			Section {
				Text("Effective July 19, 2026")
					.foregroundStyle(.secondary)
			}
		}
		.navigationTitle("Privacy & Data")
		.navigationBarTitleDisplayMode(.inline)
	}

	private func privacyRow(_ title: String, _ detail: String) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title).font(.subheadline.weight(.semibold))
			Text(detail).font(.footnote).foregroundStyle(.secondary)
		}
		.padding(.vertical, 3)
	}
}

private struct ThirdPartyNoticesView: View {
	private let notices: String = {
		guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
			  let value = try? String(contentsOf: url, encoding: .utf8) else {
			return "Third-party notices are unavailable in this build."
		}
		return value
	}()

	var body: some View {
		ScrollView {
			Text(notices)
				.font(.footnote)
				.frame(maxWidth: .infinity, alignment: .leading)
				.textSelection(.enabled)
				.padding(20)
		}
		.navigationTitle("Notices")
		.navigationBarTitleDisplayMode(.inline)
	}
}

struct DiagnosticsView: View {
	@State private var snap = KBDiagnostics.read()
	@State private var verbose = KBDiagnostics.verbose
	@State private var glideCapture = KBSettings.glideCapture
	@State private var panelHeaderPin = KBExperiments.panelHeaderOverride?.rawValue ?? ""
	@State private var typingCapture = KBTypingRecorder.enabled
	@State private var typingExport: URL?
	@State private var captureStatus = ""
	@State private var liveProbe = ""
	private let log = Logger(subsystem: KBSettings.appGroup, category: "diag-app")

	var body: some View {
		List {
			Section {
				TimelineView(.periodic(from: .now, by: 1)) { context in
					row("Keyboard memory now", keyboardMemory(at: context.date))
						.accessibilityElement(children: .combine)
						.accessibilityIdentifier("health.memory.now")
				}
				TextField("Type here to watch it live", text: $liveProbe)
					.accessibilityIdentifier("health.memory.probe")
				row("Peak footprint", mb(snap.peakFootprintMB))
				row("Lowest headroom", snap.minAvailableMB > 0 ? mb(snap.minAvailableMB) : "—")
				row("Inferred kill limit", snap.limitMB > 0 ? mb(snap.limitMB) : "—")
				row("Peak CPU (dynamic search)", snap.peakCPUPercent.map { String(format: "%.0f%%", $0) } ?? "—")
				row("Memory warnings", "\(snap.warningCount)")
				row("Critical events", "\(snap.criticalCount)")
			} header: {
				Text("Memory & CPU")
			} footer: {
				Text("iOS can terminate a keyboard extension under memory pressure. \"Now\" is live while the keyboard is open, otherwise its latest reading and how old it is; the peak is the highest ever seen and never falls. Peak CPU is sampled while a search is running (can exceed 100% across cores). These counters contain no typed text.")
			}

			if let log = snap.surfaceLog, !log.isEmpty {
				Section {
					ForEach(Array(log.reversed().enumerated()), id: \.offset) { _, entry in
						Text(entry).font(.footnote.monospacedDigit())
					}
				} header: {
					Text("Memory by surface")
				} footer: {
					Text("The keyboard's footprint when it switched surface, and one second later, after the previous surface was released. Newest first.")
				}
			}

			Section {
				row("This device", panelHeaderArmDescription())
				Picker("Header", selection: $panelHeaderPin) {
					Text("Random (assigned)").tag("")
					ForEach(PanelHeaderStyle.allCases, id: \.rawValue) { style in
						Text(style.displayName).tag(style.rawValue)
					}
				}
				.onChange(of: panelHeaderPin) { _, raw in
					KBExperiments.panelHeaderOverride = PanelHeaderStyle(rawValue: raw)
				}
				.accessibilityIdentifier("health.panelHeader.pin")
				ForEach(PanelHeaderStyle.allCases, id: \.rawValue) { style in
					VStack(alignment: .leading, spacing: 2) {
						Text(style.displayName)
						Text(panelEventSummary(for: style))
							.font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
					}
					.accessibilityElement(children: .combine)
				}
			} header: {
				Text("Panel header A/B test")
			} footer: {
				Text("Every install uses the unified (C) header. Pin the stacked (A) header to compare in a moderated session; it applies the next time a panel opens. Counts per arm: panels opened from the letters, searches started, tab switches, and emoji, GIFs or stickers picked. Counts only, no content.")
			}

			Section {
				row("Words / minute (WPM)", wpm())
				row("Keystrokes / char (KPC)", kpc())
			} header: {
				Text("Speed")
			} footer: {
				Text("WPM = committed words ÷ active typing time. KPC = physical taps (incl. backspaces) ÷ characters committed; predictions, picks, and glide push it below 1.0. Based on \(snap.wordsCommitted ?? 0) committed words.")
			}

			Section {
				row("Words Modified Ratio (WMR)", ratio(snap.wordsModified, snap.wordsCommitted))
				row("Next-word prediction hit", ratio(snap.nwpHits, snap.nwpOpportunities))
				row("Autocorrect rate", ratio(snap.wordsAutocorrected, snap.wordsCommitted))
				row("Autocorrect reverted", ratio(snap.correctionsReverted, snap.wordsAutocorrected))
			} header: {
				Text("Accuracy")
			} footer: {
				Text("WMR = committed words the user went back and edited ÷ words committed (lower is better). NWP hit = intended word already in the top-3 before the first letter. Reverted = autocorrections the user undid. Word Error Rate (WER) needs ground-truth intent and is measured offline (tools/evaluation/autocorrect) — not on device.")
			}

			Section {
				Toggle("Record typing on this device", isOn: $typingCapture)
					.onChange(of: typingCapture) { _, enabled in
						KBTypingRecorder.setEnabled(enabled)
						typingCapture = KBTypingRecorder.enabled
						typingExport = nil
					}
				Button("Prepare typing data export") {
					captureStatus = "Preparing…"
					KBTypingRecorder.export { url in
						typingExport = url
						captureStatus = url == nil ? "No records available, or storage unavailable." : "Export ready. Contains typed text."
					}
				}
				if let typingExport {
					ShareLink("Share typing data", item: typingExport)
				}
				Button("Stop recording and delete typing data", role: .destructive) {
					let deleted = KBTypingRecorder.clear()
					typingCapture = KBTypingRecorder.enabled
					typingExport = nil
					captureStatus = deleted ? "Typing records deleted." : "Deletion failed. Please retry."
				}
				if !captureStatus.isEmpty { Text(captureStatus).font(.footnote).foregroundStyle(.secondary) }
			} header: {
				Text("Typing research")
			} footer: {
				Text("On by default in beta builds. Records typed text, key timing, touches, Glide paths, suggestions and correction actions in general text fields. Ordinary text can still contain personal information. Beta builds upload the recordings automatically, encrypted, when the app opens or closes and every few hours in the background; up to 200 MB and 30 days wait on the device. An export adds one more copy. Delete removes what is on the device. Automatic corrections are unverified observations, not training labels. Share only when you intend to disclose the text.")
			}

			Section("Input integrity") {
				ForEach((snap.integrityEvents ?? [:]).keys.sorted(), id: \.self) { code in
					row(code, String(snap.integrityEvents?[code] ?? 0))
				}
				row("Storage failures", String(snap.storageFailureCount ?? 0))
			}

			Section {
				row("Inter-key interval p50", interKey(0.5))
				row("Inter-key interval p95", interKey(0.95))
				row("Backspace rate", ratio(snap.backspaceTaps, snap.physicalTaps))
				ForEach(errorProneKeys(), id: \.key) { item in
					row("Key \(item.key.uppercased()) erased", item.value)
				}
				ForEach(topConfusions(), id: \.key) { item in
					row("Typed \(item.key.replacingOccurrences(of: ">", with: " → retyped "))", "\(item.value)")
				}
			} header: {
				Text("Per-key errors & speed")
			} footer: {
				Text("Erased = letters removed by Backspace inside the word they were typed in ÷ taps on that key (keys with at least 20 taps). Typed → retyped = a letter erased and replaced by a different one. Counts only, from general text fields; no text is kept.")
			}

			Section("Latency histograms") {
				row("Host insert p95", latency(snap.hostInsertLatencyBins, 0.95))
				row("Tap decode p95", latency(snap.tapDecodeLatencyBins, 0.95))
				row("Init / UpdateLM p95", latency(snap.initLatencyBins, 0.95))
				row("Glide preview p95", latency(snap.glidePreviewLatencyBins, 0.95))
				row("Glide final p95", latency(snap.glideFinalLatencyBins, 0.95))
				row("Lift to insert p95", latency(snap.glideCommitLatencyBins, 0.95))
			}

			Section {
				Toggle("Verbose ranking log", isOn: $verbose)
					.onChange(of: verbose) { _, on in KBDiagnostics.verbose = on }
			} header: {
				Text("Live logging")
			} footer: {
				Text("Debug builds can log private candidate ranking locally. This facility is compiled out of Release builds.")
					.textSelection(.enabled)
			}

			Section {
				Toggle("Glide capture (debug)", isOn: $glideCapture)
					.onChange(of: glideCapture) { _, on in KBSettings.glideCapture = on }
				if let url = KBDiagnostics.glideCaptureURL,
				   let size = glideCaptureSize(url) {
					ShareLink(item: url) {
						Label("Export glide capture (\(size))", systemImage: "square.and.arrow.up")
					}
				} else {
					Text("No glide capture yet — enable the toggle, swipe some words, then reopen.")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Advanced")
			} footer: {
				Text("Glide capture records swipes to glide_capture.jsonl in the App Group container for offline calibration — on-device only and never uploaded. Restart the keyboard after changing this setting.")
					.textSelection(.enabled)
			}

			Section {
				if snap.updated == .distantPast {
					Text("No data yet — type with the keyboard, then reopen this screen.")
						.foregroundStyle(.secondary)
				} else {
					row("Updated", snap.updated.formatted(date: .abbreviated, time: .shortened))
				}
				Button("Refresh") { reload() }
				Button("Reset", role: .destructive) { resetDiagnostics() }
			}
		}
		.navigationTitle("Keyboard health")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear(perform: reload)
	}

	private func reload() {
		snap = KBDiagnostics.read()
		log.notice("diag peakMB=\(Int(snap.peakFootprintMB)) limitMB=\(Int(snap.limitMB)) warn=\(snap.warningCount) crit=\(snap.criticalCount)")
	}
	private func panelHeaderArmDescription() -> String {
		let style = KBExperiments.panelHeader
		return style.displayName + (KBExperiments.panelHeaderOverride == nil ? " (default)" : " (pinned)")
	}

	private func panelEventSummary(for style: PanelHeaderStyle) -> String {
		let events = snap.panelEvents ?? [:]
		func count(_ event: KBDiagnostics.PanelEvent) -> Int { events[style.arm + "." + event.rawValue] ?? 0 }
		let opens = count(.open), picks = count(.pick)
		var text = "\(opens) opens · \(count(.search)) searches · \(count(.tabSwitch)) switches · \(picks) picks"
		if opens > 0 { text += String(format: " (%.1f / open)", Double(picks) / Double(opens)) }
		return text
	}

	private func keyboardMemory(at now: Date) -> String {
		if let live = KBDiagnostics.liveFootprint() {
			let age = now.timeIntervalSince(live.at)
			return mb(live.megabytes) + (age < 3 ? " · live" : " · " + live.at.formatted(.relative(presentation: .named)))
		}
		guard let latest = snap.footprintNowMB else { return "—" }
		return mb(latest) + " · " + snap.updated.formatted(.relative(presentation: .named))
	}
	private func resetDiagnostics() {
		KBDiagnostics.reset()
		reload()
	}
	private func row(_ title: String, _ value: String) -> some View {
		HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
	}
	private func mb(_ v: Double) -> String { String(format: "%.1f MB", v) }
	private func ratio(_ numerator: Int?, _ denominator: Int?) -> String {
		guard let denominator, denominator > 0 else { return "\u{2014}" }
		let n = numerator ?? 0
		return String(format: "%.1f%% (%d/%d)", Double(n) / Double(denominator) * 100, n, denominator)
	}
	private func wpm() -> String {
		guard let words = snap.wordsCommitted, words > 0,
			let ms = snap.activeTypingMs, ms > 0 else { return "\u{2014}" }
		return String(format: "%.0f", Double(words) / (ms / 60_000))
	}
	private func kpc() -> String {
		guard let chars = snap.committedChars, chars > 0 else { return "\u{2014}" }
		return String(format: "%.2f", Double(snap.physicalTaps ?? 0) / Double(chars))
	}
	private func interKey(_ fraction: Double) -> String {
		KBDiagnostics.percentile(snap.interKeyIntervalBins, fraction: fraction,
			thresholds: KBDiagnostics.interKeyThresholds) ?? "—"
	}
	private func errorProneKeys() -> [(key: String, value: String)] {
		let taps: [String: Int] = snap.keyTaps ?? [:], erased: [String: Int] = snap.keyErasures ?? [:]
		var rows: [(key: String, rate: Double, taps: Int)] = []
		for (key, count) in taps where count >= 20 {
			let rate = Double(erased[key] ?? 0) / Double(count)
			if rate > 0 { rows.append((key: key, rate: rate, taps: count)) }
		}
		rows.sort { $0.rate == $1.rate ? $0.key < $1.key : $0.rate > $1.rate }
		return rows.prefix(5).map { row in
			(key: row.key, value: String(format: "%.1f%% of %d", row.rate * 100, row.taps))
		}
	}
	private func topConfusions() -> [(key: String, value: Int)] {
		(snap.keyConfusions ?? [:]).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
			.prefix(5).map { (key: $0.key, value: $0.value) }
	}
	private func latency(_ bins: [Int]?, _ fraction: Double) -> String {
		KBDiagnostics.percentile(bins, fraction: fraction) ?? "—"
	}
	private func glideCaptureSize(_ url: URL) -> String? {
		guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
			  let bytes = attrs[.size] as? Int, bytes > 0 else { return nil }
		return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
	}
}

func iconLabel(_ icon: String, tint: Color, title: String) -> some View {
	HStack(spacing: 12) {
		Image(systemName: icon)
			.font(.system(size: 15, weight: .semibold))
			.foregroundStyle(.white)
			.frame(width: 30, height: 30)
			.background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
		Text(title)
	}
}

struct SettingRow: View {
	let icon: String
	let tint: Color
	let title: String
	var value: String? = nil
	var trailingGradient: LinearGradient? = nil

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: icon)
				.font(.system(size: 15, weight: .semibold))
				.foregroundStyle(.white)
				.frame(width: 30, height: 30)
				.background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
			Text(title)
			Spacer()
			if let value {
				Text(value).foregroundStyle(.secondary)
			}
			if let trailingGradient {
				Circle().fill(trailingGradient).frame(width: 18, height: 18)
			}
		}
	}
}

private struct FirstRunView: View {
	@Environment(\.colorScheme) private var scheme
	let onContinue: () -> Void

	var body: some View {
		GeometryReader { geometry in
			ScrollView {
				VStack(spacing: 0) {
					Spacer(minLength: 46)
					appMark
						.padding(.bottom, 22)
					Text("Meet Glyph")
						.font(.system(size: 34, weight: .bold))
					Text("Better corrections, glide typing, and\nthemes - in every app you type in.")
						.font(.system(size: 17))
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.lineSpacing(4)
						.padding(.top, 16)
						.padding(.bottom, 34)

					VStack(spacing: 0) {
						Button(action: openSettings) {
							step(number: 1, text: "Open Settings and go to Keyboards")
						}
						.buttonStyle(.plain)
						Divider().padding(.leading, 64)
						step(number: 2, text: "Turn on Glyph", emphasized: "Glyph")
						Divider().padding(.leading, 64)
						step(number: 3, text: "In any app, hold the globe and pick Glyph")
						Divider().padding(.leading, 64)
						step(number: 4, text: "Make Glyph your main keyboard: tap Edit in Keyboards and drag Glyph to the top",
							emphasized: "main keyboard")
						Divider().padding(.leading, 64)
						step(number: 5, text: "Optional: allow Full Access for GIFs, clipboard and haptics",
							isOptional: true)
					}
					.background(Color(uiColor: .secondarySystemGroupedBackground),
						in: RoundedRectangle(cornerRadius: 8, style: .continuous))
					.padding(.horizontal, 24)

					Button(action: onContinue) {
						Text("I've turned on Glyph")
							.font(.headline)
							.frame(maxWidth: .infinity, minHeight: 50)
					}
					.buttonStyle(.borderedProminent)
					.padding(.horizontal, 24)
					.padding(.top, 24)
					.accessibilityIdentifier("onboarding.continue")

					Spacer(minLength: 48)
					#if RESEARCH_BETA
					Label("Beta: Glyph records your typing to improve it. You can turn this off in Typing Research.", systemImage: "shield")
						.font(.footnote)
						.foregroundStyle(.tertiary)
						.fixedSize(horizontal: false, vertical: true)
						.padding(.horizontal, 24)
						.padding(.bottom, 18)
					#else
					Label("Your typing stays on your iPhone.", systemImage: "shield")
						.font(.footnote)
						.foregroundStyle(.tertiary)
						.padding(.bottom, 18)
					#endif
				}
				.frame(maxWidth: .infinity, minHeight: geometry.size.height)
			}
		}
		.background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
		.toolbar(.hidden, for: .navigationBar)
		.accessibilityIdentifier("onboarding.firstRun")
	}

	private var appMark: some View {
		ZStack {
			LinearGradient(colors: [Color(uiColor: .systemBlue),
				Color(red: 0.35, green: 0.34, blue: 0.92)],
				startPoint: .topLeading, endPoint: .bottomTrailing)
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.fill(Color(uiColor: .systemBackground).opacity(scheme == .dark ? 0.92 : 0.88))
				.frame(width: 48, height: 48)
			Text("G")
				.font(.system(size: 24, weight: .bold, design: .rounded))
				.foregroundStyle(Color(red: 0.14, green: 0.22, blue: 0.42))
		}
		.frame(width: 96, height: 96)
		.clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
		.shadow(color: Color(uiColor: .systemBlue).opacity(0.18), radius: 18, y: 9)
		.accessibilityHidden(true)
	}

	private func step(number: Int, text: String, emphasized: String? = nil,
		isOptional: Bool = false) -> some View {
		HStack(spacing: 14) {
			Text("\(number)")
				.font(.system(size: 15, weight: .bold))
				.foregroundStyle(isOptional ? Color.secondary : Color.white)
				.frame(width: 30, height: 30)
				.background(isOptional ? Color(uiColor: .systemFill)
					: Color(uiColor: .systemBlue), in: Circle())
			if let emphasized, let range = text.range(of: emphasized) {
				(Text(text[..<range.lowerBound])
					+ Text(text[range]).bold()
					+ Text(text[range.upperBound...]))
					.foregroundStyle(isOptional ? .secondary : .primary)
					.fixedSize(horizontal: false, vertical: true)
					.frame(maxWidth: .infinity, alignment: .leading)
			} else {
				Text(text)
					.foregroundStyle(isOptional ? .secondary : .primary)
					.fixedSize(horizontal: false, vertical: true)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.font(.system(size: 16))
		.padding(.horizontal, 16)
		.padding(.vertical, 14)
		.contentShape(Rectangle())
	}

	private func openSettings() {
		guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
		UIApplication.shared.open(url)
	}
}

#Preview {
	ContentView()
}

private struct MainKeyboardPrompt: View {
	let done: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Label("Make Glyph your main keyboard", systemImage: "keyboard.badge.ellipsis")
				.font(.headline)
			Text("iOS shows the keyboard you used last. To get Glyph every time:")
				.font(.subheadline)
				.foregroundStyle(.secondary)
			VStack(alignment: .leading, spacing: 6) {
				Text("1. Settings › General › Keyboard › Keyboards")
				Text("2. Tap Edit and drag Glyph to the top")
				Text("3. For Glyph only, delete English (US) in the same list")
			}
			.font(.subheadline)
			HStack {
				Button("Open Settings") {
					if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
				}
				.buttonStyle(.borderedProminent)
				Spacer()
				Button("Done", action: done)
					.buttonStyle(.bordered)
			}
			.padding(.top, 4)
		}
		.padding(.vertical, 6)
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("prompt.mainKeyboard")
	}
}
