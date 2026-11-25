import UIKit

final class KeyboardView: UIView {

	var onInsert:         ((String, KeyTap?) -> Void)?
	var onDelete:         (() -> Void)?
	var onReturn:         (() -> Void)?
	var onCursorModeBegan: (() -> Void)?
	var onCursorMove:     ((Int) -> Void)?
	var onCursorModeEnded: (() -> Void)?
	var onReplaceLastInput: ((String, String) -> Void)?
	var onNextKeyboard:   (() -> Void)?
	var onInputModeEvent: ((UIView, UIEvent) -> Void)?
	var onPickSuggestion: ((String) -> Void)?
	var onHeightChange:   ((_ animated: Bool) -> Void)?
	var onGeometryChange: (() -> Void)?
	var onOpenMedia: ((KlipyKind) -> Void)?
	var onOpenClipboard: (() -> Void)?
	var onClipboardPick: ((String) -> Void)?
	var onPaste: (() -> Void)?

	struct TouchSample {
		let phase: String
		let id: UInt64
		let key: String?
		let time: TimeInterval
		let tap: KeyTap?
		let point: CGPoint
		let radius: CGFloat
	}
	var onTouchSample: ((TouchSample) -> Void)?
	var recordedTouches: [UITouch: (UInt64, String?, KeyTap?)] = [:]
	var recordsGlideSamples: (() -> Bool)?
	struct GlideSample { let point: CGPoint; let time: TimeInterval; let radius: CGFloat }
	var collectsGlideSamples = false
	var glideSamples: [GlideSample] = []
	var glideSampleStartKey: String?
	var nextRecordedTouch: UInt64 = 0
	var isRepeatingKey = false
	var activeTap: KeyTap?
	var charPriors: [Character: Double] = [:]
	var unitPitch: CGFloat = 30

	let theme: KeyboardTheme
	let deckLayer = CAGradientLayer()
	let showsGlobe: Bool
	var page: KeyboardSurfacePage = .letters
	var shift: ShiftState = .on
	var rows: [[KeyButton]] = []
	var emojiView: EmojiKeyboardView?
	var mediaView: MediaPanelView?
	var clipboardView: ClipboardPanelView?
	var mediaSearchHeader: EmojiSearchHeader?
	var mediaSearchStrip: MediaSearchStrip?
	var isMediaSearching = false
	var mediaQuery = ""
	var mediaSearchKind: KlipyKind = .gifs
	var mediaHasFullAccess = false
	var emojiSearchHeader: EmojiSearchHeader?
	var isEmojiSearching = false
	var emojiQuery = ""
	var letterKeys: [(base: String, key: KeyButton)] = []
	weak var shiftKey: KeyButton?
	weak var actionKey: KeyButton?
	var lastShiftTapAt: TimeInterval = 0
	var actionTitle: String?
	var actionEnabled = true
	let suggestionBar: SuggestionBar
	private(set) var inputKind: KeyboardInputKind = .standard
	var lastLayoutWidth: CGFloat = 0
	var lastLayoutProfile: KeyboardLayoutMetrics.Profile?

	var hapticsEnabled = false
	let keyHaptic = UISelectionFeedbackGenerator()
	let actionHaptic = UIImpactFeedbackGenerator(style: .light)

	func prepareHaptics() {
		guard hapticsEnabled else { return }
		keyHaptic.prepare()
		actionHaptic.prepare()
	}

	var onGlide: (([CGPoint], [TimeInterval], GlideLayout) -> Void)?
	var onGlideBegan: (() -> Void)?
	var onGlidePreview: (([CGPoint], [TimeInterval], GlideLayout) -> Void)?
	var onGlideCancelled: (() -> Void)?
	var glideEnabled = true
	var spaceBadge: String? {
		didSet {
			guard spaceBadge != oldValue else { return }
			for key in rows.joined() where key.isSpace { key.setTitle(spaceTitle) }
		}
	}
	var spaceTitle: String { spaceBadge.map { "space · \($0)" } ?? "space" }
	var glideTouch: UITouch?
	var glide: GlideTrack?
	let trailLayer = CAShapeLayer()
	let trailHeadLayer = CAShapeLayer()
	var lastGlidePreviewTime: TimeInterval = 0
	let glidePreviewInterval: TimeInterval = 0.035
	var glideThreshold: CGFloat { unitPitch * 0.85 }
	static let stripHeight: CGFloat = 48
	private var stripHeight: CGFloat { Self.stripHeight }
	var metrics: KeyboardLayoutMetrics {
		let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
		let base = KeyboardLayoutMetrics.resolve(width: width,
			idiom: traitCollection.userInterfaceIdiom)
		return base
	}
	var keySpacing: CGFloat { metrics.keySpacing }
	var rowSpacing: CGFloat { metrics.rowSpacing }
	var rowHeight: CGFloat { metrics.rowHeight }
	var sidePad: CGFloat { metrics.sidePadding }
	var topPad: CGFloat { metrics.topPadding }
	private var botPad: CGFloat { metrics.bottomPadding }
	private let collapsedTopPad: CGFloat = 0
	var stripSpace: CGFloat { showsSuggestions ? stripHeight : collapsedTopPad }
	var headerSpace: CGFloat {
		(isEmojiSearching || isMediaSearching) ? EmojiSearchHeader.height : stripSpace
	}
	private var expansionSpace: CGFloat {
		page == .media || page == .emoji ? Self.mediaExpansion : 0
	}
	var keyboardHeight: CGFloat {
		let count = 4
		return headerSpace + expansionSpace + topPad + rowHeight * CGFloat(count)
			+ rowSpacing * CGFloat(max(0, count - 1)) + botPad
	}
	var displayedActionTitle: String? { isMediaSearching ? "search" : actionTitle }
	var displayedActionEnabled: Bool { isMediaSearching || actionEnabled }

	var touchKeys: [UITouch: KeyButton] = [:]
	var touchPopups: [UITouch: UIView] = [:]
	var balloonPool: [KeyBalloonView] = []
	var popupShownAt: [UITouch: TimeInterval] = [:]
	var poppedKeys: [UITouch: KeyButton] = [:]
	var alternativeTimers: [UITouch: Timer] = [:]
	var alternativePopups: [UITouch: KeyAlternativesView] = [:]
	var repeatTimer: Timer?
	var repeatTouch: UITouch?
	weak var repeatKey: KeyButton?
	var cursorTimer: Timer?
	weak var cursorTouch: UITouch?
	weak var cursorKey: KeyButton?
	var cursorStartX: CGFloat = 0
	var cursorStep = 0
	var isCursorTracking = false

	var shiftSymbol: String {
		switch shift { case .off: return "shift"; case .on: return "shift.fill"; case .locked: return "capslock.fill" }
	}

	init(theme: KeyboardTheme, showsGlobe: Bool = true) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		self.suggestionBar = SuggestionBar(theme: theme)
		super.init(frame: .zero)
		accessibilityIdentifier = "glyph.keyboard"
		backgroundColor = .clear
		isOpaque = false
		layer.isOpaque = false
		deckLayer.startPoint = CGPoint(x: 0.5, y: 0)
		deckLayer.endPoint = CGPoint(x: 0.5, y: 1)
		layer.insertSublayer(deckLayer, at: 0)
		updateBackdrop()
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(reduceTransparencyDidChange),
			name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(reduceTransparencyDidChange),
			name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
			object: nil
		)
		trailLayer.fillColor = nil
		trailLayer.lineWidth = 8
		trailLayer.lineCap = .round
		trailLayer.lineJoin = .round
		trailLayer.strokeColor = theme.accentStart.withAlphaComponent(0.38).cgColor
		trailHeadLayer.fillColor = theme.accentStart.withAlphaComponent(0.46).cgColor
		trailHeadLayer.strokeColor = UIColor.white.withAlphaComponent(0.16).cgColor
		trailHeadLayer.lineWidth = 1
		layer.addSublayer(trailLayer)
		layer.addSublayer(trailHeadLayer)
		isMultipleTouchEnabled = true
		addSubview(suggestionBar)
		suggestionBar.isHidden = !showsSuggestions
		suggestionBar.onPick = { [weak self] in self?.onPickSuggestion?($0) }
        suggestionBar.onSelectTool = { [weak self] tool in
            guard let self else { return }
            switch tool {
            case .clipboard: self.onOpenClipboard?()
            case .emoji: self.showEmoji()
            case .gifs: self.onOpenMedia?(.gifs)
            case .stickers: self.onOpenMedia?(.stickers)
            }
        }
		reload()
	}
	required init?(coder: NSCoder) { fatalError() }
	deinit {
		repeatTimer?.invalidate()
		cursorTimer?.invalidate()
		alternativeTimers.values.forEach { $0.invalidate() }
		NotificationCenter.default.removeObserver(self)
	}

	private var suggestionsRequested = true
	var showsSuggestions: Bool { suggestionsRequested && !inputKind.usesDedicatedNumberPad }

	func setShowsSuggestions(_ on: Bool) {
		guard on != suggestionsRequested else { return }
		suggestionsRequested = on
		suggestionBar.isHidden = !showsSuggestions
		setNeedsLayout()
	}

	@discardableResult
	func setInputKind(_ kind: KeyboardInputKind) -> Bool {
		guard inputKind != kind else { return false }
		inputKind = kind
		page = kind == .numbersAndPunctuation || kind.usesDedicatedNumberPad ? .numbers : .letters
		shift = kind == .standard ? shift : .off
		suggestionBar.isHidden = !showsSuggestions
		reload()
		setNeedsLayout()
		return true
	}
}
