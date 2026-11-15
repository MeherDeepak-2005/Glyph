// English decoding: one versioned, asynchronously published decode contract over the shared
// C++ engine (native/DecoderCore). The engine decodes in the neural search space
// (tools/nss, keyboard/nss-english.nsslm) over the dictionary langdata.bin (built by
// tools/build_language_data.py): the joint search of the edit/touch channel, the dictionary
// trie and the neural word model, with the dictionary's unigram distribution as its floor.
// There is no other language model and no fallback decoder: without the dictionary or the
// model the keyboard types without suggestions or autocorrect.
//
// Autocorrect decisions are precomputed by background decoding while the word is being
// typed. A boundary consumes only a matching immutable snapshot; if none is ready, the typed
// word is preserved. Decoding never runs on the input path.
//
// Both files are MEMORY-MAPPED at launch: the dictionary trie and the model weights are read
// in place, clean pages the OS can evict, so they barely count against the extension's
// ~60–70 MB kill limit (heap counts in full). Only the small dynamic tries (adopted and
// contact words) stay on the heap.

final class KeyboardEngine {

	/// SERIAL, deliberately. One background pass at a time: a superseded suggestion pass
	/// bails at entry in microseconds (gen ticket), so work coalesces instead of piling up.
	/// Nothing on the keystroke path waits on this queue; boundary commits consume an
	/// already-published DecodeSnapshot or leave the typed word unchanged.
	let queue = DispatchQueue(label: "keyboard.engine")
	/// Glide must not wait behind a suggestion pass. Final decodes and
	/// live previews use separate queues; the final queue has interactive priority and
	/// stale preview work cooperatively exits when the finger lifts.
	let glideQueue = DispatchQueue(label: "keyboard.engine.glide", qos: .userInteractive)
	let glidePreviewQueue = DispatchQueue(label: "keyboard.engine.glide.preview", qos: .userInitiated)
	let initializationGroup = DispatchGroup()
	let glidePreviewLock = NSLock()
	var glidePreviewGeneration = 0
	let glidePreviewCacheLock = NSLock()
	struct GlidePreviewCache {
		let key: UInt64
		let createdAt: TimeInterval
		let prediction: GlidePrediction
	}
	var glidePreviewCache: GlidePreviewCache?
	let lexicon = Lexicon()
	let user: UserModel
	/// Built once, on `queue`, when initialization finishes. Nil when the dictionary or the
	/// model did not load; English then types without suggestions or autocorrect.
	var sharedEngine: KBSharedEngine?
	var sharedDecodeToken: KBCancellationToken?
	let touchProfile = TouchSpatialProfile()

	/// Commits before a non-dictionary word enters the dynamic vocabulary (and so becomes
	/// suggestable + immune to autocorrect). A word you were only testing or typo'd
	/// repeatedly shouldn't graduate into the dictionary (see Personalization::allowsAdoption).
	let adoptAfter = 8

	/// Session-only autocorrect rejections live in native Personalization.
	func isKept(_ word: String) -> Bool { user.isKept(word) }

	/// Learning fires on every committed word, and `user.save()` re-encodes the WHOLE
	/// personal model to JSON — O(model) work and a matching transient allocation on
	/// the engine barrier, per word typed. Coalesce to one save per 2 s typing burst.
	/// Rare, signal-bearing events (kept words, undo healing) still save immediately;
	/// losing ≤2 s of ordinary counts to a jetsam kill is an acceptable trade.
	private var savePending = false
	func scheduleSave() {
		guard !savePending else { return }
		savePending = true
		queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
			guard let self else { return }
			self.savePending = false
			self.user.save()
		}
	}

	/// Process-wide engine: iOS may prewarm more than one controller, while language
	/// data and personalization should be loaded exactly once per extension process.
	static let shared = KeyboardEngine()

	/// The word-level neural search space model (tools/nss), mapped on `queue` at startup.
	private let neuralWordModelURL: URL?
	private(set) var neuralWordModel: KBNeuralWordModel?
	private let readinessLock = NSLock()
	private var engineReady = false
	/// True once the shared engine exists (the dictionary and the model both loaded).
	var isReady: Bool {
		readinessLock.lock(); defer { readinessLock.unlock() }
		return engineReady
	}

	/// Gives the native decoder the English layout pack's letter grid (the one `KB` and the
	/// keys on screen use), once per process and before any decode.
	static let nativeKeyGridInstalled: Bool = {
		let pack = LatinLayoutPack.english
		let installed = KBKeyGrid.installRows(pack.gridRows,
			offsets: pack.gridRowOffsets.map { NSNumber(value: $0) })
		assert(installed, "the native decoder refused layout \(pack.identifier)'s grid")
		return installed
	}()

	init(languageDataURL: URL? = nil,
		 neuralWordModelURL: URL? = Bundle.main.url(forResource: "nss-english", withExtension: "nsslm"),
		 userModel: UserModel? = nil) {
		_ = Self.nativeKeyGridInstalled
		self.user = userModel ?? UserModel()
		self.neuralWordModelURL = neuralWordModelURL
		initializationGroup.enter()
		let ready = initializationGroup
		queue.async { [weak self] in
			defer { ready.leave() }
			guard let self else { return }
			if let languageDataURL { self.lexicon.load(from: languageDataURL) }
			else { self.lexicon.loadFromBundle() }
			self.user.load()
			self.applyLearned()
			if let url = self.neuralWordModelURL {
				do { self.neuralWordModel = try KBNeuralWordModel(url: url) }
				catch { KBDiagnostics.recorder.storageFailure(operation: "nss-model-load") }
			} else { KBDiagnostics.recorder.storageFailure(operation: "nss-model-missing") }
			self.sharedEngine = self.makeSharedEngine()
			KBPersonalData.acknowledgeReset(epoch: KBPersonalData.currentEpoch)
			// Build the NSS graph in the first idle moment instead of inside the first decode,
			// whose cost it otherwise is. Enqueued behind any decode already waiting, which then
			// builds it itself.
			if self.sharedEngine != nil {
				self.queue.async { [weak self] in self?.sharedEngine?.prepareNeuralSearchSpace() }
			}
		}
	}

	/// Nil when the dictionary or the model did not load.
	private func makeSharedEngine() -> KBSharedEngine? {
		guard let neural = neuralWordModel else { return nil }
		let engine = KBSharedEngine(lexicon: lexicon.nativeGenerationView(), neural: neural, safety: lexicon.nativeSafety)
		if engine == nil { KBDiagnostics.recorder.storageFailure(operation: "native-engine") }
		readinessLock.lock(); engineReady = engine != nil; readinessLock.unlock()
		return engine
	}

	func handleMemoryPressure() {
		queue.async { [weak self] in self?.sharedEngine?.memoryPressure() }
	}

	private func applyLearned() {
		// Kept words deliberately do NOT enter the trie: keeping means "stop
		// correcting this", not "suggest this". They still adopt organically below
		// once typed adoptAfter times. Snapshot (COW) so no lock is held across the loop.
		for (w, c) in user.unigramsSnapshot() {
			let count = min(c, 50)
			lexicon.noteUse(of: w, timesUsed: count, adoptAfter: adoptAfter,
				allowAdoption: allowsPersonalAdoption(of: w, count: count))
		}
	}

	/// Applies an app-initiated personal-data reset to the already-running extension.
	/// Generation tickets are invalidated synchronously; mutable model state is cleared
	/// on the engine queue after initialization so no decoder observes a half-reset state.
	func resetPersonalization(to epoch: UInt64 = KBPersonalData.currentEpoch) {
		cancelSuggestions()
		cancelGlidePreviews()
		glideLock.lock()
		lastGlideOutcome = nil
		glideLock.unlock()
		glidePreviewCacheLock.lock()
		glidePreviewCache = nil
		glidePreviewCacheLock.unlock()

		queue.async { [weak self] in
			guard let self else { return }
			self.initializationGroup.wait()
			// Drop the graph's cached context states: they hold words typed before the reset.
			self.sharedEngine?.memoryPressure()
			self.savePending = false
			self.user.reset(to: epoch)
			self.lexicon.resetPersonalization()
			self.touchProfile.reset()
			KBPersonalData.acknowledgeReset(epoch: epoch)
		}
	}

	// MARK: Glide session state
	// Behaviour lives in KeyboardEngine+Glide.swift; stored state must stay on the class.

	let glideSessionIDLock = NSLock()
	var nextGlideSessionID: UInt64 = 0

	/// Live streaming sessions, accessed only on `glidePreviewQueue`.
	var glideSessions: [GlideSessionID: StreamingGlideSession] = [:]

	/// Last committed glide, held until the user's verdict arrives (see KeyboardEngine+Glide.swift).
	let glideLock = NSLock()
	struct GlideOutcome {
		let id: String
		let winner: String
		let shapeCostByWord: [String: Double]
		/// For the typing recorder: the strip's alternatives, the winner's score margin and
		/// which decode produced the word (preview, cache, session or final).
		let alternatives: [String]
		let margin: Double
		let source: String
	}
	var lastGlideOutcome: GlideOutcome?

	// MARK: Suggestion pass state

	/// Fast typing queues several passes on the serial engine queue; without a ticket each
	/// would run its full search even when a newer keystroke had already superseded it.
	/// Ticket outside, check inside: a pass that is no longer the newest returns before
	/// doing anything — this coalescing is WHY the queue can stay serial without backlog.
	/// NSLock, not the engine queue, guards the counter — the increment happens on the
	/// caller's thread.
	let genLock = NSLock()
	var suggestGen = 0
}
