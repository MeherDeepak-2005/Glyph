
final class KeyboardEngine {

	let queue = DispatchQueue(label: "keyboard.engine")
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
	var sharedEngine: KBSharedEngine?
	var sharedDecodeToken: KBCancellationToken?
	var tenglishGuard: TeluguLexicon { TeluguLexicon.tenglishGuard }
	let touchProfile = TouchSpatialProfile()

	let adoptAfter = 8

	func isKept(_ word: String) -> Bool { user.isKept(word) }

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

	static let shared = KeyboardEngine()

	private let neuralWordModelURL: URL?
	private(set) var neuralWordModel: KBNeuralWordModel?
	private let readinessLock = NSLock()
	private var engineReady = false
	var isReady: Bool {
		readinessLock.lock(); defer { readinessLock.unlock() }
		return engineReady
	}

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
			if self.sharedEngine != nil {
				self.queue.async { [weak self] in self?.sharedEngine?.prepareNeuralSearchSpace() }
			}
		}
	}

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
		for (w, c) in user.unigramsSnapshot() {
			let count = min(c, 50)
			lexicon.noteUse(of: w, timesUsed: count, adoptAfter: adoptAfter,
				allowAdoption: allowsPersonalAdoption(of: w, count: count))
		}
	}

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
			self.sharedEngine?.memoryPressure()
			self.savePending = false
			self.user.reset(to: epoch)
			self.lexicon.resetPersonalization()
			self.touchProfile.reset()
			KBPersonalData.acknowledgeReset(epoch: epoch)
		}
	}

	let glideSessionIDLock = NSLock()
	var nextGlideSessionID: UInt64 = 0

	var glideSessions: [GlideSessionID: StreamingGlideSession] = [:]

	let glideLock = NSLock()
	struct GlideOutcome {
		let id: String
		let winner: String
		let shapeCostByWord: [String: Double]
		let alternatives: [String]
		let margin: Double
		let source: String
	}
	var lastGlideOutcome: GlideOutcome?

	let genLock = NSLock()
	var suggestGen = 0
}
