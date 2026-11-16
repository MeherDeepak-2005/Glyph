import UIKit

final class ClipboardPanelView: UIView, UITableViewDataSource, UITableViewDelegate {
	var onPick: ((String) -> Void)?
	var onPasteCurrent: (() -> Void)?
	var onABC: (() -> Void)?
	var onNextKeyboard: (() -> Void)?

	private let theme: KeyboardTheme
	private let showsGlobe: Bool
	private let hasFullAccess: Bool
	private let injectedItems: [KBClipboardItem]?
	private var pinnedItems: [KBClipboardItem] = []
	private var recentItems: [KBClipboardItem] = []

	private let table = UITableView(frame: .zero, style: .insetGrouped)
	private let bottomBar = UIView()
    private let pasteCurrentButton = UIButton(type: .system)
	private let emptyLabel = UILabel()
	private let barHeight: CGFloat = 42

	init(theme: KeyboardTheme, showsGlobe: Bool, hasFullAccess: Bool,
		 items: [KBClipboardItem]? = nil) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		self.hasFullAccess = hasFullAccess
		self.injectedItems = items
		super.init(frame: .zero)
		accessibilityIdentifier = "clipboard.panel"

		table.backgroundColor = .clear
		table.dataSource = self
		table.delegate = self
		table.register(UITableViewCell.self, forCellReuseIdentifier: "c")
		table.showsVerticalScrollIndicator = false
		table.sectionHeaderTopPadding = 4
		addSubview(table)

		emptyLabel.font = KeyboardTypography.status
		emptyLabel.textColor = theme.specialKeyText.withAlphaComponent(0.55)
		emptyLabel.textAlignment = .center
		emptyLabel.numberOfLines = 3
		table.backgroundView = emptyLabel

        pasteCurrentButton.setTitle("Paste current clipboard", for: .normal)
        pasteCurrentButton.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        pasteCurrentButton.tintColor = theme.keyText
        pasteCurrentButton.titleLabel?.font = KeyboardTypography.panelAction
        pasteCurrentButton.accessibilityIdentifier = "clipboard.pasteCurrent"
        pasteCurrentButton.isEnabled = hasFullAccess
        pasteCurrentButton.addAction(UIAction { [weak self] _ in
            self?.onPasteCurrent?()
            self?.reload()
        }, for: .touchUpInside)
        addSubview(pasteCurrentButton)
		buildBottomBar()
		addSubview(bottomBar)
		reload()
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
        pasteCurrentButton.frame = CGRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: 44)
        table.frame = CGRect(x: 0, y: 44, width: bounds.width,
            height: max(0, bounds.height - barHeight - 44))
		bottomBar.frame = CGRect(x: 0, y: bounds.height - barHeight,
								 width: bounds.width, height: barHeight)
	}

	private func reload(_ current: [KBClipboardItem]? = nil) {
		let items = hasFullAccess ? (current ?? injectedItems ?? KBClipboard.all()) : []
		pinnedItems = items.filter(\.pinned)
		recentItems = items.filter { !$0.pinned }
		if items.isEmpty {
			emptyLabel.text = hasFullAccess
				? "Nothing saved yet.\nCopy text, then open Clipboard\nfrom the Tools row."
				: "Allow Full Access in Settings\nto use the clipboard."
			emptyLabel.isHidden = false
		} else {
			emptyLabel.isHidden = true
		}
		table.reloadData()
	}

	nonisolated static func displayText(_ text: String, limit: Int = 400) -> String {
		let separators = CharacterSet.whitespacesAndNewlines
		var out = String.UnicodeScalarView()
		var length = 0, pendingSpace = false
		for scalar in text.unicodeScalars {
			if separators.contains(scalar) {
				if length >= limit { break }
				pendingSpace = length > 0
				continue
			}
			if pendingSpace { out.append(" "); length += 1; pendingSpace = false }
			out.append(scalar); length += 1
			if length >= limit * 4 { break }
		}
		return String(out)
	}

	private func items(in section: Int) -> [KBClipboardItem] {
		section == 0 ? pinnedItems : recentItems
	}

	func numberOfSections(in tv: UITableView) -> Int { 2 }
	func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int { items(in: s).count }
	func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? {
		items(in: s).isEmpty ? nil : (s == 0 ? "Pinned" : "Recent")
	}

	func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
		let cell = tv.dequeueReusableCell(withIdentifier: "c", for: ip)
		let item = items(in: ip.section)[ip.row]
		var cfg = cell.defaultContentConfiguration()
		let shown = Self.displayText(item.text)
		cfg.text = shown
		cfg.textProperties.font = KeyboardTypography.listItem
		cfg.textProperties.color = theme.keyText
		cfg.textProperties.numberOfLines = 2
		cfg.textProperties.lineBreakMode = .byTruncatingTail
		cell.contentConfiguration = cfg
		cell.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 1, alpha: 0.65)
		cell.selectionStyle = .none
		cell.isAccessibilityElement = true
		cell.accessibilityLabel = (item.pinned ? "Pinned clipboard item. " : "Clipboard item. ") + shown
		cell.accessibilityHint = "Inserts this text"
		cell.accessoryView = rowButton(symbol: "xmark.circle.fill",
			tint: theme.keyText.withAlphaComponent(0.35), accessibilityLabel: "Delete clipboard item") {
			[weak self] in
			guard let self else { return }
			reload(injectedItems == nil ? KBClipboard.remove(item.text) : nil)
		}
		return cell
	}

	private func rowButton(symbol: String, tint: UIColor, accessibilityLabel: String,
						   action: @escaping () -> Void) -> UIButton {
		let b = UIButton(type: .system)
		b.setImage(UIImage(systemName: symbol,
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)), for: .normal)
		b.tintColor = tint
		b.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
		b.accessibilityLabel = accessibilityLabel
		b.addAction(UIAction { _ in action() }, for: .touchUpInside)
		return b
	}

	func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
		onPick?(items(in: ip.section)[ip.row].text)
	}

	func tableView(_ tv: UITableView, trailingSwipeActionsConfigurationForRowAt ip: IndexPath)
		-> UISwipeActionsConfiguration? {
		let item = items(in: ip.section)[ip.row]
		let pin = UIContextualAction(style: .normal, title: item.pinned ? "Unpin" : "Pin") { [weak self] _, _, done in
			guard let self else { done(false); return }
			reload(injectedItems == nil ? KBClipboard.togglePin(item.text) : nil)
			done(true)
		}
		pin.backgroundColor = .systemOrange
		return UISwipeActionsConfiguration(actions: [pin])
	}

	private func buildBottomBar() {
		bottomBar.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.05) : UIColor(white: 0, alpha: 0.04)
		var leading: [UIButton] = [barButton(title: "ABC") { [weak self] in self?.onABC?() }]
		if showsGlobe { leading.append(barButton(symbol: "keyboard", accessibilityLabel: "Next Keyboard") { [weak self] in self?.onNextKeyboard?() }) }

		let title = UILabel()
		title.text = "Clipboard"
		title.font = KeyboardTypography.panelTitle
		title.textColor = theme.specialKeyText.withAlphaComponent(0.7)
		title.textAlignment = .center

		let stack = UIStackView(arrangedSubviews: leading + [title])
		stack.axis = .horizontal
		stack.spacing = 2
		stack.alignment = .fill
		title.setContentHuggingPriority(.defaultLow, for: .horizontal)
		for b in leading {
			b.setContentHuggingPriority(.required, for: .horizontal)
			b.widthAnchor.constraint(equalToConstant: 40).isActive = true
		}
		stack.translatesAutoresizingMaskIntoConstraints = false
		bottomBar.addSubview(stack)
		let trailing = stack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -4)
		trailing.priority = .required - 1
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 4),
			trailing,
			stack.topAnchor.constraint(equalTo: bottomBar.topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor)
		])
	}

	private func barButton(title: String? = nil, symbol: String? = nil,
						   accessibilityLabel: String? = nil,
						   action: @escaping () -> Void) -> UIButton {
		let b = UIButton(type: .system)
		if let title {
			b.setTitle(title, for: .normal)
			b.titleLabel?.font = KeyboardTypography.panelButton
		}
		if let symbol {
			b.setImage(UIImage(systemName: symbol,
				withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)
		}
		if title == "ABC" { b.accessibilityLabel = "Letters" }
		if let accessibilityLabel { b.accessibilityLabel = accessibilityLabel }
		b.tintColor = theme.specialKeyText.withAlphaComponent(0.5)
		b.setTitleColor(theme.specialKeyText, for: .normal)
		b.addAction(UIAction { _ in action() }, for: .touchUpInside)
		return b
	}
}
