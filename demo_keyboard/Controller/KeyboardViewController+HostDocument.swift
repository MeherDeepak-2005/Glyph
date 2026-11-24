import UIKit

extension KeyboardViewController {

    func handleHostCallback() {
        let firstConnection = hostConnectionDidBecomeAvailable()
        let traitsChanged = updateInputTraits()
        let changed = reconcileHostDocument()
        if traitsChanged && !changed { resetDocumentPresentation() }
        if firstConnection || traitsChanged { scheduleSuggestions() }
        updateActionKey()
        updateAutoShift()
    }

    private static let documentIdentifierSelector = NSSelectorFromString("documentIdentifier")

    func readHostDocument() -> HostDocumentSnapshot? {
        guard hostConnectionReady, !isSecureField else { return nil }
        let proxy = textDocumentProxy
        guard let documentID = (proxy as AnyObject).perform(Self.documentIdentifierSelector)?
                .takeUnretainedValue() as? UUID else {
            KBDiagnostics.noteIntegrityEvent("host-document-id-missing")
            return nil
        }
        return HostDocumentSnapshot(documentID: documentID,
            before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
            selection: proxy.selectedText, hasText: proxy.hasText)
    }

    @discardableResult
    func reconcileHostDocument(_ state: HostDocumentSnapshot? = nil) -> Bool {
        let change = documentReconciler.observe(state ?? readHostDocument())
        switch change {
        case .changed, .cleared:
            KBDiagnostics.noteIntegrityEvent("host-document-reset")
            resetDocumentPresentation()
            keyboard?.dismissOverlaysIfActive()
            scheduleSuggestions()
            updateActionKey()
            updateAutoShift()
            return true
        case .initial, .unchanged, .unavailable, .editing:
            updateRecoveryTimer()
            return false
        }
    }

    func resetDocumentPresentation() {
        invalidateDocumentSession()
        cancelGlidePreview(clearStrip: true)
        lastCorrection = nil
        recentCorrections.removeAll(keepingCapacity: true)
        resetEraseTracking()
        lastSpaceAt = 0
        resolveGlideUnverified()
        cursorModeActive = false
        nwpPredictedTop3.removeAll(keepingCapacity: true)
        nwpPredictionArmed = false
        mode = .predict
        presentationDocument = nil
        keyboard?.setKeyPriors([:])
        keyboard?.dismissTools()
        setSuggestionBar([])
    }

    private func updateRecoveryTimer() {
        let needed = hostConnectionReady && suggestionsAllowed && documentReconciler.needsRecovery
        if needed && recoveryMonitor == nil {
            recoveryMonitor = HostDocumentRecoveryMonitor { [weak self] in
                self?.reconcileHostDocument()
            }
        }
        recoveryMonitor?.setEnabled(needed)
    }

    func beginKeyboardEdit(reconcileFirst: Bool = true) {
        if reconcileFirst && documentReconciler.editDepth == 0 { reconcileHostDocument() }
        documentReconciler.beginKeyboardEdit()
        keyboard?.dismissTools()
    }

    func endKeyboardEdit() {
        let finalState = documentReconciler.editDepth == 1 ? readHostDocument() : nil
        let previousState = documentReconciler.snapshot
        var unexpectedInsertion = false
        if documentReconciler.editDepth == 1, let text = expectedLetterInsertion {
            expectedLetterInsertion = nil
            if let finalState, finalState.isAvailable {
                unexpectedInsertion = documentReconciler.snapshot?.acceptsInsertion(text, result: finalState) != true
            }
        }
        documentReconciler.endKeyboardEdit(finalState)
        if unexpectedInsertion || (finalState?.isEmpty == true && lastCorrection != nil) {
            KBDiagnostics.noteIntegrityEvent("host-edit-diverged")
            resetDocumentPresentation()
            scheduleSuggestions()
        } else if documentReconciler.editDepth == 0 {
            finishRecordedWordEdit(before: previousState, after: finalState)
        }
        updateRecoveryTimer()
    }

	@discardableResult
	private func hostConnectionDidBecomeAvailable() -> Bool {
		let firstConnection = !hostConnectionReady
		if firstConnection {
			hostConnectionReady = true
			KBSettings.markKeyboardObserved(fullAccess: hasFullAccess)
			resolveSuggestionModeIfNeeded()
			let requiresSwitchKey = needsInputModeSwitchKey
			if showsGlobe != requiresSwitchKey {
				showsGlobe = requiresSwitchKey
				buildKeyboard()
			}
		}
		keyboard?.isUserInteractionEnabled = true
		keyboard?.accessibilityElementsHidden = false
		resolveSuggestionModeIfNeeded()

		if !supplementaryLexiconRequested {
			supplementaryLexiconRequested = true
			requestSupplementaryLexicon { [weak self] lexicon in
				self?.engine.importSupplementaryLexicon(lexicon.entries.map(\.documentText))
			}
		}
		if firstConnection {
			updateActionKey()
			updateAutoShift()
		}
		return firstConnection
	}
}
