import Foundation

extension KeyboardEngine {

	func isLatest(_ gen: Int) -> Bool { genLock.lock(); defer { genLock.unlock() }; return gen == suggestGen }
	func cancelSuggestions() {
		genLock.lock(); sharedDecodeToken?.cancel(); suggestGen &+= 1; genLock.unlock()
	}

	func decode(_ request: DecodeRequest, completion: @escaping (DecodeSnapshot) -> Void) {
		genLock.lock(); sharedDecodeToken?.cancel(); let nativeToken = KBCancellationToken(); sharedDecodeToken = nativeToken; suggestGen &+= 1; let gen = suggestGen; genLock.unlock()
		let started = ProcessInfo.processInfo.systemUptime
		let isWordStart = request.currentWord.isEmpty
		let signpost = KBDiagnostics.beginTapDecode()
		queue.async { [weak self] in
			defer {
				let ms = (ProcessInfo.processInfo.systemUptime - started) * 1_000
				KBDiagnostics.endTapDecode(signpost, milliseconds: ms)
				if isWordStart { KBDiagnostics.recordInitializationLatency(milliseconds: ms) }
			}
			guard let self, self.isLatest(gen) else { return }
			KBDiagnostics.recorder.sample()
			let currentWord = request.currentWord
			let lw = currentWord.lowercased()
			let taps = self.touchProfile.adjusted(request.taps, typed: lw)
			let publish: ([String], [DecodeCandidateEvidence], String?, Double) -> Void = { suggestions, evidence, decision, confidence in
				let priors = self.contextualCharPriors(evidence: evidence, prefix: lw,
					base: self.lexicon.nextCharPriors(prefix: lw))
				guard self.isLatest(gen) else { return }
				let snapshot = DecodeSnapshot(request: request, suggestions: suggestions,
					candidates: evidence, correction: decision, confidence: confidence,
					nextCharacterPriors: priors, completedAtUptime: ProcessInfo.processInfo.systemUptime)
				DispatchQueue.main.async { completion(snapshot) }
			}
			guard let engine = self.sharedEngine else {
				publish(currentWord.isEmpty ? [] : [currentWord], [], nil, 0)
				return
			}
			let view = self.lexicon.nativeGenerationView()
			let identity = [request.fieldRevision, request.documentRevision, request.wordSessionID,
				request.generation, request.layoutRevision, self.lexicon.vocabularyRevision, KBPersonalData.currentEpoch]
			let buffers = NativeTapBuffers(taps: taps, expectedCount: lw.utf8.count)
			do {
				let result = try engine.decode(word: currentWord, normalized: lw, context: request.context.map { $0.lowercased() },
					identity: identity.withUnsafeBytes { Data($0) }, tapOffsets: buffers?.offsets, tapValidity: buffers?.validity,
					lexicon: view, personal: self.user.nativeCountsSnapshot(), kept: self.isKept(lw), token: nativeToken)
				guard !result.cancelled, self.isLatest(gen) else { return }
				let typedScore = result.rows.first(where: { $0.word == lw })?.score ?? 0
				let evidence = zip(result.rows, result.sources).map { row, source in
					DecodeCandidateEvidence(word: row.word, score: row.score, spatialCost: row.cost,
						logFrequency: row.logFrequency, logLanguageProbability: row.language,
						source: DecodeCandidateSource(rawValue: source) ?? .fuzzyLexicon, typedWordMargin: row.score - typedScore)
				}
				publish(result.suggestions, evidence, result.correction.word, result.correction.margin)
			} catch {
				KBDiagnostics.recorder.storageFailure(operation: "native-decode")
				publish(currentWord.isEmpty ? [] : [currentWord], [], nil, 0)
			}
		}
	}

	func suggestions(currentWord: String, context: [String], taps: [KeyTap?]? = nil,
					 completion: @escaping ([String], [Character: Double]) -> Void) {
		let request = DecodeRequest(fieldRevision: 0, documentRevision: 0,
			wordSessionID: 0, generation: 0, layoutRevision: 0,
			currentWord: currentWord, context: context, taps: taps)
		decode(request) { completion($0.suggestions, $0.nextCharacterPriors) }
	}

	func importSupplementaryLexicon(_ words: [String]) {
		queue.async { [weak self] in
			guard let self else { return }
			for w in words {
				let lw = w.lowercased()
				guard lw.count >= 2, lw.allSatisfy({ $0.isLetter || $0 == "'" }),
					  !self.lexicon.contains(lw), self.lexicon.isSafeToLearn(lw) else { continue }
				self.lexicon.insert(lw, freq: 50)
			}
		}
	}

	func learn(word: String) {
		let lw = word.lowercased()
		guard lw.count >= 2 || lw == "a" || lw == "i",
			  lw.allSatisfy({ $0.isLetter || $0 == "'" }) else { return }
		if !lexicon.isSafeToLearn(lw) { return }
		queue.async { [weak self] in
			guard let self else { return }
			self.user.learn(word: lw)
			self.user.pruneIfNeeded()
			let count = self.user.uniCount(lw)
			self.lexicon.noteUse(of: lw, timesUsed: count, adoptAfter: self.adoptAfter,
				allowAdoption: self.allowsPersonalAdoption(of: lw, count: count))
			self.scheduleSave()
		}
	}

	func learnTouchProfile(word: String, taps: [KeyTap?]) {
		let lower = word.lowercased()
		guard lower.utf8.count == taps.count,
			  lower.utf8.allSatisfy({ KB.pos[$0] != nil }) else { return }
		queue.async { [weak self] in
			guard let self, self.lexicon.isStaticWord(lower),
				  self.lexicon.isSafeToLearn(lower) else { return }
			self.touchProfile.observe(word: lower, taps: taps)
		}
	}

	func allowsPersonalAdoption(of word: String, count: Int) -> Bool {
		user.allowsAdoption(word, count: count, lexicon: lexicon.nativeGenerationView())
	}
}
