import UIKit

extension KeyboardViewController {

	@discardableResult
	func applyAutocorrectIfNeeded() -> Correction? {
		guard autocorrectionAllowed else { return nil }
		guard let snapshot = currentPresentedDecodeSnapshot else { return nil }
		let word = snapshot.canonical.request.currentWord
		guard !word.isEmpty,
			  let correction = snapshot.correction,
			  correction != word else { return nil }
		guard textDocumentProxy.selectedText?.isEmpty != false,
			replaceHostSuffix(word, with: correction) else {
			KBDiagnostics.noteIntegrityEvent("correction-host-mismatch")
			return nil
		}
		recordTyping("autocorrection", text: word, replacement: correction, evidence: "automatic-unverified",
			snapshot: snapshot.canonical)
		noteProxyEdit()
		recentCorrections.append((original: word, corrected: correction, word: wordSessionID))
		if recentCorrections.count > 4 { recentCorrections.removeFirst() }
		return Correction(original: word, corrected: correction, trailing: "", fromAutocorrect: true, recordedWordSessionID: wordSessionID)
	}

	func resetEraseTracking() {
		erasedWord = ""
		erasedCrossedBoundary = false
		replacementStarted = false
	}

	func trackErase(of char: Character?) {
		replacementStarted = false
		guard let char else { resetEraseTracking(); return }
		if isWordChar(char) {
			if erasedCrossedBoundary {
				erasedWord = String(char)
				erasedCrossedBoundary = false
			} else {
				erasedWord.insert(char, at: erasedWord.startIndex)
			}
			if erasedWord.count > 24 { resetEraseTracking() }
		} else if !erasedWord.isEmpty {
			erasedCrossedBoundary = true
		}
	}

	func trackReplacementStart(wasInsideWord: Bool) {
		guard !erasedWord.isEmpty, !replacementStarted else { return }
		replacementStarted = true
		if wasInsideWord { resetEraseTracking() }
	}

	func resolveManualFix(_ committed: String) {
		defer { resetEraseTracking() }
		let erased = HostDocumentSnapshot.folded(erasedWord)
		guard erased.count >= 2, !committed.isEmpty,
			  erased.lowercased() != committed.lowercased(), !isSecureField else { return }
		let corrected = recentCorrections.last(where: { $0.corrected.lowercased() == erased.lowercased() })
		let revertedCorrection = corrected?.original.lowercased() == committed.lowercased()
		if revertedCorrection {
			rejectCorrection(committed)
			decodeSnapshot = nil
			presentedDecodeSnapshot = nil
		}
		recordTyping("manual-replacement", text: erased, replacement: committed,
			evidence: revertedCorrection ? "manual-autocorrect-undo" : corrected != nil ? "manual-fix-of-correction" : "inferred-word-swap",
			relatedWord: corrected?.word)
		recordReplacement(original: erased, replacement: committed)
	}
}
