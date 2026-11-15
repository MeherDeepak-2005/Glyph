import Foundation
import CoreGraphics

extension KeyboardEngine {
	// MARK: Glide typing
	//
	// Every glide decodes in the shared engine's neural search space (KBSharedGlide): shape
	// candidates from the dictionary trie, steered by the NSS graph's lookahead, ranked by
	// shape and the graph's score in context. Live previews stream one session per gesture;
	// the final decision is the last visible prediction, or one full-path decode when none
	// was shown.

	/// Accessed only on `glidePreviewQueue`. Each session retains its native glide stream
	/// for the lifetime of one finger gesture.
	struct StreamingGlideSession {
		let id: GlideSessionID
		let context: [String]
		var shared: KBSharedGlide?
		/// Vocabulary cannot change mid-gesture; computed once when the shared stream starts.
		var dynamicWords: [String] = []
		var revision: UInt64 = 0
		var latestPrediction: GlidePrediction?
		var invalid = false
	}

	private func currentGlidePreviewGeneration() -> Int {
		glidePreviewLock.lock(); defer { glidePreviewLock.unlock() }
		return glidePreviewGeneration
	}

	private func isCurrentGlidePreview(_ generation: Int) -> Bool {
		glidePreviewLock.lock(); defer { glidePreviewLock.unlock() }
		return generation == glidePreviewGeneration
	}

	/// Called at gesture start, cancellation, and lift. A decoder already running checks
	/// this ticket and exits instead of competing with the final pass.
	func cancelGlidePreviews() {
		glidePreviewLock.lock()
		glidePreviewGeneration &+= 1
		glidePreviewLock.unlock()
		glidePreviewQueue.async { [weak self] in self?.glideSessions.removeAll(keepingCapacity: true) }
	}

	func beginGlideSession(context: [String]) -> GlideSessionID {
		glideSessionIDLock.lock()
		nextGlideSessionID &+= 1
		let id = GlideSessionID(rawValue: nextGlideSessionID)
		glideSessionIDLock.unlock()
		glidePreviewQueue.async { [weak self] in
			self?.glideSessions[id] = StreamingGlideSession(id: id, context: context)
		}
		return id
	}

	func cancelGlideSession(_ id: GlideSessionID) {
		glidePreviewQueue.async { [weak self] in self?.glideSessions[id] = nil }
	}

	/// Consume a cumulative UIKit path. Completion is always delivered on main so the
	/// controller can directly publish the middle suggestion without another hop.
	func updateGlideSession(_ id: GlideSessionID, path: [CGPoint], times: [TimeInterval],
		layout: GlideLayout, completion: @escaping (GlideUpdate?) -> Void) {
		let started = ProcessInfo.processInfo.systemUptime
		let signpost = KBDiagnostics.beginGlidePreview()
		glidePreviewQueue.async { [weak self] in
			defer {
				KBDiagnostics.endGlidePreview(signpost,
					milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
			}
			guard let self else {
				DispatchQueue.main.async { completion(nil) }
				return
			}
			self.initializationGroup.wait()
			guard var session = self.glideSessions[id] else {
				DispatchQueue.main.async { completion(nil) }
				return
			}
			let update = self.consumeStreamingPath(path, layout: layout, session: &session)
			self.glideSessions[id] = session.invalid ? nil : session
			DispatchQueue.main.async { completion(update) }
		}
	}

	/// Finalizes from the same retained session. Only the winner and visible runners-up
	/// receive exact full-path shape costs, for learning and diagnostics.
	func finishGlideSession(_ id: GlideSessionID, path: [CGPoint], times: [TimeInterval],
		layout: GlideLayout, completion: @escaping (String?, [String]) -> Void) {
		let started = ProcessInfo.processInfo.systemUptime
		let signpost = KBDiagnostics.beginGlideFinal()
		glidePreviewQueue.async { [weak self] in
			defer {
				KBDiagnostics.endGlideFinal(signpost,
					milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
			}
			guard let self else {
				DispatchQueue.main.async { completion(nil, []) }
				return
			}
			self.initializationGroup.wait()
			guard var session = self.glideSessions.removeValue(forKey: id) else {
				self.glide(path: path, times: times, layout: layout, context: [], completion: completion)
				return
			}
			let update = self.consumeStreamingPath(path, layout: layout, session: &session)
			guard !session.invalid else {
				self.glide(path: path, times: times, layout: layout, context: session.context, completion: completion)
				return
			}
			guard let prediction = update?.prediction ?? session.latestPrediction,
				let processed = GlidePreprocess.run(path, layout: layout, times: times.isEmpty ? nil : times) else {
				DispatchQueue.main.async { completion(nil, []) }
				return
			}
			let displayed = [prediction.word] + prediction.alternatives
			var exactCosts: [String: Double] = [:]
			for word in displayed {
				if let cost = GlideDecoder.shapeCost(of: word, processed) { exactCosts[word] = cost }
			}
			// The streaming snapshot is authoritative: exact costs are retained only for
			// learning/diagnostics and never change the displayed commit decision.
			let committed = GlidePrediction(word: prediction.word, alternatives: prediction.alternatives,
				shapeCostByWord: exactCosts, margin: prediction.margin)
			let gestureID = self.noteGlideCommit(committed, source: "session")
			DispatchQueue.main.async { completion(committed.word, committed.alternatives) }
			self.glideQueue.async { [weak self] in
				self?.logCachedGlide(committed, path: path, times: times,
					layout: layout, processed: processed, gestureID: gestureID)
			}
		}
	}

	/// Runs the gesture's native stream over the whole path so far. Nil without a shared
	/// engine (no dictionary or model) or when nothing matched.
	private func consumeStreamingPath(_ path: [CGPoint], layout: GlideLayout,
		session: inout StreamingGlideSession) -> GlideUpdate? {
		guard let engine = sharedEngine else { return nil }
		if session.shared == nil {
			session.shared = engine.glideSession(withContext: session.context.map { $0.lowercased() })
			session.dynamicWords = lexicon.glideDynamicWords(limit: 128)
		}
		guard let shared = session.shared else { return nil }
		do {
			guard let prediction = try prediction(shared, path: path, layout: layout,
				dynamicWords: session.dynamicWords) else { return nil }
			session.revision &+= 1; session.latestPrediction = prediction
			return GlideUpdate(sessionID: session.id, revision: session.revision, prediction: prediction)
		} catch { session.invalid = true; return nil }
	}

	/// The ranked words of one native glide update as a prediction: the winner, three
	/// alternatives, the shape costs of the best dozen and the winner's score margin.
	private func prediction(_ shared: KBSharedGlide, path: [CGPoint], layout: GlideLayout,
		dynamicWords: [String]) throws -> GlidePrediction? {
		let scored = try shared.update(GlideBuffers.points(path), keys: GlideBuffers.keys(layout),
			centers: GlideBuffers.points(layout.centers.map(\.point)), xPitch: Double(layout.xPitch), yPitch: Double(layout.yPitch),
			lexicon: lexicon.nativeGenerationView(), personal: user.nativeCountsSnapshot(), dynamicWords: dynamicWords)
		guard let winner = scored.first else { return nil }
		return GlidePrediction(word: winner.word, alternatives: scored.dropFirst().prefix(3).map(\.word),
			shapeCostByWord: Dictionary(scored.prefix(12).map { ($0.word, $0.cost) }, uniquingKeysWith: min),
			margin: scored.count > 1 ? scored[0].score - scored[1].score : .greatestFiniteMagnitude)
	}

	/// One full-path decode in a fresh native glide session.
	private func decodeGlide(path: [CGPoint], layout: GlideLayout, context: [String]) -> GlidePrediction? {
		guard let engine = sharedEngine else { return nil }
		let shared = engine.glideSession(withContext: context.map { $0.lowercased() })
		return try? prediction(shared, path: path, layout: layout, dynamicWords: lexicon.glideDynamicWords(limit: 128))
	}

	/// In-progress decode for UI feedback, single-flight per the controller, so preview work
	/// can never occupy the final decoder or the suggestion queue.
	func glidePreview(path: [CGPoint], times: [TimeInterval] = [], layout: GlideLayout,
					  context: [String], completion: @escaping (GlidePrediction?) -> Void) {
		let generation = currentGlidePreviewGeneration()
		let cacheKey = glideCacheKey(path: path, times: times, layout: layout, context: context)
		let started = ProcessInfo.processInfo.systemUptime
		let signpost = KBDiagnostics.beginGlidePreview()
		glidePreviewQueue.async { [weak self] in
			defer {
				KBDiagnostics.endGlidePreview(signpost,
					milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
			}
			func deliver(_ prediction: GlidePrediction?) {
				DispatchQueue.main.async { completion(prediction) }
			}
			guard let self else { return deliver(nil) }
			self.initializationGroup.wait()
			guard self.isCurrentGlidePreview(generation),
				  let prediction = self.decodeGlide(path: path, layout: layout, context: context) else { return deliver(nil) }
			self.storeGlidePreview(prediction, key: cacheKey)
			deliver(prediction)
		}
	}

	private func storeGlidePreview(_ prediction: GlidePrediction, key: UInt64) {
		glidePreviewCacheLock.lock()
		glidePreviewCache = GlidePreviewCache(
			key: key,
			createdAt: ProcessInfo.processInfo.systemUptime,
			prediction: prediction
		)
		glidePreviewCacheLock.unlock()
	}

	private func recentGlidePreview(key: UInt64) -> GlidePrediction? {
		glidePreviewCacheLock.lock(); defer { glidePreviewCacheLock.unlock() }
		guard let cached = glidePreviewCache,
			  cached.key == key,
			  // A user may pause on the final key before lifting. The exact cache key
			  // already includes every path point, timestamp, layout pitch, and context,
			  // so a five-second gesture-local window is safer than expiring a valid
			  // displayed result after 350 ms and launching a disagreeing final decode.
			  ProcessInfo.processInfo.systemUptime - cached.createdAt <= 5.0
		else { return nil }
		return cached.prediction
	}

	/// Stable FNV-1a fingerprint of the exact raw path, timing samples, layout scale,
	/// and language context. A cache hit therefore means preview and commit consumed
	/// identical evidence, not merely a similar endpoint.
	private func glideCacheKey(path: [CGPoint], times: [TimeInterval], layout: GlideLayout,
							   context: [String]) -> UInt64 {
		var hash: UInt64 = 0xcbf29ce484222325
		func mix(_ value: UInt64) {
			hash = (hash ^ value) &* 0x100000001b3
		}
		mix(UInt64(path.count))
		for point in path {
			mix(Double(point.x).bitPattern)
			mix(Double(point.y).bitPattern)
		}
		mix(UInt64(times.count))
		for time in times { mix(time.bitPattern) }
		mix(Double(layout.xPitch).bitPattern)
		mix(Double(layout.yPitch).bitPattern)
		for word in context {
			for byte in word.utf8 { mix(UInt64(byte)) }
			mix(0xff)
		}
		return hash
	}

	/// Decode a swipe into a word and deliver the winner and up to 3 alternatives for the
	/// suggestion bar (swap targets) on the MAIN queue; (nil, []) when the swipe matched
	/// nothing.
	func glide(path: [CGPoint], times: [TimeInterval] = [], layout: GlideLayout, context: [String],
				   publishedPrediction: GlidePrediction? = nil,
				   completion: @escaping (String?, [String]) -> Void) {
		cancelGlidePreviews()
		// Invalidate any suggestion pass already dispatched to the engine queue.
		// A queued pass that hasn't started yet bails at its isLatest() check;
		// a pass mid-execution still completes, but any further queued ones skip.
		// The controller also cancels the debounced work item before calling here.
		cancelSuggestions()
		if let publishedPrediction {
			let gestureID = noteGlideCommit(publishedPrediction, source: "preview")
			// The visible preview is the gesture's contract. Commit it inline on the
			// main-thread lift callback; never run a second decoder that can disagree.
			completion(publishedPrediction.word, publishedPrediction.alternatives)
			glideQueue.async { [weak self] in
				guard let self,
					  let processed = GlidePreprocess.run(path, layout: layout,
						times: times.isEmpty ? nil : times) else { return }
				self.logCachedGlide(publishedPrediction, path: path, times: times,
					layout: layout, processed: processed, gestureID: gestureID)
			}
			return
		}
		let cacheKey = glideCacheKey(path: path, times: times, layout: layout, context: context)
		if let cached = recentGlidePreview(key: cacheKey) {
			let gestureID = noteGlideCommit(cached, source: "cache")
			// `glide` is invoked from touchesEnded on main. Deliver inline so an exact
			// preview hit inserts before the next display frame.
			completion(cached.word, cached.alternatives)
			glideQueue.async { [weak self] in
				guard let self,
					  let processed = GlidePreprocess.run(path, layout: layout, times: times.isEmpty ? nil : times)
				else { return }
				self.logCachedGlide(cached, path: path, times: times, layout: layout,
					processed: processed, gestureID: gestureID)
			}
			return
		}
		// Dedicated interactive queue: the full-path decision never waits behind
		// suggestions or a live-preview decode.
		let finalStarted = ProcessInfo.processInfo.systemUptime
		let finalSignpost = KBDiagnostics.beginGlideFinal()
		glideQueue.async { [weak self] in
			defer {
				KBDiagnostics.endGlideFinal(finalSignpost,
					milliseconds: (ProcessInfo.processInfo.systemUptime - finalStarted) * 1_000)
			}
			func deliver(_ w: String?, _ alts: [String]) { DispatchQueue.main.async { completion(w, alts) } }
			guard let self else { return deliver(nil, []) }
			self.initializationGroup.wait()
			guard let processed = GlidePreprocess.run(path, layout: layout, times: times.isEmpty ? nil : times)
			else { return deliver(nil, []) }
			guard let prediction = self.decodeGlide(path: path, layout: layout, context: context) else {
				deliver(nil, [])
				KBDiagnostics.logGlide(points: processed.points.count, pivots: processed.pivots.count, letters: "rejected")
				return
			}
			// Stash raw shape costs so an explicit alternative selection can provide a
			// supervised sample. An automatic commit is never treated as ground truth.
			let gestureID = self.noteGlideCommit(prediction, source: "final")
			// Queue the visible insertion before diagnostics and optional capture formatting.
			// Those facilities must never add lift-to-insert latency.
			deliver(prediction.word, prediction.alternatives)
			self.logCachedGlide(prediction, path: path, times: times, layout: layout,
				processed: processed, gestureID: gestureID)
		}
	}

	private func logCachedGlide(_ prediction: GlidePrediction, path: [CGPoint], times: [TimeInterval],
							layout: GlideLayout, processed: ProcessedGlide, gestureID: String) {
		let displayed = [prediction.word] + prediction.alternatives
		KBDiagnostics.logGlide(points: processed.points.count, pivots: processed.pivots.count,
							   letters: displayed.joined(separator: ","), margin: prediction.margin)
		// Offline calibration capture (debug flag): RAW grid path + timestamps, dwell letters
		// and the commit margin.
		let rawGrid = path.map { point -> (Double, Double) in
			let grid = GlidePreprocess.toGrid(point, layout: layout)
			return (Double(grid.x), Double(grid.y))
		}
		KBDiagnostics.captureGlide(id: gestureID, path: rawGrid, times: times.map { Double($0) },
								   dwell: processed.dwellKeys, candidates: Array(displayed.prefix(3)),
								   committed: prediction.word, margin: prediction.margin)
	}

	// MARK: The user's verdict on a committed glide
	//
	// A committed glide leaves a stash of its candidates' raw SHAPE costs. The controller
	// then reports what the user did with it. Tapping a different bar alternative is the
	// only explicit label (captured for offline calibration); typing on or deleting merely
	// discards the pending sample. None of these touch the engine queue: the stash is
	// behind `glideLock`, so a verdict fired from the main thread costs microseconds.

	@discardableResult
	private func noteGlideCommit(_ prediction: GlidePrediction, source: String) -> String {
		let id = UUID().uuidString
		glideLock.lock()
		lastGlideOutcome = GlideOutcome(id: id, winner: prediction.word, shapeCostByWord: prediction.shapeCostByWord,
			alternatives: prediction.alternatives, margin: prediction.margin, source: source)
		glideLock.unlock()
		return id
	}
	/// The gesture just committed, for the typing recorder; the verdict calls below still own it.
	func committedGlideEvidence() -> GlideOutcome? {
		glideLock.lock(); defer { glideLock.unlock() }; return lastGlideOutcome
	}
	private func takeGlideOutcome() -> GlideOutcome? {
		glideLock.lock(); defer { lastGlideOutcome = nil; glideLock.unlock() }; return lastGlideOutcome
	}

	/// Typing on is not proof that the automatic winner was intended. Discard the
	/// pending sample; only an explicit alternative supplies a label.
	func glideUnverified() { _ = takeGlideOutcome() }
	/// The user swapped the glided word for a bar alternative — THAT word is the true one.
	func glideCorrected(to word: String) {
		guard let o = takeGlideOutcome() else { return }
		KBDiagnostics.captureGlideLabel(id: o.id, intended: word.lowercased())
	}
	/// The user backspaced the whole glided word away. We don't know what they meant; only
	/// drop the stash so a later verdict can't double-count.
	func glideRejected() { _ = takeGlideOutcome() }
}
