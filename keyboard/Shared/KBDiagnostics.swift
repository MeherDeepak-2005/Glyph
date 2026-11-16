import Foundation
import os

enum KBDiagnostics {

	struct Snapshot: Codable {
		var updated = Date.distantPast
		var warningCount = 0
		var criticalCount = 0
		var peakFootprintMB = 0.0
		var minAvailableMB = 0.0
		var limitMB = 0.0
		var footprintNowMB: Double?
		var surfaceLog: [String]?
		var integrityEvents: [String: Int]?
		var storageFailureCount: Int?
		var lastStorageOperation: String?
		var hostInsertLatencyBins: [Int]?
		var tapDecodeLatencyBins: [Int]?
		var glidePreviewLatencyBins: [Int]?
		var glideFinalLatencyBins: [Int]?
		var glideCommitLatencyBins: [Int]?
		var initLatencyBins: [Int]?

		var wordsCommitted: Int?
		var wordsModified: Int?
		var wordsAutocorrected: Int?
		var correctionsReverted: Int?
		var nwpOpportunities: Int?
		var nwpHits: Int?
		var activeTypingMs: Double?
		var committedChars: Int?
		var physicalTaps: Int?
		var peakCPUPercent: Double?
		var keyTaps: [String: Int]?
		var keyErasures: [String: Int]?
		var keyConfusions: [String: Int]?
		var backspaceTaps: Int?
		var interKeyIntervalBins: [Int]?
		var panelEvents: [String: Int]?
	}

	static let key = "kb.diag"
	static var store: UserDefaults { isTestHost ? testHostStore : KBSettings.sharedDefaults }
	private static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
		|| NSClassFromString("XCTestCase") != nil
	nonisolated(unsafe) private static let testHostStore = UserDefaults(suiteName: "kb.diag.test-host") ?? .standard
	private static let log = Logger(subsystem: KBSettings.appGroup, category: "diag")
	private static let glideCaptureQueue = DispatchQueue(label: "keyboard.glide.capture", qos: .utility)
	private static let metricsQueue = DispatchQueue(label: "keyboard.metrics", qos: .utility)
	private static let performanceLog = OSLog(subsystem: KBSettings.appGroup,
		category: .pointsOfInterest)
	private static let latencyThresholds: [Double] = [1, 2, 4, 8, 16, 32, 50, 75, 120, 250]
	static let interKeyThresholds: [Double] = [60, 90, 120, 160, 200, 260, 350, 500, 800, 1500]

	enum LatencyOperation: Sendable {
		case hostInsert, tapDecode, glidePreview, glideFinal, glideCommit, initialization
	}

	static func recordInitializationLatency(milliseconds: Double) {
		recordLatency(.initialization, milliseconds: milliseconds)
	}

	static func beginHostInsert() -> OSSignpostID {
		let id = OSSignpostID(log: performanceLog)
		os_signpost(.begin, log: performanceLog, name: "Host Insert", signpostID: id)
		return id
	}
	static func endHostInsert(_ id: OSSignpostID, milliseconds: Double) {
		os_signpost(.end, log: performanceLog, name: "Host Insert", signpostID: id)
		recordLatency(.hostInsert, milliseconds: milliseconds)
	}
	static func beginTapDecode() -> OSSignpostID {
		let id = OSSignpostID(log: performanceLog)
		os_signpost(.begin, log: performanceLog, name: "Tap Decode", signpostID: id)
		return id
	}
	static func endTapDecode(_ id: OSSignpostID, milliseconds: Double) {
		os_signpost(.end, log: performanceLog, name: "Tap Decode", signpostID: id)
		recordLatency(.tapDecode, milliseconds: milliseconds)
	}
	static func beginGlidePreview() -> OSSignpostID {
		let id = OSSignpostID(log: performanceLog)
		os_signpost(.begin, log: performanceLog, name: "Glide Preview", signpostID: id)
		return id
	}
	static func endGlidePreview(_ id: OSSignpostID, milliseconds: Double) {
		os_signpost(.end, log: performanceLog, name: "Glide Preview", signpostID: id)
		recordLatency(.glidePreview, milliseconds: milliseconds)
	}
	static func beginGlideFinal() -> OSSignpostID {
		let id = OSSignpostID(log: performanceLog)
		os_signpost(.begin, log: performanceLog, name: "Glide Final", signpostID: id)
		return id
	}
	static func endGlideFinal(_ id: OSSignpostID, milliseconds: Double) {
		os_signpost(.end, log: performanceLog, name: "Glide Final", signpostID: id)
		recordLatency(.glideFinal, milliseconds: milliseconds)
	}

	private static func recordLatency(_ operation: LatencyOperation, milliseconds: Double) {
		metricsQueue.async { Recorder.shared.recordLatency(operation, milliseconds: milliseconds) }
	}

	static func noteIntegrityEvent(_ code: String) {
		metricsQueue.async { Recorder.shared.noteIntegrityEvent(code) }
	}

	static let liveKey = "kb.diag.live"
	static func noteLiveFootprint() {
		metricsQueue.async {
			let bytes = footprintBytes()
			Recorder.shared.noteLive(bytes: bytes)
			store.set([Double(bytes) / 1_048_576, Date().timeIntervalSince1970], forKey: liveKey)
		}
	}
	static var isExtensionProcess: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

	static func liveFootprint() -> (megabytes: Double, at: Date)? {
		guard let reading = store.array(forKey: liveKey) as? [Double], reading.count == 2 else { return nil }
		return (reading[0], Date(timeIntervalSince1970: reading[1]))
	}

	static func noteSurface(_ surface: String) {
		guard isExtensionProcess else { return }
		let bytes = footprintBytes()
		metricsQueue.async { Recorder.shared.noteSurface(surface, bytes: bytes) }
		metricsQueue.asyncAfter(deadline: .now() + 1) {
			Recorder.shared.noteSurface(surface + " +1s", bytes: footprintBytes())
		}
	}

	static func finishTypingSession() {
		metricsQueue.async { Recorder.shared.finishTypingSession() }
	}

	enum PanelEvent: String, CaseIterable, Sendable {
		case open
		case search
		case tabSwitch = "switch"
		case pick
	}

	static func notePanelEvent(_ event: PanelEvent) {
		guard isExtensionProcess else { return }
		let key = KBExperiments.panelHeader.arm + "." + event.rawValue
		metricsQueue.async { Recorder.shared.notePanelEvent(key) }
	}

	static func noteKeystroke(letter: String?, intervalMs: Double?) {
		metricsQueue.async { Recorder.shared.noteKeystroke(letter: letter, intervalMs: intervalMs) }
	}

	static func noteBackspace(erasedLetter: String?) {
		metricsQueue.async { Recorder.shared.noteBackspace(erasedLetter: erasedLetter) }
	}

	static func noteKeyConfusion(typed: String, retyped: String) {
		metricsQueue.async { Recorder.shared.noteKeyConfusion(typed: typed, retyped: retyped) }
	}

	static func noteTap(atUptime uptime: Double) {
		metricsQueue.async { Recorder.shared.noteTap(atUptime: uptime) }
	}

	static func noteWordCommitted(chars: Int, autocorrected: Bool,
		predictionShown: Bool, predictionHit: Bool) {
		metricsQueue.async {
			Recorder.shared.noteWordCommitted(chars: chars, autocorrected: autocorrected,
				predictionShown: predictionShown, predictionHit: predictionHit)
		}
	}

	static func noteWordModified(revertedCorrection: Bool) {
		metricsQueue.async { Recorder.shared.noteWordModified(revertedCorrection: revertedCorrection) }
	}

	static func percentile(_ bins: [Int]?, fraction: Double) -> String? {
		percentile(bins, fraction: fraction, thresholds: latencyThresholds)
	}
	static func percentile(_ bins: [Int]?, fraction: Double, thresholds latencyThresholds: [Double]) -> String? {
		guard let bins, bins.count == latencyThresholds.count + 1 else { return nil }
		let total = bins.reduce(0, +)
		guard total > 0 else { return nil }
		let target = max(1, Int(ceil(Double(total) * min(max(fraction, 0), 1))))
		var running = 0
		for (index, count) in bins.enumerated() {
			running += count
			if running >= target {
				return index < latencyThresholds.count
					? "≤ \(Int(latencyThresholds[index])) ms"
					: "> \(Int(latencyThresholds.last ?? 250)) ms"
			}
		}
		return nil
	}

	static func read() -> Snapshot {
		guard let data = store.data(forKey: key),
			  let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
		return s
	}
	static func reset() {
		store.set(UUID().uuidString, forKey: "kb.diag.reset-generation")
		store.removeObject(forKey: key)
		store.removeObject(forKey: liveKey)
		Recorder.shared.clear()
	}

	static let defaultVerbose = false
	#if DEBUG
	static var verbose: Bool {
		get { store.object(forKey: "kb.diag.verbose") as? Bool ?? defaultVerbose }
		set { store.set(newValue, forKey: "kb.diag.verbose") }
	}
	#else
	static var verbose: Bool {
		get { false }
		set { store.removeObject(forKey: "kb.diag.verbose") }
	}
	#endif
	private static let rankLog = Logger(subsystem: KBSettings.appGroup, category: "ranking")

	static func logDecision(typed: String, best: String?, margin: Double, threshold: Double, corrected: Bool) {
		#if DEBUG
		guard verbose else { return }
		rankLog.debug("[autocorrect] typed=\"\(typed, privacy: .private(mask: .hash))\" best=\"\(best ?? "—", privacy: .private(mask: .hash))\" margin=\(String(format: "%.2f", margin), privacy: .public) gate=\(String(format: "%.1f", threshold), privacy: .public) result=\(corrected ? "correct" : "keep", privacy: .public)")
		#endif
	}

	static func logPick(mode: String, replacing: String, with picked: String,
		contextTail: String, deletes: Int, inserted: Bool) {
		#if DEBUG
		guard verbose else { return }
		rankLog.debug("[pick] mode=\(mode, privacy: .public) replace=\"\(replacing, privacy: .private(mask: .hash))\" -> \"\(picked, privacy: .private(mask: .hash))\" tail=\"\(contextTail, privacy: .private(mask: .hash))\" deletes=\(deletes, privacy: .public) inserted=\(inserted, privacy: .public)")
		#endif
	}

	static func logGlide(points: Int, pivots: Int, letters: String, margin: Double = -1) {
		#if DEBUG
		guard verbose else { return }
		let m = margin >= 0 ? String(format: " margin=%.2f", margin) : ""
		rankLog.debug("[glide] \(points, privacy: .public) pts, \(pivots, privacy: .public) pivots\(m, privacy: .public) words=\(letters, privacy: .private(mask: .hash))")
		#endif
	}

	static func logGlideCommit(ms: Double) {
		recordLatency(.glideCommit, milliseconds: ms)
		#if DEBUG
		guard verbose else { return }
		rankLog.debug("[glide-commit] lift-to-insert \(String(format: "%.2f", ms), privacy: .public) ms")
		#endif
	}

	static var glideCaptureURL: URL? {
		FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KBSettings.appGroup)?
			.appendingPathComponent("glide_capture.jsonl")
	}

	static func captureGlide(id: String, path: [(Double, Double)], times: [Double], dwell: [Character],
							 candidates: [String], committed: String?, margin: Double) {
		#if DEBUG
		guard KBSettings.glideCapture else { return }
		glideCaptureQueue.async {
			writeGlideCapture([
				"event": "gesture",
				"id": id,
				"path": path.map { [$0.0, $0.1] },
				"times": times,
				"dwell": dwell.map(String.init),
				"candidates": candidates,
				"committed": (committed as Any?) ?? NSNull(),
				"margin": margin,
			])
		}
		#endif
	}

	static func captureGlideLabel(id: String, intended: String) {
		#if DEBUG
		guard KBSettings.glideCapture, !intended.isEmpty else { return }
		glideCaptureQueue.async {
			writeGlideCapture(["event": "label", "id": id, "intended": intended])
		}
		#endif
	}

	#if DEBUG
	private static func writeGlideCapture(_ record: [String: Any]) {
		guard let url = glideCaptureURL,
			  JSONSerialization.isValidJSONObject(record),
			  var data = try? JSONSerialization.data(withJSONObject: record) else { return }
		data.append(0x0A)
		let existingSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
		if existingSize > 5_000_000 { try? FileManager.default.removeItem(at: url) }
		if let handle = try? FileHandle(forWritingTo: url) {
			defer { try? handle.close() }
			_ = try? handle.seekToEnd()
			try? handle.write(contentsOf: data)
		} else {
			try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		}
	}
	#endif

	static func footprintBytes() -> UInt64 {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
		let kr = withUnsafeMutablePointer(to: &info) { p in
			p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
			}
		}
		return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
	}

	static func availableBytes() -> UInt64 {
		let a = os_proc_available_memory()
		return a > 0 ? UInt64(a) : 0
	}

	static func cpuUsagePercent() -> Double {
		var threads: thread_act_array_t?
		var count: mach_msg_type_number_t = 0
		guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
			let threads else { return 0 }
		defer {
			for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
			vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
				vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
		}
		let infoCount = mach_msg_type_number_t(
			MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
		var total = 0.0
		for index in 0..<Int(count) {
			var info = thread_basic_info_data_t()
			var infoSize = infoCount
			let kr = withUnsafeMutablePointer(to: &info) { pointer in
				pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoSize)) {
					thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoSize)
				}
			}
			if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
				total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
			}
		}
		return total
	}

	static var recorder: Recorder { Recorder.shared }

	final class Recorder {
		static let shared = Recorder()
		private let lock = NSLock()
		private var snap: Snapshot
		private var tick = 0
		private var lastCPUSampleUptime = -Double.infinity
		private var resetGeneration = KBDiagnostics.store.string(forKey: "kb.diag.reset-generation")

		private init() { snap = KBDiagnostics.read() }

		private func synchronizeResetLocked() {
			let current = KBDiagnostics.store.string(forKey: "kb.diag.reset-generation")
			guard current != resetGeneration else { return }
			resetGeneration = current
			snap = Snapshot(); tick = 0; lastTapUptime = 0
			lastCPUSampleUptime = -Double.infinity
		}

		func clear() { lock.lock(); synchronizeResetLocked(); snap = Snapshot(); tick = 0; lastTapUptime = 0; lastCPUSampleUptime = -Double.infinity; lock.unlock() }
		func notePanelEvent(_ key: String) {
			lock.lock(); synchronizeResetLocked(); defer { lock.unlock() }
			var events = snap.panelEvents ?? [:]
			events[key, default: 0] += 1
			snap.panelEvents = events
			persistLocked()
		}
		func noteIntegrityEvent(_ code: String) {
			lock.lock(); synchronizeResetLocked(); defer { lock.unlock() }
			var events = snap.integrityEvents ?? [:]
			events[code, default: 0] += 1
			snap.integrityEvents = events
		}
		func finishTypingSession() {
			lock.lock(); synchronizeResetLocked(); defer { lock.unlock() }
			lastTapUptime = 0
			persistLocked()
		}
		func flush() { lock.lock(); synchronizeResetLocked(); persistLocked(); lock.unlock() }

		private static let clock: DateFormatter = {
			let formatter = DateFormatter()
			formatter.dateFormat = "HH:mm:ss"
			return formatter
		}()
		func noteLive(bytes: UInt64) {
			lock.lock(); synchronizeResetLocked()
			let megabytes = Double(bytes) / 1_048_576
			snap.footprintNowMB = megabytes
			if megabytes > snap.peakFootprintMB { snap.peakFootprintMB = megabytes; persistLocked() }
			lock.unlock()
		}
		func noteSurface(_ surface: String, bytes: UInt64) {
			lock.lock(); synchronizeResetLocked()
			let megabytes = Double(bytes) / 1_048_576
			snap.footprintNowMB = megabytes
			if megabytes > snap.peakFootprintMB { snap.peakFootprintMB = megabytes }
			let entry = String(format: "%@  %@  %.1f MB", Self.clock.string(from: Date()), surface, megabytes)
			snap.surfaceLog = Array(((snap.surfaceLog ?? []) + [entry]).suffix(40))
			persistLocked()
			lock.unlock()
		}

		func memoryPressure(critical: Bool) {
			lock.lock(); synchronizeResetLocked()
			if critical { snap.criticalCount += 1 } else { snap.warningCount += 1 }
			sampleLocked()
			persistLocked()
			lock.unlock()
			KBDiagnostics.log.notice("memory pressure \(critical ? "critical" : "warning")")
		}

		func recordLatency(_ operation: LatencyOperation, milliseconds: Double) {
			guard milliseconds.isFinite, milliseconds >= 0 else { return }
			lock.lock(); synchronizeResetLocked()
			switch operation {
			case .hostInsert:
				snap.hostInsertLatencyBins = bucket(snap.hostInsertLatencyBins, milliseconds)
			case .tapDecode:
				snap.tapDecodeLatencyBins = bucket(snap.tapDecodeLatencyBins, milliseconds)
			case .glidePreview:
				snap.glidePreviewLatencyBins = bucket(snap.glidePreviewLatencyBins, milliseconds)
			case .glideFinal:
				snap.glideFinalLatencyBins = bucket(snap.glideFinalLatencyBins, milliseconds)
			case .glideCommit:
				snap.glideCommitLatencyBins = bucket(snap.glideCommitLatencyBins, milliseconds)
			case .initialization:
				snap.initLatencyBins = bucket(snap.initLatencyBins, milliseconds)
			}
			tick += 1
			if tick % 32 == 0 { persistLocked() }
			lock.unlock()
		}

		private var lastTapUptime = 0.0
		private static let idleCapSeconds = 5.0

		func noteTap(atUptime uptime: Double) {
			lock.lock(); synchronizeResetLocked()
			snap.physicalTaps = (snap.physicalTaps ?? 0) + 1
			if lastTapUptime > 0 {
				let delta = uptime - lastTapUptime
				if delta > 0, delta <= Self.idleCapSeconds {
					snap.activeTypingMs = (snap.activeTypingMs ?? 0) + delta * 1_000
				}
			}
			lastTapUptime = max(lastTapUptime, uptime)
			tick += 1
			if tick % 32 == 0 { persistLocked() }
			lock.unlock()
		}

		func noteWordCommitted(chars: Int, autocorrected: Bool,
			predictionShown: Bool, predictionHit: Bool) {
			lock.lock(); synchronizeResetLocked()
			snap.wordsCommitted = (snap.wordsCommitted ?? 0) + 1
			snap.committedChars = (snap.committedChars ?? 0) + max(0, chars)
			if autocorrected { snap.wordsAutocorrected = (snap.wordsAutocorrected ?? 0) + 1 }
			if predictionShown {
				snap.nwpOpportunities = (snap.nwpOpportunities ?? 0) + 1
				if predictionHit { snap.nwpHits = (snap.nwpHits ?? 0) + 1 }
			}
			persistLocked()
			lock.unlock()
		}

		func noteWordModified(revertedCorrection: Bool) {
			lock.lock(); synchronizeResetLocked()
			snap.wordsModified = (snap.wordsModified ?? 0) + 1
			if revertedCorrection {
				snap.correctionsReverted = (snap.correctionsReverted ?? 0) + 1
			}
			persistLocked()
			lock.unlock()
		}

		func noteKeystroke(letter: String?, intervalMs: Double?) {
			lock.lock(); synchronizeResetLocked(); defer { lock.unlock() }
			if let letter { snap.keyTaps = increment(snap.keyTaps, letter) }
			if let intervalMs, intervalMs.isFinite, intervalMs > 0, intervalMs <= Self.idleCapSeconds * 1_000 {
				snap.interKeyIntervalBins = bucket(snap.interKeyIntervalBins, intervalMs, KBDiagnostics.interKeyThresholds)
			}
		}

		func noteBackspace(erasedLetter: String?) {
			lock.lock(); synchronizeResetLocked(); defer { lock.unlock() }
			snap.backspaceTaps = (snap.backspaceTaps ?? 0) + 1
			if let erasedLetter { snap.keyErasures = increment(snap.keyErasures, erasedLetter) }
		}

		func noteKeyConfusion(typed: String, retyped: String) {
			lock.lock(); synchronizeResetLocked(); defer { lock.unlock() }
			snap.keyConfusions = increment(snap.keyConfusions, typed + ">" + retyped)
		}

		private func increment(_ counts: [String: Int]?, _ key: String) -> [String: Int] {
			var counts = counts ?? [:]
			counts[key, default: 0] &+= 1
			return counts
		}

		private func bucket(_ existing: [Int]?, _ milliseconds: Double,
			_ thresholds: [Double] = KBDiagnostics.latencyThresholds) -> [Int] {
			var bins = existing ?? []
			if bins.count != thresholds.count + 1 {
				bins = [Int](repeating: 0, count: thresholds.count + 1)
			}
			let index = thresholds.firstIndex { milliseconds <= $0 }
				?? thresholds.count
			bins[index] &+= 1
			return bins
		}

		func storageFailure(operation: String) {
			lock.lock(); synchronizeResetLocked()
			snap.storageFailureCount = (snap.storageFailureCount ?? 0) + 1
			snap.lastStorageOperation = operation
			persistLocked()
			lock.unlock()
			KBDiagnostics.log.error("storage operation failed: \(operation, privacy: .public)")
		}

		func sample() {
			lock.lock(); synchronizeResetLocked()
			sampleLocked()
			tick += 1
			if tick % 16 == 0 { persistLocked() }
			lock.unlock()
		}

		private func sampleLocked() {
			let foot = Double(KBDiagnostics.footprintBytes()) / 1_048_576
			let avail = Double(KBDiagnostics.availableBytes()) / 1_048_576
			if foot > snap.peakFootprintMB { snap.peakFootprintMB = foot }
			snap.footprintNowMB = foot
			if avail > 0, snap.minAvailableMB == 0 || avail < snap.minAvailableMB {
				snap.minAvailableMB = avail
				snap.limitMB = foot + avail
			}
			let now = ProcessInfo.processInfo.systemUptime
			if now - lastCPUSampleUptime >= 1 {
				lastCPUSampleUptime = now
				let cpu = KBDiagnostics.cpuUsagePercent()
				if cpu > (snap.peakCPUPercent ?? 0) { snap.peakCPUPercent = cpu }
			}
		}
		private func persistLocked() {
			var out = snap
			out.updated = Date()
			if let data = try? JSONEncoder().encode(out) { KBDiagnostics.store.set(data, forKey: KBDiagnostics.key) }
		}
	}
}
