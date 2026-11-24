import UIKit

extension KeyboardViewController {

	func resolveCorrectionAsAccepted() {
		if let c = lastCorrection, c.fromAutocorrect {
			engine.correctionStood(c.original)
			if let word = c.recordedWordSessionID, word != recordedAcceptance {
				recordedAcceptance = word
				recordTyping("correction-accepted", text: c.original, replacement: c.corrected, evidence: "user-continued",
					relatedWord: word, sinceMs: (ProcessInfo.processInfo.systemUptime - c.appliedAt) * 1_000)
			}
		}
	}

	func resolveGlideUnverified() {
		if pendingGlideVerdict { pendingGlideVerdict = false; engine.glideUnverified() }
		KBStats.confirm(pendingGlideStatsID)
		pendingGlideStatsID = nil
	}

	func learnCommittedWord(_ word: String) {
		guard permitsLearning else { return }
		engine.learn(word: word)
	}

	func recordReplacement(original: String, replacement: String) {
		guard permitsLearning else { return }
		engine.wordReplaced(original: original, with: replacement)
	}

	func rejectCorrection(_ word: String) {
		guard !isSecureField else { return }
		engine.dontCorrect(word)
	}

	func noteTap(atUptime uptime: Double = ProcessInfo.processInfo.systemUptime) {
		guard !isSecureField else { return }
		KBDiagnostics.noteTap(atUptime: uptime)
	}

	func recordCommitMetrics(_ word: String, autocorrected: Bool, source: String? = nil) {
		let armed = nwpPredictionArmed
		nwpPredictionArmed = false
		guard !word.isEmpty, !isSecureField else { return }
		recordCommit(word, evidence: source ?? (autocorrected ? "automatic-unverified" : "literal-unverified"))
		KBDiagnostics.noteWordCommitted(chars: word.count + 1, autocorrected: autocorrected,
			predictionShown: armed, predictionHit: armed && nwpPredictedTop3.contains(word.lowercased()))
	}

    func noteProxyEdit() {
		documentRevision &+= 1
		generation &+= 1
		decodeSnapshot = nil
		presentedDecodeSnapshot = nil
		keyboard?.setKeyPriors([:])
	}

	func advanceWordSession() {
		wordSessionID &+= 1
		currentWordBuffer = ""
		wordTaps.removeAll(keepingCapacity: true)
		typingTrace = TypingTrace()
		showModelTier(on: keyboard)
	}

	func showModelTier(on keyboard: KeyboardView?) {
		#if DEBUG
		keyboard?.spaceBadge = engine.isReady ? "NSS" : engine.neuralWordModel == nil ? "no model" : "no engine"
		#endif
	}

	@inline(__always)
	func insertIntoHost(_ text: String) {
		#if DEBUG
		let started = ProcessInfo.processInfo.systemUptime
		let signpost = KBDiagnostics.beginHostInsert()
		textDocumentProxy.insertText(text)
		KBDiagnostics.endHostInsert(signpost,
			milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
		#else
		textDocumentProxy.insertText(text)
		#endif
		extendRecordedGlides(with: text)
	}

	func deleteFromHost(backspace: Bool = false) {
		textDocumentProxy.deleteBackward()
		shortenRecordedGlides(by: 1, backspace: backspace)
	}

	@discardableResult
	func replaceHostSuffix(_ suffix: String, with replacement: String) -> Bool {
		lastReplaceDeleteCount = 0
		guard let initial = textDocumentProxy.documentContextBeforeInput else { return false }
		let hostSuffix = String(initial.suffix(suffix.count))
		let matched = hostSuffix.count == suffix.count
			&& HostDocumentSnapshot.folded(hostSuffix) == HostDocumentSnapshot.folded(suffix) ? hostSuffix : suffix
		guard let plan = HostSuffixReplacementPlan(contextBeforeInput: initial,
				suffix: matched, replacement: replacement) else { return false }
		let applied = plan.apply(initialContext: initial,
			deleteBackward: {
				textDocumentProxy.deleteBackward()
				lastReplaceDeleteCount += 1
				return textDocumentProxy.documentContextBeforeInput
			},
			insert: {
				shortenRecordedGlides(by: matched.count)
				insertIntoHost($0)
			})
		if applied && replacement.isEmpty {
			shortenRecordedGlides(by: matched.count)
		} else if !applied && lastReplaceDeleteCount > 0 {
			recordedGlideFollowUps.removeAll()
		}
		return applied
	}
}
