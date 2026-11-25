
import XCTest

final class keyboardUITests: XCTestCase {
    override func setUpWithError() throws {

        continueAfterFailure = false

    }

    override func tearDownWithError() throws {
    }

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        app.launch()

    }

	@MainActor
	func testPrimarySettingsFlows() throws {
		let app = XCUIApplication()
		app.launchArguments = ["-ui-testing-used-keyboard"]
		app.launch()

		let appearance = app.buttons["settings.appearance"]
		XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
		for _ in 0..<6 {
			if appearance.exists && appearance.isHittable { break }
			app.swipeUp()
		}
		XCTAssertTrue(appearance.waitForExistence(timeout: 2), "Appearance row missing")
		appearance.tap()
		XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 2))
		add(XCTAttachment(screenshot: app.screenshot()))
		app.navigationBars["Appearance"].buttons.element(boundBy: 0).tap()

		let progress = app.buttons["progress.banner"]
		for _ in 0..<3 {
			if progress.isHittable { break }
			app.swipeDown()
		}
		XCTAssertTrue(progress.waitForExistence(timeout: 2))
		progress.tap()
		XCTAssertTrue(app.navigationBars["Achievements"].waitForExistence(timeout: 2))
		XCTAssertTrue(app.staticTexts["Last 14 days"].exists)
		add(XCTAttachment(screenshot: app.screenshot()))
	}

	@MainActor
	func testInstalledExtensionTypes() throws {
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
			throw XCTSkip("Glyph is not the active software keyboard on this simulator")
		}
		XCTAssertTrue(host.keys["Q"].waitForExistence(timeout: 2))
		host.keys["Q"].tap()
		XCTAssertEqual(host.textFields["runtime.text"].value as? String, "Q")
	}

	@MainActor
	private func launchRuntimeHost() -> XCUIApplication {
		let app = XCUIApplication()
		app.launchArguments = ["-keyboard-runtime-host"]
		app.launch()
		let field = app.textFields["runtime.text"]
		XCTAssertTrue(field.waitForExistence(timeout: 5))
		field.tap()
		return app
	}

	@MainActor
	private func tapLetter(_ preferredLabel: String, in app: XCUIApplication) {
		let preferred = app.keys[preferredLabel]
		if preferred.waitForExistence(timeout: 1) {
			preferred.tap()
			return
		}
		let alternateLabel = preferredLabel == preferredLabel.lowercased()
			? preferredLabel.uppercased() : preferredLabel.lowercased()
		let alternate = app.keys[alternateLabel]
		XCTAssertTrue(alternate.waitForExistence(timeout: 2))
		alternate.tap()
	}

	@MainActor
	private func key(_ label: String, in app: XCUIApplication) -> XCUIElement {
		let preferred = app.keys[label]
		return preferred.waitForExistence(timeout: 1) ? preferred
			: app.keys[label == label.lowercased() ? label.uppercased() : label.lowercased()]
	}

	@MainActor
	private func glide(_ from: String, to: String, in app: XCUIApplication) {
		let centre = CGVector(dx: 0.5, dy: 0.5)
		key(from, in: app).coordinate(withNormalizedOffset: centre)
			.press(forDuration: 0.05, thenDragTo: key(to, in: app).coordinate(withNormalizedOffset: centre),
				withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.05)
	}

	@MainActor
	private func fieldText(_ field: XCUIElement) -> String {
		let value = field.value as? String ?? ""
		return value == field.placeholderValue ? "" : value
	}

	@MainActor
	private func waitForText(_ field: XCUIElement, toDifferFrom old: String, timeout: TimeInterval = 3) -> String {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			let now = fieldText(field)
			if now != old { return now }
			RunLoop.current.run(until: Date().addingTimeInterval(0.05))
		}
		return fieldText(field)
	}

	@MainActor
	func testGlideCommitsTheFirstWordOfAnEmptyField() throws {
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 10) else {
			throw XCTSkip("Glyph is not the active software keyboard")
		}
		let field = host.textFields["runtime.text"]
		XCTAssertEqual(fieldText(field), "")
		glide("h", to: "i", in: host)
		let first = waitForText(field, toDifferFrom: "")
		NSLog("GLIDE-FIRST [%@]", first)
		XCTAssertTrue(first.trimmingCharacters(in: .whitespaces).count >= 2,
			"The first glided word of an empty field was not committed: [\(first)]")
		glide("t", to: "o", in: host)
		let second = waitForText(field, toDifferFrom: first)
		NSLog("GLIDE-SECOND [%@]", second)
		XCTAssertTrue(second.count > first.count + 1, "The second glided word was not committed: [\(second)]")
	}

	@MainActor
	func testContractionsCommitWhatTheStripShows() throws {
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 10) else {
			throw XCTSkip("Glyph is not the active software keyboard")
		}
		let field = host.textFields["runtime.text"]
		let cases = [("dont", "don't"), ("im", "i'm"), ("cant", "can't"), ("thats", "that's"),
			("youre", "you're"), ("didnt", "didn't"), ("hows", "how's"), ("whys", "why's"),
			("ill", "i'll"), ("its", "it's"), ("she", "she"), ("lets", "lets")]
		var previous = fieldText(field), mismatches: [String] = []
		for (typed, intended) in cases {
			for ch in typed { tapLetter(String(ch), in: host) }
			let primary = host.descendants(matching: .any)["suggestion.primary"]
			RunLoop.current.run(until: Date().addingTimeInterval(0.4))
			let shown = primary.exists ? primary.label : ""
			host.keys["Space"].tap()
			let text = waitForText(field, toDifferFrom: previous)
			let committed = String(text.dropFirst(previous.count)).trimmingCharacters(in: .whitespaces)
				.replacingOccurrences(of: "\u{2019}", with: "'")
			previous = text
			NSLog("CONTRACTION %@ strip=[%@] committed=[%@] want=[%@]", typed, shown, committed, intended)
			let strip = shown.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
			if strip != committed.lowercased() {
				mismatches.append("\(typed): strip \(shown), committed \(committed)")
			}
			if committed.lowercased() != intended { NSLog("CONTRACTION-MISS %@ committed=[%@] want=[%@]", typed, committed, intended) }
		}
		XCTAssertEqual(mismatches, [], "Space must commit the strip's middle word")
	}

	@MainActor
	func testKeyboardHealthFollowsMemoryLive() throws {
		let app = XCUIApplication()
		app.launchArguments = []
		app.launch()
		let health = app.buttons["Keyboard health"]
		for _ in 0..<6 where !health.isHittable { app.swipeUp() }
		guard health.waitForExistence(timeout: 5) else { throw XCTSkip("Keyboard health is a Debug-build screen") }
		health.tap()
		let memory = app.descendants(matching: .any)["health.memory.now"]
		XCTAssertTrue(memory.waitForExistence(timeout: 5))
		app.textFields["health.memory.probe"].tap()
		guard app.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 10) else {
			throw XCTSkip("Glyph is not the active software keyboard")
		}
		expectation(for: NSPredicate(format: "label CONTAINS ' · live'"), evaluatedWith: memory)
		waitForExpectations(timeout: 6)
		app.navigationBars.buttons.firstMatch.tap()
		RunLoop.current.run(until: Date().addingTimeInterval(4))
		health.tap()
		XCTAssertTrue(memory.waitForExistence(timeout: 5))
		XCTAssertTrue(memory.label.contains(" ago"), memory.label)
	}

	@MainActor
	func testMemoryAcrossSurfaces() throws {
		try XCTSkipUnless(ProcessInfo.processInfo.environment["KB_MEMORY_TOUR"] == "1",
			"set TEST_RUNNER_KB_MEMORY_TOUR=1 to tour the keyboard's surfaces")
		let host = launchRuntimeHost()
		let keyboard = host.descendants(matching: .any)["glyph.keyboard"]
		guard keyboard.waitForExistence(timeout: 10) else {
			throw XCTSkip("Glyph is not the active software keyboard")
		}
		func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
		func type(_ text: String) {
			for character in text {
				if character == " " { key("Space", in: host).tap() } else { tapLetter(String(character), in: host) }
			}
		}
		func control(_ name: String) -> XCUIElement { keyboard.descendants(matching: .any)[name].firstMatch }
		func tap(_ element: XCUIElement) {
			guard element.waitForExistence(timeout: 5) else {
				return XCTFail("\(element) missing from:\n\(keyboard.debugDescription)")
			}
			element.tap()
		}
		func scroll(_ times: Int) {
			let grid = keyboard.collectionViews["media.grid"]
			guard grid.waitForExistence(timeout: 5) else { return }
			for _ in 0..<times { grid.swipeLeft(); settle(1.5) }
		}
		for _ in 0..<3 {
			type("hello there how are you "); settle(2)
			tap(key("Emoji", in: host)); settle(2)
			XCTAssertTrue(control("emoji.category.0").waitForExistence(timeout: 5), "Emoji category tabs missing")
			var index = 0
			while control("emoji.category.\(index)").exists {
				control("emoji.category.\(index)").tap(); settle(0.6)
				index += 1
			}
			tap(control("GIFs")); settle(4)
			scroll(4)
			tap(control("Stickers")); settle(4)
			scroll(4)
			tap(control("ABC")); settle(3)
		}
	}

	@MainActor
	func testBackspaceUndoOfACorrectionSticks() throws {
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 10) else {
			throw XCTSkip("Glyph is not the active software keyboard")
		}
		let field = host.textFields["runtime.text"]
		let primary = host.descendants(matching: .any)["suggestion.primary"]
		func spelled(_ text: String) -> String {
			text.unicodeScalars.map { $0.isASCII ? String($0) : String(format: "<U+%04X>", $0.value) }.joined()
		}
		func folded(_ text: String) -> String { text.replacingOccurrences(of: "\u{2019}", with: "'").lowercased() }
		func lastWord(_ text: String) -> String { String(text.split(separator: " ").last ?? "") }
		func type(_ word: String) {
			for ch in word { tapLetter(String(ch), in: host) }
			RunLoop.current.run(until: Date().addingTimeInterval(0.4))
		}
		var failures: [String] = [], undone = 0
		for (typed, corrected) in [("shed", "she'd"), ("shell", "she'll"), ("well", "we'll"), ("hell", "he'll")] {
			type("I"); host.keys["Space"].tap()
			type("think"); host.keys["Space"].tap()
			type(typed)
			let before = fieldText(field)
			host.keys["Space"].tap()
			let afterSpace = waitForText(field, toDifferFrom: before)
			host.keys["Delete"].tap()
			let afterUndo = waitForText(field, toDifferFrom: afterSpace)
			RunLoop.current.run(until: Date().addingTimeInterval(0.4))
			let shown = primary.exists ? primary.label : ""
			host.keys["Space"].tap()
			let afterRetry = waitForText(field, toDifferFrom: afterUndo)
			NSLog("UNDO %@ space=[%@] backspace=[%@] strip=[%@] space=[%@]", typed,
				spelled(afterSpace), spelled(afterUndo), shown, spelled(afterRetry))
			guard folded(lastWord(afterSpace)) != typed else {
				NSLog("UNDO-SKIP %@ was not corrected (want %@)", typed, corrected)
				continue
			}
			undone += 1
			if folded(lastWord(afterUndo)) != typed {
				failures.append("\(typed): Backspace did not restore it: [\(afterUndo)]")
			} else if folded(shown) != typed {
				failures.append("\(typed): strip middle after the undo was [\(shown)]")
			} else if folded(lastWord(afterRetry)) != typed {
				failures.append("\(typed): Space redid the correction after the undo: [\(afterRetry)]")
			}
		}
		XCTAssertGreaterThan(undone, 0, "No case was corrected, so no undo was tested")
		XCTAssertEqual(failures, [])
	}

	private enum ComparedKeyboard: String, CaseIterable { case glyph, apple, gboard }

	private func menuName(_ keyboard: ComparedKeyboard) -> String {
		switch keyboard { case .glyph: return "Glyph"; case .apple: return "English"; case .gboard: return "Gboard" }
	}

	@MainActor
	private func activate(_ keyboard: ComparedKeyboard, in app: XCUIApplication, attempts: Int = 1) -> Bool {
		let row = XCUIElement.ElementType(rawValue: 75) ?? .any
		let item = app.descendants(matching: row).matching(NSPredicate(format: "label BEGINSWITH %@", menuName(keyboard))).firstMatch
		var found = false
		for _ in 0..<max(1, attempts) {
			app.buttons["Next keyboard"].firstMatch.press(forDuration: 1.2)
			if item.waitForExistence(timeout: 4) { found = true; break }
			app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
			RunLoop.current.run(until: Date().addingTimeInterval(1.5))
		}
		guard found else { return false }
		item.tap()
		RunLoop.current.run(until: Date().addingTimeInterval(1.5))
		let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		shot.name = "selected \(keyboard.rawValue)"; shot.lifetime = .keepAlways; add(shot)
		return true
	}

	@MainActor
	func testGlyphTypesRightAfterGlobeSwitch() throws {
		let host = launchRuntimeHost()
		let field = host.textFields["runtime.text"]
		XCTAssertTrue(activate(.apple, in: host))
		XCTAssertTrue(activate(.glyph, in: host))
		XCTAssertTrue(host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 5))
		for ch in "the" { tapLetter(String(ch), in: host) }
		let text = waitForText(field, toDifferFrom: "")
		RunLoop.current.run(until: Date().addingTimeInterval(0.5))
		let primary = host.descendants(matching: .any)["suggestion.primary"]
		NSLog("GLOBE-SWITCH text=[%@] strip=[%@]", text, primary.exists ? primary.label : "")
		XCTAssertEqual(text.lowercased(), "the", "Glyph did not type until the field was tapped")
		XCTAssertFalse(primary.exists ? primary.label.isEmpty : true, "The strip stayed empty after the switch")
	}

	private static let gboardKeys: [Character: CGVector] = {
		var keys: [Character: CGVector] = [:]
		let rows: [(String, [CGFloat], CGFloat)] = [
			("qwertyuiop", [52, 143, 233, 323, 414, 505, 596, 686, 777, 867], 1398),
			("asdfghjkl", [97, 187, 278, 368, 459, 550, 641, 731, 822], 1522),
			("zxcvbnm", [187, 278, 368, 459, 550, 641, 731], 1646)]
		for (letters, xs, y) in rows {
			for (letter, x) in zip(letters, xs) { keys[letter] = CGVector(dx: x / 920, dy: y / 2000) }
		}
		keys[" "] = CGVector(dx: 459.0 / 920, dy: 1770.0 / 2000)
		return keys
	}()

	@MainActor
	private func keyPoints(for keyboard: ComparedKeyboard, in app: XCUIApplication) -> [Character: CGPoint] {
		let window = app.windows.firstMatch.frame
		if keyboard == .gboard {
			return Self.gboardKeys.mapValues { CGPoint(x: window.minX + $0.dx * window.width, y: window.minY + $0.dy * window.height) }
		}
		var points: [Character: CGPoint] = [:]
		for key in app.keys.allElementsBoundByIndex where key.exists {
			let label = key.label.lowercased(), centre = CGPoint(x: key.frame.midX, y: key.frame.midY)
			if label.count == 1, let letter = label.first, letter.isLetter { points[letter] = centre }
			else if label == " " || label == "space" { points[" "] = centre }
		}
		return points
	}

	@MainActor
	func testCompareKeyboards() throws {
		let host = XCUIApplication()
		host.launchArguments = ["-keyboard-runtime-host"]
		let perBucket = Int(ProcessInfo.processInfo.environment["KB_COMPARE_PER_BUCKET"] ?? "") ?? .max
		var taken: [String: Int] = [:]
		let cases = keyboardComparisonCases.filter { c in
			taken[c.kind, default: 0] += 1
			return taken[c.kind]! <= perBucket
		}
		let contexts = cases.map(\.context)
		host.launchEnvironment["KB_RUNTIME_CONTEXTS"] = String(decoding: try JSONEncoder().encode(contexts), as: UTF8.self)
		host.launch()
		defer { _ = activate(.glyph, in: host, attempts: 3) }
		let field = host.textFields["runtime.text"]
		XCTAssertTrue(field.waitForExistence(timeout: 5))
		field.tap()
		let origin = host.coordinate(withNormalizedOffset: .zero)
		func tap(_ point: CGPoint) { origin.withOffset(CGVector(dx: point.x, dy: point.y)).tap() }
		func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
		let nextFrame = host.buttons["runtime.next"].frame
		let next = CGPoint(x: nextFrame.midX, y: nextFrame.midY)
		pause(2)
		var summary: [String] = []
		for keyboard in ComparedKeyboard.allCases {
			guard activate(keyboard, in: host) else {
				NSLog("COMPARE %@ not in the globe menu", keyboard.rawValue)
				continue
			}
			let points = keyPoints(for: keyboard, in: host)
			guard points.count == 27 else {
				NSLog("COMPARE %@ found %ld of 27 keys", keyboard.rawValue, points.count)
				continue
			}
			var right: [String: (Int, Int)] = [:]
			for (n, c) in cases.enumerated() {
				let started = Date()
				tap(next)
				pause(0.2)
				let before = fieldText(field)
				for letter in c.typed { tap(points[letter]!) }
				pause(0.3)
				tap(points[" "]!)
				let text = waitForText(field, toDifferFrom: before, timeout: 1.5)
				let typed = text.hasPrefix(before) ? String(text.dropFirst(before.count)) : String(text.split(separator: " ").last ?? "")
				let committed = typed.trimmingCharacters(in: .whitespaces)
					.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
					.trimmingCharacters(in: .punctuationCharacters)
				let ok = committed == c.intended
				let tally = right[c.kind] ?? (0, 0)
				right[c.kind] = (tally.0 + (ok ? 1 : 0), tally.1 + 1)
				NSLog("COMPARE %@ %@ [%@] %@ -> %@ [want %@] %@ %.1fs", keyboard.rawValue, c.kind, c.context, c.typed,
					committed, c.intended, ok ? "OK" : "MISS", Date().timeIntervalSince(started))
				if n < 3 {
					let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
					shot.name = "\(keyboard.rawValue) \(c.typed)"; shot.lifetime = .keepAlways; add(shot)
				}
			}
			let line = keyboard.rawValue + " " + right.keys.sorted().map { "\($0)=\(right[$0]!.0)/\(right[$0]!.1)" }.joined(separator: " ")
			NSLog("COMPARE-SUMMARY %@", line)
			summary.append(line)
		}
		let attachment = XCTAttachment(string: summary.joined(separator: "\n"))
		attachment.name = "keyboard comparison"; attachment.lifetime = .keepAlways; add(attachment)
	}

	@MainActor
	func testProbeEnabledKeyboards() throws {
		let host = launchRuntimeHost()
		RunLoop.current.run(until: Date().addingTimeInterval(2))
		let before = Set(host.descendants(matching: .any).allElementsBoundByIndex.filter(\.exists).map(\.label))
		host.buttons["Next keyboard"].firstMatch.press(forDuration: 1.2)
		RunLoop.current.run(until: Date().addingTimeInterval(1))
		let all = host.descendants(matching: .any).allElementsBoundByIndex.filter(\.exists)
		for element in all where !before.contains(element.label) && !element.label.isEmpty {
			NSLog("KBMENU type=%lu label=[%@] id=[%@] frame=%@", element.elementType.rawValue, element.label,
				element.identifier, NSCoder.string(for: element.frame))
		}
		let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		shot.name = "globe menu"; shot.lifetime = .keepAlways; add(shot)
	}

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

	@MainActor
	func testClipboardToolsArePresentAndTappable() throws {
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
			throw XCTSkip("Glyph is not the active software keyboard on this simulator")
		}
        let tools = host.descendants(matching: .any)["suggestion.tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 3))
        tools.tap()
		let clip = host.descendants(matching: .any)["tools.clipboard"]
		XCTAssertTrue(clip.waitForExistence(timeout: 3), "Clipboard action missing from tools row")
		XCTAssertTrue(clip.isHittable, "Clipboard icon is not hittable")
		clip.tap()
		let allowPaste = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
		if allowPaste.waitForExistence(timeout: 3) { allowPaste.tap() }
		XCTAssertTrue(host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 3),
			"Keyboard disappeared after opening the clipboard panel")
	}

    @MainActor
    func testKeyboardHeightRemainsBoundedAcrossHostEditsAndRotation() throws {
        let host = launchRuntimeHost()
        let deck = host.descendants(matching: .any)["glyph.keyboard"]
        XCTAssertTrue(deck.waitForExistence(timeout: 5), "Enable Glyph as the active software keyboard before running this device test")
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            for _ in 0..<3 {
                host.textFields["runtime.text"].tap()
                let settled = NSPredicate { _, _ in
                    let window = host.windows.firstMatch.frame
                    return deck.exists && deck.frame.height > 100 && deck.frame.height < window.height * 0.70
                }
                expectation(for: settled, evaluatedWith: host)
                waitForExpectations(timeout: 5)
                tapLetter("a", in: host)
                host.buttons["runtime.clear"].tap()
                XCTAssertTrue(host.buttons["suggestion.tools"].isHittable)
            }
            let screenshot = XCTAttachment(screenshot: host.screenshot())
            screenshot.name = "Keyboard height after rotation \(orientation.rawValue)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testUniversalSuggestionsRemainVisibleInURLFieldWithAutocorrectionDisabled() throws {
        let host = XCUIApplication()
        host.launchArguments = ["-keyboard-runtime-host", "-keyboard-runtime-url"]
        host.launch()
        let field = host.textFields["runtime.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
            throw XCTSkip("Glyph is not the active software keyboard on this device")
        }
        let tools = host.buttons["suggestion.tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 3))
        XCTAssertTrue(tools.isHittable)
        let primary = host.buttons["suggestion.primary"]
        expectation(for: NSPredicate { _, _ in !primary.label.isEmpty }, evaluatedWith: host)
        waitForExpectations(timeout: 3)
        let stripHeight = tools.frame.height
        for letter in ["Q", "z", "x", "q"] { tapLetter(letter, in: host) }
        host.keys["Space"].tap()
        XCTAssertEqual((field.value as? String)?.lowercased(), "qzxq ",
            "Showing predictions must not enable unwanted URL autocorrection")
        XCTAssertTrue(tools.isHittable)
        XCTAssertEqual(tools.frame.height, stripHeight)
        tools.tap()
        XCTAssertTrue(host.buttons["tools.clipboard"].waitForExistence(timeout: 2))
        add(XCTAttachment(screenshot: host.screenshot()))
    }

    @MainActor
    func testHostSendClearsSuggestionsWithoutSpaceAndKeepsStarterWords() throws {
        let host = launchRuntimeHost()
        guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
            throw XCTSkip("Glyph is not the active software keyboard on this device")
        }
        for letter in ["M", "i", "c", "r", "o", "s", "o", "f", "t"] { tapLetter(letter, in: host) }
        let primary = host.buttons["suggestion.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 3))
        let oldWord = primary.label
        XCTAssertFalse(oldWord.isEmpty)
        host.buttons["runtime.clear"].tap()
        let refreshed = NSPredicate { _, _ in
            let field = host.textFields["runtime.text"].value as? String ?? ""
            return (field.isEmpty || field == "Type") && !primary.label.isEmpty && primary.label != oldWord
        }
        expectation(for: refreshed, evaluatedWith: host)
        waitForExpectations(timeout: 3)
        host.buttons["runtime.copy"].tap()
        XCTAssertTrue(primary.exists)
        XCTAssertFalse(host.buttons["suggestion.paste"].exists)
        add(XCTAttachment(screenshot: host.screenshot()))
    }

	@MainActor
	func testSendKeyWorksInAFieldThatEnablesReturnAutomatically() throws {
		let host = XCUIApplication()
		host.launchArguments = ["-keyboard-runtime-send"]
		host.launch()
		let field = host.textViews["runtime.text"]
		XCTAssertTrue(field.waitForExistence(timeout: 5))
		field.tap()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 10) else {
			throw XCTSkip("Glyph is not the active software keyboard")
		}
		let sent = host.staticTexts["runtime.sent"]
		let send = host.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'send'")).firstMatch
		XCTAssertTrue(send.waitForExistence(timeout: 3), "Send key missing")
		XCTAssertFalse(send.isEnabled, "Send should start disabled in an empty field that enables Return automatically")
		for ch in "ok" { tapLetter(String(ch), in: host) }
		let typed = waitForText(field, toDifferFrom: "")
		RunLoop.current.run(until: Date().addingTimeInterval(0.5))
		XCTAssertTrue(send.isEnabled, "Send stayed disabled after typing [\(typed)]")
		send.tap()
		let deadline = Date().addingTimeInterval(3)
		var delivered = false
		while Date() < deadline, !delivered {
			delivered = sent.label == "Sent 1" || ((field.value as? String) ?? "").contains("\n")
			if !delivered { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
		}
		XCTAssertTrue(delivered, "Send did not deliver Return; field=[\((field.value as? String) ?? "")]")
	}

	@MainActor
	func testEmojiSelectionProbe() throws {
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
			throw XCTSkip("Glyph is not the active software keyboard on this simulator")
		}
		let field = host.textFields["runtime.text"]
		let emojiKey = host.buttons["Emoji"].exists ? host.buttons["Emoji"] : host.keys["Emoji"]
		XCTAssertTrue(emojiKey.waitForExistence(timeout: 3), "Emoji key missing on letters page")
		emojiKey.tap()

		let grid = host.collectionViews["emoji.grid"]
		XCTAssertTrue(grid.waitForExistence(timeout: 3), "Emoji grid did not appear")
		var previous = fieldText(field)
		var tapped = 0

		func settle() { RunLoop.current.run(until: Date().addingTimeInterval(1.2)) }
		func tapVisibleCell(_ note: String, skip: Int = 0) {
			settle()
			guard let snapshot = try? grid.snapshot() else {
				return XCTFail("\(note): could not read the emoji grid")
			}
			let bounds = snapshot.frame.insetBy(dx: -0.5, dy: -0.5)
			let inside = snapshot.children.filter {
				$0.elementType == .cell && !$0.frame.isEmpty && bounds.contains($0.frame) && !$0.label.isEmpty
			}
			guard inside.count > skip else {
				return XCTFail("\(note): no fully visible emoji cell in \(snapshot.frame)")
			}
			let cell = inside[skip]
			let expected = cell.label
			grid.coordinate(withNormalizedOffset: .zero)
				.withOffset(CGVector(dx: cell.frame.midX - snapshot.frame.minX, dy: cell.frame.midY - snapshot.frame.minY)).tap()
			let text = waitForText(field, toDifferFrom: previous)
			let inserted = text.hasPrefix(previous) ? String(text.dropFirst(previous.count)) : text
			previous = text
			tapped += 1
			NSLog("EMOJI-PROBE %@ tapped=%@ inserted=%@ %@", note, expected, inserted,
				  inserted == expected ? "OK" : "MISMATCH")
			XCTAssertEqual(inserted, expected, "\(note): tapped \(expected) got \(inserted)")
		}

		tapVisibleCell("first-cell")
		tapVisibleCell("sixth-cell", skip: 5)

		let tab = host.descendants(matching: .any)["emoji.category.4"]
		if tab.waitForExistence(timeout: 2) {
			tab.tap()
			tapVisibleCell("after-tab-jump")
		}

		grid.swipeLeft()
		RunLoop.current.run(until: Date().addingTimeInterval(3))
		tapVisibleCell("after-scroll")
		XCTAssertEqual(tapped, 4, "Not every emoji probe ran")
	}

	@MainActor
	func testTypoCorrectionBattery() throws {
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
			throw XCTSkip("Glyph is not the active software keyboard on this simulator")
		}

		let cases: [(typed: String, intended: String)] = [
			("i", "I"), ("am", "am"), ("goinf", "going"), ("to", "to"), ("the", "the"), ("store", "store"),
			("can", "can"), ("you", "you"), ("sebd", "send"), ("me", "me"), ("thw", "the"), ("file", "file"),
			("see", "see"), ("you", "you"), ("tomirrow", "tomorrow"),
			("whst", "what"), ("time", "time"), ("is", "is"), ("it", "it"),
			("i", "I"), ("dont", "don't"), ("know", "know"),
			("hiw", "how"), ("are", "are"), ("yiu", "you"), ("doing", "doing"),
			("plesse", "please"), ("call", "call"), ("me", "me"),
			("teh", "the"), ("meeting", "meeting"), ("was", "was"), ("awesomr", "awesome"),
			("rhis", "this"), ("wprk", "work"), ("runnjng", "running"),
			("coudl", "could"), ("definately", "definitely"), ("recieve", "receive"),
			("coeevitjkn", "correction"),
		]

		var lines: [String] = []
		var correctedHits = 0, typoTotal = 0, falseCorrections = 0, cleanTotal = 0
		var suggestionHits = 0
		var previousText = ""
		let field = host.textFields["runtime.text"]

		for c in cases {
			for ch in c.typed { tapLetter(String(ch), in: host) }
			let sugg = ["suggestion.left", "suggestion.primary", "suggestion.right"].map { id -> String in
				let el = host.descendants(matching: .any)[id]
				return el.exists ? el.label : ""
			}
			host.keys["Space"].tap()
			let text = (field.value as? String) ?? ""
			let committed = String(text.dropFirst(previousText.count))
				.trimmingCharacters(in: .whitespaces)
			previousText = text

			let isTypo = c.typed.lowercased() != c.intended.lowercased()
			let ok = committed.lowercased() == c.intended.lowercased()
			if isTypo {
				typoTotal += 1
				if ok { correctedHits += 1 }
				if sugg.contains(where: { $0.lowercased() == c.intended.lowercased() }) { suggestionHits += 1 }
			} else {
				cleanTotal += 1
				if !ok { falseCorrections += 1 }
			}
			lines.append("\(c.typed) -> \(committed) [want \(c.intended)] \(ok ? "OK" : "MISS") sugg=[\(sugg.joined(separator: "|"))]")
		}

		let summary = "SUMMARY corrected=\(correctedHits)/\(typoTotal) inSuggestions=\(suggestionHits)/\(typoTotal) falseCorrections=\(falseCorrections)/\(cleanTotal)"
		lines.append(summary)
		for l in lines { NSLog("TYPO-BATTERY %@", l) }
		let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
		attachment.name = "typo-battery-results"
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
