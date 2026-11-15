import UIKit

extension KeyboardViewController {
    /// On-device personalization (learned words, touch profile): everything but secrets,
    /// codes, account and contact fields. Wider than the recorder's allowlist below, which
    /// guards text that can be exported. An undo is remembered wherever autocorrect ran.
    var permitsLearning: Bool {
        guard !isSecureField else { return false }
        switch textDocumentProxy.textContentType {
        case .password, .newPassword, .oneTimeCode, .username, .emailAddress,
             .telephoneNumber, .creditCardNumber: return false
        default: break
        }
        switch textDocumentProxy.keyboardType ?? .default {
        case .default, .asciiCapable, .twitter: return true
        default: return false
        }
    }

    /// Only general prose; do not collect credentials, codes, addresses or numeric fields.
    var permitsTypingData: Bool {
        guard !isSecureField else { return false }
        // Allowlist: an unlabelled field is prose; every labelled content type (names,
        // addresses, URLs, codes, credentials, payment) is personal data and stays out.
        guard textDocumentProxy.textContentType == nil else { return false }
        switch textDocumentProxy.keyboardType ?? .default {
        case .default, .asciiCapable, .twitter: return true
        default: return false
        }
    }

    /// A key in a general text field: per-key diagnostics, the word's trace, and a `key` event.
    /// A letter that replaces one erased from the same word also records a `key-fix`.
    func traceKey(_ ch: String, tap: KeyTap?, at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard permitsTypingData else { return }
        let interval = lastKeyUptime > 0 && time > lastKeyUptime ? (time - lastKeyUptime) * 1_000 : nil
        lastKeyUptime = time
        let letter = ch.count == 1 && ch.first.map(isWordChar) == true ? ch.lowercased() : nil
        KBDiagnostics.noteKeystroke(letter: letter.flatMap { $0.first?.isASCII == true && $0.first?.isLetter == true ? $0 : nil },
                                    intervalMs: interval)
        recordTyping("key", text: ch, tap: tap, intervalMs: interval, at: time)
        guard let letter else { typingTrace.erasedLetters.removeAll(); return }
        if typingTrace.startedAt == nil { typingTrace.startedAt = time }
        if typingTrace.keystrokes.count < 64 {
            typingTrace.keystrokes.append(.init(key: ch, dx: tap?.dx.isFinite == true ? tap?.dx : nil,
                                                dy: tap?.dy.isFinite == true ? tap?.dy : nil, intervalMs: interval))
        }
        guard !typingTrace.erasedLetters.isEmpty else { return }
        let erased = String(typingTrace.erasedLetters.removeFirst()).lowercased()
        guard erased != letter else { return }
        KBDiagnostics.noteKeyConfusion(typed: erased, retyped: letter)
        recordTyping("key-fix", text: erased, replacement: letter, evidence: "backspace-retype", tap: tap, at: time)
    }

    /// A plain Backspace that removed `erased` (nil at the start of the field).
    func traceErase(_ erased: Character?) {
        guard permitsTypingData else { return }
        lastKeyUptime = ProcessInfo.processInfo.systemUptime
        typingTrace.backspaces += 1
        var erasedLetter: String?
        if let erased, isWordChar(erased), !typingTrace.keystrokes.isEmpty {
            typingTrace.keystrokes.removeLast()
            typingTrace.erasedLetters.insert(erased, at: 0)
            if erased.isASCII, erased.isLetter { erasedLetter = erased.lowercased() }
        } else {
            typingTrace.erasedLetters.removeAll()
        }
        KBDiagnostics.noteBackspace(erasedLetter: erasedLetter)
        recordTyping("backspace", text: erased.map(String.init), evidence: erasedLetter == nil ? nil : "in-word")
    }

    /// A word was committed: its typed literal, keystrokes, time from first letter and Backspaces.
    func recordCommit(_ word: String, evidence: String) {
        guard KBTypingRecorder.enabled, permitsTypingData else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recordTyping("commit", text: word, evidence: evidence,
                     typed: currentWordBuffer.isEmpty ? nil : currentWordBuffer,
                     keystrokes: typingTrace.keystrokes.isEmpty ? nil : typingTrace.keystrokes,
                     durationMs: typingTrace.startedAt.map { (now - $0) * 1_000 },
                     backspaces: typingTrace.backspaces, at: now)
    }

    /// The keyboard's geometry, written before the first touch on a layout the recorder has
    /// not described yet: a rotation or resize, a rebuilt deck, another page, a new appearance.
    func recordLayoutIfNeeded() {
        guard KBTypingRecorder.enabled, permitsTypingData, let keyboard else { return }
        let current = RecordedLayout(revision: layoutRevision, view: ObjectIdentifier(keyboard),
                                     size: keyboard.bounds.size, page: keyboard.page)
        guard current != recordedLayout else { return }
        recordedLayout = current
        recordTyping("layout", geometry: keyboard.recordedGeometry())
    }

    /// Takes the finished gesture's samples from the view; they are recorded once its outcome is known.
    func holdGlideSamples(from keyboard: KeyboardView?, liftAt: Double) {
        guard let taken = keyboard?.takeGlideSamples() else { return }
        pendingGlideRecord = PendingGlideRecord(samples: taken.samples, startKey: taken.startKey,
                                                previews: glidePreviewCount, liftAt: liftAt)
    }

    /// One `glide` event per gesture: the full-rate path with its outcome, and for a committed
    /// word the decoder's candidates (shape costs), margin and the decode that produced it.
    func recordGlide(outcome: String, word: String? = nil) {
        guard let pending = pendingGlideRecord else { return }
        pendingGlideRecord = nil
        guard KBTypingRecorder.enabled, permitsTypingData,
              let first = pending.samples.first, let last = pending.samples.last else { return }
        func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        let kept = pending.samples.prefix(KBTypingRecorder.maxGlideSamples)
        let path = kept.map {
            [tenth(Double($0.point.x)), tenth(Double($0.point.y)), tenth(($0.time - first.time) * 1_000), tenth(Double($0.radius))]
        }
        let committed = outcome == "committed" ? engine.committedGlideEvidence() : nil
        let candidates = committed.map { evidence in
            ([evidence.winner] + evidence.alternatives).prefix(8).map {
                KBTypingRecorder.Candidate(word: String($0.prefix(64)), score: nil,
                    spatialCost: evidence.shapeCostByWord[$0].flatMap { $0.isFinite ? $0 : nil },
                    logLanguageProbability: nil, neuralLogProbability: nil, typedWordMargin: nil, source: "glide")
            }
        }
        // A lone candidate has no runner-up: its margin is a sentinel, not a measurement.
        let margin = committed.flatMap { $0.margin.isFinite && $0.margin < 1e6 ? $0.margin : nil }
        let now = ProcessInfo.processInfo.systemUptime
        recordTyping("glide", text: word, evidence: outcome,
            durationMs: (last.time - first.time) * 1_000,
            confidence: margin, candidateEvidence: candidates,
            glide: .init(path: path, startKey: pending.startKey, outcome: outcome, source: committed?.source,
                         previews: pending.previews,
                         liftToInsertMs: outcome == "committed" ? tenth((now - pending.liftAt) * 1_000) : nil,
                         truncated: pending.samples.count > kept.count ? true : nil),
            at: pending.liftAt)
    }

    func recordTyping(_ kind: String, text: String? = nil, replacement: String? = nil,
                      evidence: String? = nil, relatedWord: UInt64? = nil, candidates: [String]? = nil,
                      tap: KeyTap? = nil, touchID: String? = nil, snapshot: DecodeSnapshot? = nil,
                      intervalMs: Double? = nil, typed: String? = nil, keystrokes: [KBTypingRecorder.Keystroke]? = nil,
                      durationMs: Double? = nil, backspaces: Int? = nil,
                      point: CGPoint? = nil, radius: CGFloat? = nil, sinceMs: Double? = nil,
                      confidence: Double? = nil, candidateEvidence: [KBTypingRecorder.Candidate]? = nil,
                      glide: KBTypingRecorder.Glide? = nil, geometry: KBTypingRecorder.Layout? = nil,
                      at: Double = ProcessInfo.processInfo.systemUptime) {
        guard KBTypingRecorder.enabled, permitsTypingData else { return }
        func finite(_ value: Double?) -> Double? { value?.isFinite == true ? value : nil }
        func tenth(_ value: CGFloat?) -> Double? { value.flatMap { finite((Double($0) * 10).rounded() / 10) } }
        // Keep every individual event bounded, including paste and unusually long words.
        KBTypingRecorder.record(.init(uptime: at, process: KBTypingRecorder.processID,
            session: fieldRevision, word: wordSessionID, relatedWord: relatedWord, layout: layoutRevision, kind: kind,
            text: text.map { String($0.prefix(64)) },
            replacement: replacement.map { String($0.prefix(64)) }, evidence: evidence,
            candidates: candidates.map { $0.prefix(3).map { String($0.prefix(64)) } },
            dx: finite(tap?.dx), dy: finite(tap?.dy), x: tenth(point?.x), y: tenth(point?.y), radius: tenth(radius),
            touchID: touchID,
            intervalMs: finite(intervalMs), sinceMs: finite(sinceMs), typed: typed.map { String($0.prefix(64)) },
            keystrokes: keystrokes.map { Array($0.prefix(64)) }, durationMs: finite(durationMs), backspaces: backspaces,
            confidence: finite(confidence) ?? (snapshot?.confidence.isFinite == true ? snapshot?.confidence : nil),
            candidateEvidence: candidateEvidence ?? snapshot?.candidates.prefix(8).map {
                .init(word: String($0.word.prefix(64)), score: finite($0.score),
                      spatialCost: finite($0.spatialCost), logLanguageProbability: finite($0.logLanguageProbability),
                      neuralLogProbability: finite($0.neuralLogProbability),
                      typedWordMargin: finite($0.typedWordMargin), source: $0.source.rawValue)
            },
            glide: glide, geometry: geometry,
            model: snapshot == nil && glide == nil ? "not-decoded" : "nss", requestedModel: "nss",
            language: "english",
            build: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"))
    }
}
