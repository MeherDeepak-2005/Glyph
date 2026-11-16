import UIKit

extension KeyboardView {

	func showEmoji() {
		let opening = page == .letters && !isEmojiSearching && !isMediaSearching
		if isEmojiSearching { tearDownEmojiSearch() }
		guard page != .emoji else { return }
		let previous = mediaView.map { PanelTab($0.kind) }
		discardMediaPanel()
		page = .emoji
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = []
		letterKeys = []
		accessibilityElements = nil
		suggestionBar.isHidden = true
		let ev = EmojiKeyboardView(theme: theme, showsGlobe: showsGlobe, from: previous)
		ev.onPick = { [weak self] in self?.onInsert?($0, nil) }
		ev.onDelete = { [weak self] in self?.onDelete?() }
		ev.onNextKeyboard = { [weak self] in self?.onNextKeyboard?() }
		ev.onABC = { [weak self] in self?.hideEmoji() }
		ev.onSearch = { [weak self] in self?.showEmojiSearch() }
		ev.onGIF = { [weak self] in self?.onOpenMedia?(.gifs) }
		ev.onStickers = { [weak self] in self?.onOpenMedia?(.stickers) }
		addSubview(ev)
		emojiView = ev
		onHeightChange?(true)
		setNeedsLayout()
		if previous != nil { returnPanelMemory() }
		KBDiagnostics.recorder.sample()
		KBDiagnostics.noteSurface("emoji")
		if opening { KBDiagnostics.notePanelEvent(.open) }
	}
	private func hideEmoji() {
		emojiView?.removeFromSuperview()
		emojiView = nil
		page = .letters
		shift = .on
		suggestionBar.isHidden = !showsSuggestions
		reload()
		onHeightChange?(true)
		returnPanelMemory()
		KBDiagnostics.noteSurface("letters")
	}

	func showMedia(kind: KlipyKind, query: String? = nil, hasFullAccess: Bool) {
		mediaHasFullAccess = hasFullAccess
		let opening = page == .letters && !isEmojiSearching && !isMediaSearching
		if isEmojiSearching { tearDownEmojiSearch() }
		if isMediaSearching { tearDownMediaSearch() }
		let previous: PanelTab? = page == .emoji ? .emoji : nil
		emojiView?.removeFromSuperview(); emojiView = nil
		discardMediaPanel()
		page = .media
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = []
		letterKeys = []
		accessibilityElements = nil
		suggestionBar.isHidden = true
		let panel = MediaPanelView(theme: theme, showsGlobe: showsGlobe,
			hasFullAccess: hasFullAccess, kind: kind, query: query, from: previous)
		panel.onABC = { [weak self] in self?.hideMedia() }
		panel.onEmoji = { [weak self] in self?.showEmoji() }
		panel.onNextKeyboard = { [weak self] in self?.onNextKeyboard?() }
		panel.onSearch = { [weak self] in self?.showMediaSearch(kind: $0) }
		addSubview(panel)
		mediaView = panel
		onHeightChange?(true)
		setNeedsLayout()
		returnPanelMemory()
		KBDiagnostics.noteSurface(kind.rawValue)
		if opening { KBDiagnostics.notePanelEvent(.open) }
	}

	private func hideMedia() {
		discardMediaPanel()
		if isMediaSearching { tearDownMediaSearch() }
		page = .letters
		suggestionBar.isHidden = !showsSuggestions
		reload()
		onHeightChange?(true)
		returnPanelMemory()
		KBDiagnostics.noteSurface("letters")
	}

	func showClipboard(hasFullAccess: Bool) {
		if isEmojiSearching { tearDownEmojiSearch() }
		if isMediaSearching { tearDownMediaSearch() }
		emojiView?.removeFromSuperview(); emojiView = nil
		discardMediaPanel()
		guard page != .clipboard else { return }
		page = .clipboard
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = []
		letterKeys = []
		accessibilityElements = nil
		suggestionBar.isHidden = true
		let panel = ClipboardPanelView(theme: theme, showsGlobe: showsGlobe, hasFullAccess: hasFullAccess)
		panel.onPick = { [weak self] in self?.onClipboardPick?($0) }
        panel.onPasteCurrent = { [weak self] in self?.onPaste?() }
		panel.onABC = { [weak self] in self?.hideClipboard() }
		panel.onNextKeyboard = { [weak self] in self?.onNextKeyboard?() }
		addSubview(panel)
		clipboardView = panel
		onHeightChange?(true)
		setNeedsLayout()
		returnPanelMemory()
		KBDiagnostics.noteSurface("clipboard")
	}

	private func hideClipboard() {
		clipboardView?.removeFromSuperview()
		clipboardView = nil
		page = .letters
		shift = .on
		suggestionBar.isHidden = !showsSuggestions
		reload()
		onHeightChange?(true)
		returnPanelMemory()
		KBDiagnostics.noteSurface("letters")
	}

	private func showMediaSearch(kind: KlipyKind) {
		guard page == .media, !isMediaSearching else { return }
		discardMediaPanel()
		isMediaSearching = true
		mediaSearchKind = kind
		mediaQuery = ""
		page = .letters
		shift = .off
		suggestionBar.isHidden = true
		let header = EmojiSearchHeader(theme: theme)
		header.placeholder = kind == .gifs ? "Search GIFs" : "Search stickers"
		header.emptyStatus = ""
		header.noResultsStatus = ""
		header.onCancel = { [weak self] in self?.exitMediaSearch(submit: false) }
		header.onClear = { [weak self] in self?.mediaQuery = ""; self?.refreshMediaSearch() }
		addSubview(header)
		mediaSearchHeader = header
		let strip = MediaSearchStrip(theme: theme, kind: kind, hasFullAccess: mediaHasFullAccess)
		addSubview(strip)
		mediaSearchStrip = strip
		reload(); refreshMediaSearch(); onHeightChange?(true); setNeedsLayout()
	}

	private func refreshMediaSearch() {
		mediaSearchHeader?.update(query: mediaQuery, results: [], showingRecents: true)
		mediaSearchStrip?.search(mediaQuery)
	}

	private func tearDownMediaSearch() {
		mediaSearchHeader?.removeFromSuperview(); mediaSearchHeader = nil
		mediaSearchStrip?.prepareForDismissal()
		mediaSearchStrip?.removeFromSuperview(); mediaSearchStrip = nil
		isMediaSearching = false
	}

	private func discardMediaPanel() {
		mediaView?.prepareForDismissal()
		mediaView?.removeFromSuperview()
		mediaView = nil
	}

	private func returnPanelMemory() {
		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
			_ = malloc_zone_pressure_relief(nil, 0)
		}
	}

	private func exitMediaSearch(submit: Bool) {
		guard isMediaSearching else { return }
		let query = mediaQuery.trimmingCharacters(in: .whitespacesAndNewlines)
		mediaQuery = ""
		tearDownMediaSearch()
		showMedia(kind: mediaSearchKind, query: submit && !query.isEmpty ? query : nil,
			hasFullAccess: mediaHasFullAccess)
	}

	private func showEmojiSearch() {
		guard page == .emoji, !isEmojiSearching else { return }
		emojiView?.removeFromSuperview()
		emojiView = nil
		isEmojiSearching = true
		emojiQuery = ""
		page = .letters
		shift = .off
		suggestionBar.isHidden = true
		let header = EmojiSearchHeader(theme: theme)
		header.onCancel = { [weak self] in self?.exitEmojiSearch(backToEmoji: true) }
		header.onClear = { [weak self] in
			guard let self else { return }
			emojiQuery = ""
			refreshEmojiSearch()
		}
		header.onPick = { [weak self] e in
			KBDiagnostics.notePanelEvent(.pick)
			self?.onInsert?(e, nil)
			KBEmojiRecents.add(e)
		}
		addSubview(header)
		emojiSearchHeader = header
		reload()
		refreshEmojiSearch()
		onHeightChange?(true)
		setNeedsLayout()
	}

	private func tearDownEmojiSearch() {
		emojiSearchHeader?.removeFromSuperview()
		emojiSearchHeader = nil
		isEmojiSearching = false
		emojiQuery = ""
	}

	private func exitEmojiSearch(backToEmoji: Bool) {
		guard isEmojiSearching else { return }
		tearDownEmojiSearch()
		if backToEmoji {
			showEmoji()
		} else {
			suggestionBar.isHidden = !showsSuggestions
			reload()
			onHeightChange?(true)
			setNeedsLayout()
		}
	}

	@discardableResult
	func dismissOverlaysIfActive() -> Bool {
		if isEmojiSearching { exitEmojiSearch(backToEmoji: false); return true }
		if isMediaSearching { tearDownMediaSearch(); page = .letters; reload(); return true }
		if page == .emoji { hideEmoji(); return true }
		if page == .media { hideMedia(); return true }
		if page == .clipboard { hideClipboard(); return true }
		return false
	}

	func releaseTransientMediaForMemoryPressure() {
		_ = dismissOverlaysIfActive()
		EmojiAtlas.purgeShared()
		balloonPool.removeAll()
	}

	func refreshEmojiSearch() {
		guard let header = emojiSearchHeader else { return }
		let results = emojiQuery.isEmpty
			? KBEmojiRecents.all()
			: (EmojiStore.bundled?.search(emojiQuery) ?? [])
		header.update(query: emojiQuery, results: results, showingRecents: emojiQuery.isEmpty)
	}

	func routeInsert(_ s: String, _ tap: KeyTap?) {
        suggestionBar.dismissTools()
		if isEmojiSearching {
			emojiQuery += s.lowercased()
			refreshEmojiSearch()
			return
		}
		if isMediaSearching {
			mediaQuery += s.lowercased()
			refreshMediaSearch()
			return
		}
		onInsert?(s, tap)
	}
	func routeDelete() {
        suggestionBar.dismissTools()
		if isEmojiSearching {
			if !emojiQuery.isEmpty { emojiQuery.removeLast(); refreshEmojiSearch(); return }
		}
		if isMediaSearching, !mediaQuery.isEmpty {
			mediaQuery.removeLast(); refreshMediaSearch(); return
		}
		onDelete?()
	}
	func routeReturn() {
        suggestionBar.dismissTools()
		if isEmojiSearching { exitEmojiSearch(backToEmoji: true); return }
		if isMediaSearching { exitMediaSearch(submit: true); return }
		onReturn?()
	}

	func returnToLettersFromSymbolPage() {
		guard page == .numbers || page == .symbols else { return }
		page = .letters
		reload()
	}
}
