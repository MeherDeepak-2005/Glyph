import Foundation

final class UserModel {
    private let storageURLOverride: URL?
    private let state = KBPersonalState()
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "keyboard.usermodel.io", qos: .utility)
    private var nativeCountsCache: KBPersonalCounts?
    private static let maxUnigrams = 4000
    private static let version = 3
    init(storageURL: URL? = nil) { storageURLOverride = storageURL }
    private func locked<T>(_ operation: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation() }
    private func ensureEpoch() {
        let epoch = KBPersonalData.currentEpoch
        if state.epoch != epoch { state.reset(epoch); nativeCountsCache = nil }
    }
    func nativeCountsSnapshot() -> KBPersonalCounts {
        locked { if let nativeCountsCache { return nativeCountsCache }; let value = state.snapshot(); nativeCountsCache = value; return value }
    }
    func uniCount(_ word: String) -> Int { locked { state.count(word) } }
    func unigramsSnapshot() -> [String: Int] { locked { state.unigrams.mapValues(\.intValue) } }
    func isKept(_ word: String) -> Bool { locked { state.kept(word) } }
    func releaseKeep(_ word: String) { locked { state.releaseKeep(word) } }
    func allowsAdoption(_ word: String, count: Int, lexicon: KBGenerationLexicon) -> Bool { locked { state.allowsAdoption(word, count: count, lexicon: lexicon) } }
    func confirmSpelling(_ word: String) { locked { ensureEpoch(); state.confirm(word) } }
    @discardableResult func pruneIfNeeded() -> Bool { locked { nativeCountsCache = nil; return state.prune() } }
    func learn(word: String) { locked { ensureEpoch(); nativeCountsCache = nil; state.learn(word) } }
    func demote(_ word: String) { locked { let priorEpoch = state.epoch; ensureEpoch(); nativeCountsCache = nil; if priorEpoch == state.epoch { state.demote(word) } } }

    private func storeURL(for epoch: UInt64) -> URL? { storageURLOverride ?? KBPersonalData.modelURL(for: epoch) }
    private var legacyStoreURL: URL? { storageURLOverride == nil ? KBPersonalData.legacyModelURL : nil }
    private struct Snapshot: Codable {
        var version: Int?; var epoch: UInt64?
        var uni: [String: Int]; var confirmed: [String: Int]?
    }
    private enum StoreError: Error { case invalidShape }
    func load() {
        let current = KBPersonalData.currentEpoch
        guard let primary = storeURL(for: current) else { KBDiagnostics.recorder.storageFailure(operation: "personal-container-unavailable"); reset(to: current); return }
        let legacy = legacyStoreURL
        let source = FileManager.default.fileExists(atPath: primary.path) ? primary : legacy.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard let source else { reset(to: current); return }
        do {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            guard data.count <= 4_000_000 else { throw StoreError.invalidShape }
            let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
            guard (decoded.version ?? 1) <= Self.version, (decoded.epoch ?? current) == current,
                  decoded.uni.count <= Self.maxUnigrams * 2 else { throw StoreError.invalidShape }
            install(decoded, current: current, rewrite: source == legacy || (decoded.version ?? 1) < Self.version)
        } catch {
            KBPersonalData.withExclusiveStoreLock { try? FileManager.default.removeItem(at: source) }
            KBDiagnostics.recorder.storageFailure(operation: "personal-model-read"); reset(to: current)
        }
    }
    private func valid(_ word: String) -> Bool { !word.isEmpty && word.count <= 64 && word.allSatisfy { $0.isLetter || $0 == "'" } }
    private func install(_ snapshot: Snapshot, current: UInt64, rewrite: Bool) {
        let counts = KBPersonalCounts(unigrams: snapshot.uni.filter { valid($0.key) && $0.value > 0 }.mapValues { NSNumber(value: $0) })
        let changed: Bool = locked {
            nativeCountsCache = nil
            state.install(counts, confirmed: (snapshot.confirmed ?? [:]).filter { valid($0.key) && $0.value > 0 }.mapValues { NSNumber(value: $0) }, epoch: current)
            return state.prune()
        }
        if changed || rewrite { save() }
    }
    func save() {
        let snapshot: Snapshot = locked { Snapshot(version: Self.version, epoch: state.epoch,
            uni: state.unigrams.mapValues(\.intValue), confirmed: state.confirmed.mapValues(\.intValue)) }
        let epoch = snapshot.epoch!
        guard let url = storeURL(for: epoch) else { KBDiagnostics.recorder.storageFailure(operation: "personal-container-unavailable"); return }
        ioQueue.async {
            let data: Data
            do { data = try JSONEncoder().encode(snapshot) } catch { KBDiagnostics.recorder.storageFailure(operation: "personal-model-encode"); return }
            KBPersonalData.withExclusiveStoreLock {
                guard KBPersonalData.currentEpoch == epoch else { return }
                do { try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                catch { KBDiagnostics.recorder.storageFailure(operation: "personal-model-write") }
            }
        }
    }
    func reset(to epoch: UInt64 = KBPersonalData.currentEpoch) { locked { state.reset(epoch); nativeCountsCache = nil } }
    func waitForPendingIO() { ioQueue.sync {} }
}
