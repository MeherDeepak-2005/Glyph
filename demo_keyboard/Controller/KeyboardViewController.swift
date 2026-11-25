import UIKit

final class KeyboardViewController: UIInputViewController {

	var keyboard: KeyboardView!
	var heightConstraint: NSLayoutConstraint?
	var keyboardHeightConstraint: NSLayoutConstraint?
	private var heightMismatchActive = false
	let engine = KeyboardEngine.shared
	private var personalDataResetObserver: KBPersonalDataResetObserver?
	private var configurationObserver: KBConfigurationObserver?
	private var accessibilityObservers: [NSObjectProtocol] = []

	enum Mode { case predict, complete(String), revert(String), glided(String) }
	var mode: Mode = .predict
	var generation: UInt64 = 0
	var fieldRevision: UInt64 = 0
	var documentRevision: UInt64 = 0
	var wordSessionID: UInt64 = 0
	var layoutRevision: UInt64 = 0
	var fieldInputKind: KeyboardInputKind = .standard
	var decodeSnapshot: DecodeSnapshot?
	var presentedDecodeSnapshot: PresentedDecodeSnapshot?
	var currentWordBuffer = ""
	var currentContextBuffer: [String] = []
	var nwpPredictedTop3: Set<String> = []
	var nwpPredictionArmed = false
	var suggestionModeResolved = false
	var suggestionsVisible = true
	var hostConnectionReady = false
	var supplementaryLexiconRequested = false
	var contactNamesLoadedAt: Date?
    var documentReconciler = HostDocumentReconciler()
    var recoveryMonitor: HostDocumentRecoveryMonitor?
    var presentationDocument: HostDocumentSnapshot?
    var expectedLetterInsertion: String?

	enum SuggestionPresentation {
		case ranked(words: [String], prefix: String?, highlightPrimary: Bool)
		case glide(winner: String, alternatives: [String])
	}
	var suggestionPresentation = SuggestionPresentation.ranked(words: [], prefix: nil, highlightPrimary: false)
	struct GlidePreviewRequest {
		let path: [CGPoint]
		let times: [TimeInterval]
		let layout: GlideLayout
		let sequence: Int
	}
	var pendingGlidePreview: GlidePreviewRequest?
	var glidePreviewInFlight = false
	var glidePreviewGeneration = 0
	var glidePreviewSequence = 0
	var activeGlideDocumentContext: String?
	var activeGlideContext: [String] = []
	var activeGlideAutoShift = false
	var activeGlideSessionID: GlideSessionID?
	var glidePreviewEnabled = false
	struct DisplayedGlidePrediction {
		let prediction: GlidePrediction
		let sessionID: GlideSessionID
		let revision: UInt64
		let pointCount: Int
		let endpoint: CGPoint
		let pitch: CGFloat
	}
	var displayedGlidePrediction: DisplayedGlidePrediction?

	struct Correction {
		let original: String
		let corrected: String
		var trailing: String
		let fromAutocorrect: Bool
		var recordedWordSessionID: UInt64? = nil
		var appliedAt = ProcessInfo.processInfo.systemUptime
	}
	var lastCorrection: Correction?

	var erasedWord = ""
	var erasedCrossedBoundary = false
	var replacementStarted = false
	var recentCorrections: [(original: String, corrected: String, word: UInt64)] = []

	var wordTaps: [KeyTap?] = []

	struct TypingTrace {
		var keystrokes: [KBTypingRecorder.Keystroke] = []
		var startedAt: Double?
		var backspaces = 0
		var erasedLetters: [Character] = []
	}
	var typingTrace = TypingTrace()
	var lastKeyUptime = 0.0
	struct PendingGlideRecord {
		let samples: [KeyboardView.GlideSample]
		let startKey: String?
		let previews: Int
		let liftAt: Double
	}
	var pendingGlideRecord: PendingGlideRecord?
	struct RecordedWordFollowUp {
		let kind: String
		let wordID: UInt64
		let enteredAt: Double
		let length: Int
		var tail: String
		var continued = false
		var hasNewTyping = false
		var backspaced = false
	}
	var recordedWordFollowUps: [RecordedWordFollowUp] = []
	var glidePreviewCount = 0
	struct RecordedLayout: Equatable {
		let revision: UInt64
		let view: ObjectIdentifier
		let size: CGSize
		let page: KeyboardSurfacePage
	}
	var recordedLayout: RecordedLayout?
	var recordedAcceptance: UInt64?

	var pendingGlideVerdict = false
	var pendingGlideStatsID: UUID?

	var showsGlobe = false

	let boundary = CharacterSet(charactersIn: " .,!?;:")

	override func loadView() {
		let root = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
		root.allowsSelfSizing = true
		view = root
	}

	func updateKeyboardHeight(animated: Bool = false) {
		guard let keyboard else { return }
		let desired = keyboard.keyboardHeight
		guard desired.isFinite, desired > 0 else { return }
		let current = keyboardHeightConstraint?.constant ?? desired
		applyKeyboardHeight(desired)
		guard animated, abs(current - desired) > 1, view.window != nil,
			!UIAccessibility.isReduceMotionEnabled else { return }
		UIView.performWithoutAnimation { view.layoutIfNeeded() }
		animateHeightChange(by: desired - current, in: keyboard)
	}

	static let heightAnimationDuration: CFTimeInterval = 0.32

	private func animateHeightChange(by delta: CGFloat, in keyboard: UIView) {
		let rise = CABasicAnimation(keyPath: "transform.translation.y")
		rise.fromValue = delta > 0 ? delta : min(18, -delta)
		rise.toValue = 0
		let fade = CABasicAnimation(keyPath: "opacity")
		fade.fromValue = delta > 0 ? 0.35 : 0
		fade.toValue = 1
		fade.duration = delta > 0 ? 0.18 : 0.22
		let group = CAAnimationGroup()
		group.animations = [rise, fade]
		group.duration = Self.heightAnimationDuration
		rise.duration = group.duration
		group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
		group.fillMode = .backwards
		keyboard.layer.add(group, forKey: "heightChange")
	}

	func applyKeyboardHeight(_ height: CGFloat) {
		rootInputView?.desiredHeight = height
		if heightConstraint?.constant != height { heightConstraint?.constant = height }
		if keyboardHeightConstraint?.constant != height { keyboardHeightConstraint?.constant = height }
		let size = CGSize(width: view.bounds.width, height: height)
		if preferredContentSize != size { preferredContentSize = size }
	}

	private var rootInputView: KeyboardInputView? { view as? KeyboardInputView }

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		updateKeyboardHeight()
		if let keyboard, view.window != nil {
			let mismatch = abs(view.bounds.height - keyboard.keyboardHeight) > 2
			if mismatch && !heightMismatchActive { KBDiagnostics.noteIntegrityEvent("keyboard-height-mismatch") }
			heightMismatchActive = mismatch
		}
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .clear
		view.isOpaque = false
		view.layer.isOpaque = false
		inputView?.backgroundColor = .clear
		inputView?.isOpaque = false
		buildKeyboard()
		personalDataResetObserver = KBPersonalDataResetObserver { [weak self] epoch in
			guard let self else { return }
			self.engine.resetPersonalization(to: epoch)
			DispatchQueue.main.async { [weak self] in self?.handlePersonalDataReset() }
		}
		configurationObserver = KBConfigurationObserver { [weak self] in
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				self.buildKeyboard()
				if self.hostConnectionReady { self.scheduleSuggestions() }
			}
		}

		registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
			self.buildKeyboard()
			if self.hostConnectionReady { self.scheduleSuggestions() }
		}
		let accessibilityNotifications: [Notification.Name] = [
			UIAccessibility.boldTextStatusDidChangeNotification,
			UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
			UIAccessibility.differentiateWithoutColorDidChangeNotification,
			UIAccessibility.reduceTransparencyStatusDidChangeNotification,
			UIAccessibility.reduceMotionStatusDidChangeNotification,
		]
		for name in accessibilityNotifications {
			accessibilityObservers.append(NotificationCenter.default.addObserver(
				forName: name, object: nil, queue: .main) { [weak self] _ in
					guard let self else { return }
					self.buildKeyboard()
					if self.hostConnectionReady { self.scheduleSuggestions() }
				})
		}
	}

	deinit {
		for observer in accessibilityObservers { NotificationCenter.default.removeObserver(observer) }
		#if DEBUG
		liveMemoryTimer?.invalidate()
		#endif
	}

	private func handlePersonalDataReset() {
		KBStats.synchronizeAfterExternalReset()
		invalidateSuggestionRequests(cancelEngineWork: true)
		cancelGlidePreview(clearStrip: true)
		lastCorrection = nil
		recentCorrections.removeAll(keepingCapacity: false)
		wordTaps.removeAll(keepingCapacity: false)
		pendingGlideVerdict = false
		KBStats.cancel(pendingGlideStatsID)
		pendingGlideStatsID = nil
		cursorModeActive = false
		resetEraseTracking()
		mode = .predict
		suggestionPresentation = .ranked(words: [], prefix: nil, highlightPrimary: false)
		applySuggestionPresentation(to: keyboard)
		if hostConnectionReady { scheduleSuggestions() }
	}

	private func currentTheme() -> KeyboardTheme {
		.system(dark: traitCollection.userInterfaceStyle == .dark)
	}

	func buildKeyboard() {
		keyboard?.removeFromSuperview()
		heightConstraint?.isActive = false
		heightConstraint = nil
		keyboardHeightConstraint = nil

		let theme = currentTheme()
		view.backgroundColor = .clear
		view.isOpaque = false
		view.layer.isOpaque = false
		inputView?.backgroundColor = .clear
		inputView?.isOpaque = false

		let kb = KeyboardView(theme: theme, showsGlobe: showsGlobe)
		kb.isUserInteractionEnabled = hostConnectionReady
		kb.accessibilityElementsHidden = !hostConnectionReady
		kb.hapticsEnabled   = KBSettings.haptics
		kb.glideEnabled     = true
		showModelTier(on: kb)
		let touchViewID = UUID().uuidString
		kb.onTouchSample = { [weak self, weak kb] sample in
			guard let self, let kb, self.keyboard === kb,
				!kb.isEmojiSearching, !kb.isMediaSearching else { return }
			if sample.phase == "touch-down" { self.recordLayoutIfNeeded() }
			self.recordTyping(sample.phase, text: sample.key, tap: sample.tap, touchID: "\(touchViewID):\(sample.id)",
				point: sample.point, radius: sample.radius, at: sample.time)
		}
		kb.recordsGlideSamples = { [weak self] in
			guard let self else { return false }
			return KBTypingRecorder.enabled && self.permitsTypingData
		}
		kb.onInsert         = { [weak self] ch, tap in self?.handleInsert(ch, tap: tap) }
		kb.onReplaceLastInput = { [weak self] base, replacement in
			self?.handleReplaceLastInput(base: base, with: replacement)
		}
		kb.onDelete         = { [weak self] in self?.handleDelete() }
		kb.onReturn         = { [weak self] in self?.handleReturn() }
		kb.onCursorModeBegan = { [weak self] in self?.beginCursorMode() }
		kb.onCursorMove     = { [weak self] in self?.moveCursor(by: $0) }
		kb.onCursorModeEnded = { [weak self] in self?.endCursorMode() }
		kb.onNextKeyboard   = { [weak self] in self?.advanceToNextInputMode() }
		kb.onInputModeEvent = { [weak self] sender, event in
			self?.handleInputModeList(from: sender, with: event)
		}
		kb.onPickSuggestion = { [weak self] in self?.handlePick($0) }
		kb.onOpenMedia = { [weak self, weak kb] kind in
			guard let self, let kb, self.keyboard === kb else { return }
			kb.showMedia(kind: kind, hasFullAccess: self.hasFullAccess)
		}
		kb.onOpenClipboard = { [weak self, weak kb] in
			guard let self, let kb, self.keyboard === kb else { return }
			self.captureClipboardIfNeeded()
			kb.showClipboard(hasFullAccess: self.hasFullAccess)
		}
		kb.onClipboardPick = { [weak self] in self?.handleClipboardPick($0) }
		kb.onPaste = { [weak self] in self?.handlePasteCurrentClipboard() }
		kb.onGlideBegan     = { [weak self] in self?.beginGlidePreview() }
		kb.onGlidePreview   = { [weak self] path, times, layout in
			self?.handleGlidePreview(path, times, layout)
		}
		kb.onGlideCancelled = { [weak self, weak kb] in
			guard let self else { return }
			self.holdGlideSamples(from: kb, liftAt: ProcessInfo.processInfo.systemUptime)
			self.recordGlide(outcome: "cancelled")
			self.cancelGlidePreview(clearStrip: true)
		}
		kb.onGlide          = { [weak self] path, times, layout in self?.handleGlide(path, times, layout) }
		kb.onHeightChange   = { [weak self, weak kb] animated in
			guard let self, let kb, self.keyboard === kb else { return }
			self.updateKeyboardHeight(animated: animated)
		}
		kb.onGeometryChange = { [weak self, weak kb] in
			guard let self, let kb, self.keyboard === kb else { return }
			self.layoutRevision &+= 1
			self.invalidateSuggestionRequests(cancelEngineWork: true)
			if self.hostConnectionReady { self.scheduleSuggestions() }
		}

		kb.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(kb)
		NSLayoutConstraint.activate([
			kb.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			kb.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			kb.bottomAnchor.constraint(equalTo: view.bottomAnchor)
		])
		let kh = kb.heightAnchor.constraint(equalToConstant: kb.keyboardHeight)
		kh.isActive = true
		keyboardHeightConstraint = kh
		let h = view.heightAnchor.constraint(equalToConstant: kb.keyboardHeight)
		h.priority = .required - 1
		h.isActive = true
		heightConstraint = h
		keyboard = kb
		kb.setInputKind(fieldInputKind)
		kb.prepareHaptics()
		if suggestionModeResolved {
			kb.setShowsSuggestions(suggestionsVisible)
			applyKeyboardHeight(kb.keyboardHeight)
		}
		if hostConnectionReady { updateActionKey() }
		applySuggestionPresentation(to: kb)
		updateKeyboardHeight()
	}

	var currentDecodeSnapshot: DecodeSnapshot? {
		guard let snapshot = decodeSnapshot else { return nil }
		let request = snapshot.request
		guard request.fieldRevision == fieldRevision,
			  request.documentRevision == documentRevision,
			  request.wordSessionID == wordSessionID,
			  request.generation == generation,
			  request.layoutRevision == layoutRevision,
			  request.currentWord == currentWordBuffer,
			  request.context == currentContextBuffer else { return nil }
		return snapshot
	}
	var currentPresentedDecodeSnapshot: PresentedDecodeSnapshot? {
		guard let canonical = currentDecodeSnapshot,
			  let presented = presentedDecodeSnapshot,
			  presented.canonical == canonical else { return nil }
		return presented
	}

	var cursorModeActive = false

	#if DEBUG
	private var liveMemoryTimer: Timer?
	#endif

	var lastSpaceAt: TimeInterval = 0
	var lastReplaceDeleteCount = 0

	var isSecureField: Bool { textDocumentProxy.isSecureTextEntry ?? false }
	var suggestionsAllowed: Bool { !isSecureField }
	var autocorrectionAllowed: Bool {
		let p = textDocumentProxy
		if p.isSecureTextEntry ?? false { return false }
		if p.autocorrectionType == .no { return false }
		switch p.keyboardType {
		case .some(.URL), .some(.emailAddress), .some(.webSearch),
			 .some(.numberPad), .some(.phonePad), .some(.decimalPad),
			 .some(.namePhonePad), .some(.asciiCapableNumberPad):
			return false
		default:
			return true
		}
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		hostConnectionReady = false
		recordedLayout = nil
        documentReconciler.reset()
        presentationDocument = nil
        keyboard?.dismissTools()
        setSuggestionBar([])
		keyboard?.isUserInteractionEnabled = false
		keyboard?.accessibilityElementsHidden = true
		view.backgroundColor = .clear
		view.isOpaque = false
		inputView?.backgroundColor = .clear
		inputView?.isOpaque = false
		keyboard?.hapticsEnabled = KBSettings.haptics
		suggestionModeResolved = false
		suggestionsVisible = true
		keyboard?.setShowsSuggestions(true)
		if fieldInputKind != .standard {
			fieldInputKind = .standard
			layoutRevision &+= 1
			keyboard?.setInputKind(.standard)
		}
		keyboard?.glideEnabled = true
		if let keyboard { applyKeyboardHeight(keyboard.keyboardHeight) }
		invalidateDocumentSession()
		resetEraseTracking()
		wordTaps.removeAll(keepingCapacity: true)
		KBStats.confirm(pendingGlideStatsID)
		pendingGlideStatsID = nil
		pendingGlideVerdict = false
		cursorModeActive = false
		keyboard?.prepareHaptics()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
		if !hostConnectionReady { handleHostCallback() }
		#if DEBUG
		liveMemoryTimer?.invalidate()
		KBDiagnostics.noteLiveFootprint()
		let timer = Timer(timeInterval: 1, repeats: true) { _ in KBDiagnostics.noteLiveFootprint() }
		timer.tolerance = 0.25
		RunLoop.main.add(timer, forMode: .common)
		liveMemoryTimer = timer
		#endif
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		#if DEBUG
		liveMemoryTimer?.invalidate()
		liveMemoryTimer = nil
		KBDiagnostics.noteLiveFootprint()
		#endif
		hostConnectionReady = false
        recoveryMonitor?.stop()
        recoveryMonitor = nil
        invalidateSuggestionRequests(cancelEngineWork: true)
        cancelGlidePreview(clearStrip: true)
		keyboard?.isUserInteractionEnabled = false
		keyboard?.accessibilityElementsHidden = true
		KBStats.confirm(pendingGlideStatsID)
		pendingGlideStatsID = nil
		KBStats.flush()
		KBDiagnostics.finishTypingSession()
		KBTypingRecorder.flush()
	}

	override func didReceiveMemoryWarning() {
		super.didReceiveMemoryWarning()
		KBDiagnostics.recorder.memoryPressure(critical: false)
		keyboard?.releaseTransientMediaForMemoryPressure()
		engine.handleMemoryPressure()
	}

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        handleHostCallback()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        handleHostCallback()
    }
}
