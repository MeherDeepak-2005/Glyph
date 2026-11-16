import UIKit

extension KeyboardViewController {

	func updateAutoShift() {
		let ctx = textDocumentProxy.documentContextBeforeInput
		keyboard?.setAutoShift(shouldAutoShift(ctx))
	}

	func shouldAutoShift(_ ctx: String?) -> Bool {
		guard let ctx, !ctx.isEmpty else { return true }
		if ctx.hasSuffix("\n") { return true }
		var s = Substring(ctx)
		var sawSpace = false
		while s.last == " " { sawSpace = true; s = s.dropLast() }
		if sawSpace, let l = s.last, ".!?".contains(l) { return true }
		return s.isEmpty
	}

	func handleDelete() {
        beginKeyboardEdit()
        defer { endKeyboardEdit() }
		noteProxyEdit()
		if keyboard?.isRepeatingKey != true { noteTap() }
		if let c = lastCorrection {
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			let expected = c.corrected + c.trailing
			guard !expected.isEmpty,
				HostDocumentSnapshot.folded(ctx).hasSuffix(HostDocumentSnapshot.folded(expected)) else {
				if pendingGlideVerdict {
					pendingGlideVerdict = false
					engine.glideRejected()
					KBStats.cancel(pendingGlideStatsID)
					pendingGlideStatsID = nil
				}
				lastCorrection = nil
				let erased = ctx.last
				textDocumentProxy.deleteBackward()
				traceErase(erased)
				if let erased, isWordChar(erased), !wordTaps.isEmpty { wordTaps.removeLast() }
				else { wordTaps.removeAll(keepingCapacity: true) }
				trackErase(of: erased)
				updateAutoShift()
				scheduleSuggestions()
				return
			}
			if pendingGlideVerdict, c.original.isEmpty, !c.fromAutocorrect {
				pendingGlideVerdict = false
				engine.glideRejected()
				KBStats.cancel(pendingGlideStatsID)
				pendingGlideStatsID = nil
			}
			lastCorrection = nil
			resetEraseTracking()
			wordTaps.removeAll(keepingCapacity: true)
			typingTrace = TypingTrace()
			if permitsTypingData { KBDiagnostics.noteBackspace(erasedLetter: nil) }
			guard replaceHostSuffix(expected, with: c.original) else {
				updateAutoShift()
				scheduleSuggestions()
				return
			}
			recordTyping("undo", text: c.corrected, replacement: c.original, evidence: c.fromAutocorrect ? "explicit-autocorrect-undo" : "explicit-retraction", relatedWord: c.recordedWordSessionID,
				sinceMs: (ProcessInfo.processInfo.systemUptime - c.appliedAt) * 1_000)
			KBDiagnostics.noteWordModified(revertedCorrection: c.fromAutocorrect)
			if !isSecureField, !c.corrected.isEmpty {
				recordReplacement(original: c.corrected, replacement: c.original)
			}
			if c.fromAutocorrect {
				rejectCorrection(c.original)
			}
			updateAutoShift()
			scheduleSuggestions()
			return
		}
		let erased = textDocumentProxy.documentContextBeforeInput?.last
		textDocumentProxy.deleteBackward()
		traceErase(erased)
		if let erased, isWordChar(erased), !wordTaps.isEmpty { wordTaps.removeLast() }
		else { wordTaps.removeAll(keepingCapacity: true) }
		trackErase(of: erased)
		updateAutoShift()
		scheduleSuggestions()
	}

	func handlePick(_ s: String) {
        guard hostConnectionReady, let shown = presentationDocument,
            let current = readHostDocument(), current.isAvailable, shown.matches(current) else {
            reconcileHostDocument()
            return
        }
        documentReconciler.beginKeyboardEdit()
        keyboard?.dismissTools()
        defer { endKeyboardEdit() }
		noteProxyEdit()
		noteTap()
		resetEraseTracking()
		wordTaps.removeAll(keepingCapacity: true)

		if !s.isEmpty, !s.contains(where: { $0.isLetter }) {
			resolveCorrectionAsAccepted()
			if case .complete(let partial) = mode {
				guard replaceHostSuffix(partial, with: s) else { return }
			} else {
				insertIntoHost(s)
			}
			KBEmojiRecents.add(s)
			lastCorrection = nil
			updateAutoShift()
			scheduleSuggestions()
			return
		}

		let pickMode: (label: String, replacing: String) = {
			switch mode {
			case .complete(let partial): return ("complete", partial)
			case .predict: return ("predict", "")
			case .revert(let original): return ("revert", original)
			case .glided(let committed): return ("glided", committed)
			}
		}()
		if case .revert(let original) = mode, s == original {} else { resolveCorrectionAsAccepted() }
		switch mode {
		case .complete(let partial):
			guard replaceHostSuffix(partial, with: s + " ") else { return }
			recordTyping("suggestion-pick", text: pickMode.replacing, replacement: s, evidence: "explicit-selection")
			learnCommittedWord(s)
			if !isSecureField { KBStats.noteCommitted(glided: false) }
			if partial.lowercased() != s.lowercased() {
				recordReplacement(original: partial, replacement: s)
			}
			recordCommitMetrics(s, autocorrected: false)
			lastCorrection = Correction(original: partial, corrected: s, trailing: " ", fromAutocorrect: false, recordedWordSessionID: wordSessionID)
			advanceWordSession()
		case .predict:
			insertIntoHost(s + " ")
			recordTyping("prediction-pick", replacement: s, evidence: "explicit-selection")
			learnCommittedWord(s)
			if !isSecureField { KBStats.noteCommitted(glided: false) }
			recordCommitMetrics(s, autocorrected: false)
			advanceWordSession()
			lastCorrection = nil
		case .revert(let original):
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			if s == original, let corrected = lastCompleteWord(ctx) {
				guard replaceHostSuffix(corrected + " ", with: original + " ") else { return }
				recordTyping("undo", text: corrected, replacement: original, evidence: "strip-autocorrect-undo", relatedWord: lastCorrection?.recordedWordSessionID,
					sinceMs: lastCorrection.map { (ProcessInfo.processInfo.systemUptime - $0.appliedAt) * 1_000 })
				rejectCorrection(original)
				recordReplacement(original: corrected, replacement: original)
				KBDiagnostics.noteWordModified(revertedCorrection: true)
			} else {
				insertIntoHost(s + " ")
			}
			lastCorrection = nil
		case .glided(let committed):
			let correctedWordID = lastCorrection?.recordedWordSessionID
			let oldAlternatives: [String]
			if case .glide(_, let alternatives) = suggestionPresentation {
				oldAlternatives = alternatives
			} else {
				oldAlternatives = []
			}
			let replacement = SuggestionCasePolicy.display(s,
				sentenceStart: shouldAutoShift(textDocumentProxy.documentContextBeforeInput))
			guard replaceHostSuffix(committed + " ", with: replacement + " ") else { return }
			if pendingGlideVerdict { pendingGlideVerdict = false; engine.glideCorrected(to: s) }
			KBStats.confirm(pendingGlideStatsID)
			pendingGlideStatsID = nil
			recordTyping("glide-selection", text: committed, replacement: s, evidence: "explicit-selection", relatedWord: correctedWordID,
				sinceMs: lastCorrection.map { (ProcessInfo.processInfo.systemUptime - $0.appliedAt) * 1_000 })
			learnCommittedWord(s)
			if committed.lowercased() != s.lowercased() {
				recordReplacement(original: committed, replacement: s)
			}
			lastCorrection = Correction(original: "", corrected: replacement, trailing: " ", fromAutocorrect: false, recordedWordSessionID: correctedWordID)
			if committed.lowercased() != s.lowercased() {
				KBDiagnostics.noteWordModified(revertedCorrection: false)
			}
			mode = .glided(replacement)
			let alternatives = uniqueWords([committed] + oldAlternatives, excluding: replacement)
			setGlideSuggestionBar(winner: replacement, alternatives: alternatives)
			updateAutoShift()
			return
		}
		KBDiagnostics.logPick(mode: pickMode.label, replacing: pickMode.replacing, with: s,
			contextTail: String((textDocumentProxy.documentContextBeforeInput ?? "").suffix(24)),
			deletes: lastReplaceDeleteCount, inserted: true)
		updateAutoShift()
		scheduleSuggestions()
	}
}
