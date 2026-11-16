import Foundation

nonisolated struct HostDocumentSnapshot: Equatable, Sendable {
    let documentID: UUID
    let before: String?
    let after: String?
    let selection: String?
    let hasText: Bool

    var isEmpty: Bool {
        !hasText && (before ?? "").isEmpty && (after ?? "").isEmpty
            && (selection ?? "").isEmpty
    }
    var isAvailable: Bool {
        isEmpty || before != nil || after != nil || selection != nil
    }
    func acceptsInsertion(_ text: String, result: Self) -> Bool {
        guard documentID == result.documentID, result.hasText,
            (result.selection ?? "").isEmpty,
            (after ?? "") == (result.after ?? ""),
            let observed = result.before, !observed.isEmpty else { return false }
        guard let previous = before ?? (isEmpty ? "" : nil),
            observed.count >= previous.count else { return false }
        let expected = Self.folded(previous + text)
        let actual = Self.folded(observed)
        return expected.hasSuffix(actual) || actual.hasSuffix(expected)
    }

    func matches(_ other: Self) -> Bool {
        guard documentID == other.documentID else { return false }
        if isEmpty && other.isEmpty { return true }
        guard hasText == other.hasText else { return false }
        if before == other.before && after == other.after && selection == other.selection { return true }
        return Self.folded(before) == Self.folded(other.before)
            && Self.folded(after) == Self.folded(other.after) && Self.folded(selection) == Self.folded(other.selection)
    }

    private static let smartPunctuation: Set<Unicode.Scalar> = ["\u{2019}", "\u{2018}", "\u{02BC}", "\u{201C}", "\u{201D}"]

    static func folded(_ text: String?) -> String {
        guard let text else { return "" }
        guard text.unicodeScalars.contains(where: smartPunctuation.contains) else { return text }
        return String(text.map { character -> Character in
            switch character {
            case "\u{2019}", "\u{2018}", "\u{02BC}": return "'"
            case "\u{201C}", "\u{201D}": return "\""
            default: return character
            }
        })
    }
}

nonisolated struct HostDocumentReconciler {
    enum Change: Equatable { case initial, unchanged, changed, cleared, unavailable, editing }
    private(set) var snapshot: HostDocumentSnapshot?
    private(set) var editDepth = 0
    var needsRecovery: Bool { snapshot.map { !$0.isEmpty } ?? false }

    mutating func reset() { snapshot = nil; editDepth = 0 }
    mutating func beginKeyboardEdit() { editDepth += 1 }
    mutating func endKeyboardEdit(_ state: HostDocumentSnapshot?) {
        precondition(editDepth > 0)
        editDepth -= 1
        if editDepth == 0, let state, state.isAvailable { snapshot = state }
    }
    mutating func observe(_ state: HostDocumentSnapshot?) -> Change {
        guard editDepth == 0 else { return .editing }
        guard let state else { return .unavailable }
        guard state.isAvailable else {
            if let previous = snapshot, previous.documentID != state.documentID {
                snapshot = state
                return .changed
            }
            return .unavailable
        }
        guard let previous = snapshot else { snapshot = state; return .initial }
        guard !previous.matches(state) else { return .unchanged }
        snapshot = state
        return state.isEmpty ? .cleared : .changed
    }
}

@MainActor final class HostDocumentRecoveryMonitor {
    private var timer: Timer?
    var isRunning: Bool { timer != nil }
    private let check: () -> Void
    init(check: @escaping () -> Void) { self.check = check }
    func setEnabled(_ enabled: Bool) {
        guard enabled else { stop(); return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.05
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}
