import UIKit

extension KeyboardViewController {
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

    var permitsTypingData: Bool {
        guard !isSecureField else { return false }
        guard textDocumentProxy.textContentType == nil else { return false }
        switch textDocumentProxy.keyboardType ?? .default {
        case .default, .asciiCapable, .twitter: return true
        default: return false
        }
    }

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

    func recordCommit(_ word: String, evidence: String) {
        guard KBTypingRecorder.enabled, permitsTypingData else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recordTyping("commit", text: word, evidence: evidence,
                     typed: currentWordBuffer.isEmpty ? nil : currentWordBuffer,
                     keystrokes: typingTrace.keystrokes.isEmpty ? nil : typingTrace.keystrokes,
                     durationMs: typingTrace.startedAt.map { (now - $0) * 1_000 },
                     backspaces: typingTrace.backspaces, at: now)
    }

    func recordLayoutIfNeeded() {
        guard KBTypingRecorder.enabled, permitsTypingData, let keyboard else { return }
        let current = RecordedLayout(revision: layoutRevision, view: ObjectIdentifier(keyboard),
                                     size: keyboard.bounds.size, page: keyboard.page)
        guard current != recordedLayout else { return }
        recordedLayout = current
        recordTyping("layout", geometry: keyboard.recordedGeometry())
    }

    func holdGlideSamples(from keyboard: KeyboardView?, liftAt: Double) {
        guard let taken = keyboard?.takeGlideSamples() else { return }
        pendingGlideRecord = PendingGlideRecord(samples: taken.samples, startKey: taken.startKey,
                                                previews: glidePreviewCount, liftAt: liftAt)
    }

    func recordGlide(outcome: String, word: String? = nil, displayedWord: String? = nil) {
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
        if outcome == "committed", let displayedWord {
            trackRecordedWord(displayedWord, trailing: " ", kind: "glide", enteredAt: pending.liftAt)
        }
    }

    func trackRecordedWord(_ word: String, trailing: String, kind: String,
                           enteredAt: Double = ProcessInfo.processInfo.systemUptime) {
        guard KBTypingRecorder.enabled, permitsTypingData, !word.isEmpty, word.count <= 64 else { return }
        if recordedWordFollowUps.count == 4 { recordedWordFollowUps.removeFirst() }
        recordedWordFollowUps.append(.init(kind: kind, wordID: wordSessionID, enteredAt: enteredAt,
                                           length: word.count, tail: word + trailing))
    }

    func recordCorrectionAccepted(_ correction: Correction) {
        guard correction.fromAutocorrect, let word = correction.recordedWordSessionID,
              word != recordedAcceptance else { return }
        recordedAcceptance = word
        recordTyping("correction-accepted", text: correction.original, replacement: correction.corrected,
                     evidence: "user-continued", relatedWord: word,
                     sinceMs: (ProcessInfo.processInfo.systemUptime - correction.appliedAt) * 1_000)
    }

    func extendRecordedWords(with text: String) {
        guard !recordedWordFollowUps.isEmpty, !text.isEmpty else { return }
        let length = text.prefix(97).count
        let hasNewTyping = length <= 96 && text.contains(where: isWordChar)
        recordedWordFollowUps.removeAll { $0.tail.count + length > 96 }
        for index in recordedWordFollowUps.indices {
            recordedWordFollowUps[index].tail += text
            if hasNewTyping && !recordedWordFollowUps[index].continued {
                recordedWordFollowUps[index].hasNewTyping = true
            }
        }
    }

    func shortenRecordedWords(by count: Int, backspace: Bool = false) {
        guard !recordedWordFollowUps.isEmpty, count > 0 else { return }
        recordedWordFollowUps.removeAll { glide in
            count > glide.tail.count || (!backspace && glide.tail.count - count < glide.length)
        }
        for index in recordedWordFollowUps.indices {
            recordedWordFollowUps[index].tail.removeLast(count)
            if backspace && recordedWordFollowUps[index].tail.count < recordedWordFollowUps[index].length {
                recordedWordFollowUps[index].backspaced = true
            }
        }
    }

    func finishRecordedWordEdit(before: HostDocumentSnapshot?, after: HostDocumentSnapshot?) {
        guard !recordedWordFollowUps.isEmpty else { return }
        guard KBTypingRecorder.enabled, permitsTypingData, let before, let after,
              before.documentID == after.documentID, (before.selection ?? "").isEmpty,
              (after.selection ?? "").isEmpty, (before.after ?? "") == (after.after ?? ""),
              let context = after.before ?? (after.isEmpty ? "" : nil) else {
            recordedWordFollowUps.removeAll()
            return
        }
        let tail = HostDocumentSnapshot.folded(String(context.suffix(96)))
        for index in recordedWordFollowUps.indices.reversed() {
            let glide = recordedWordFollowUps[index]
            guard tail.hasSuffix(HostDocumentSnapshot.folded(glide.tail)) else {
                recordedWordFollowUps.remove(at: index)
                continue
            }
            if glide.backspaced || glide.hasNewTyping {
                guard !before.matches(after) else {
                    recordedWordFollowUps.remove(at: index)
                    continue
                }
                let now = ProcessInfo.processInfo.systemUptime
                let prefix = glide.kind == "glide" ? "glide" : "word"
                recordTyping(prefix + (glide.backspaced ? "-backspaced" : "-continued"),
                             evidence: glide.kind == "glide" ? nil : glide.kind,
                             relatedWord: glide.wordID, sinceMs: (now - glide.enteredAt) * 1_000, at: now)
                if glide.backspaced {
                    recordedWordFollowUps.remove(at: index)
                } else {
                    recordedWordFollowUps[index].continued = true
                    recordedWordFollowUps[index].hasNewTyping = false
                }
            }
        }
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
        let clippedCandidates: [String]? = candidates.map { $0.prefix(3).map { String($0.prefix(64)) } }
        let clippedKeystrokes: [KBTypingRecorder.Keystroke]? = keystrokes.map { Array($0.prefix(64)) }
        let snapshotConfidence: Double? = snapshot.flatMap { $0.confidence.isFinite ? $0.confidence : nil }
        let snapshotEvidence: [KBTypingRecorder.Candidate]? = snapshot.map { snapshot in
            snapshot.candidates.prefix(8).map { candidate -> KBTypingRecorder.Candidate in
                KBTypingRecorder.Candidate(word: String(candidate.word.prefix(64)), score: finite(candidate.score),
                      spatialCost: finite(candidate.spatialCost),
                      logLanguageProbability: finite(candidate.logLanguageProbability),
                      neuralLogProbability: finite(candidate.neuralLogProbability),
                      typedWordMargin: finite(candidate.typedWordMargin), source: candidate.source.rawValue)
            }
        }
        let model: String = snapshot == nil && glide == nil ? "not-decoded" : "nss"
        let build: String = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
        KBTypingRecorder.record(KBTypingRecorder.Event(uptime: at, process: KBTypingRecorder.processID,
            session: fieldRevision, word: wordSessionID, relatedWord: relatedWord, layout: layoutRevision, kind: kind,
            text: text.map { String($0.prefix(64)) },
            replacement: replacement.map { String($0.prefix(64)) }, evidence: evidence,
            candidates: clippedCandidates,
            dx: finite(tap?.dx), dy: finite(tap?.dy), x: tenth(point?.x), y: tenth(point?.y), radius: tenth(radius),
            touchID: touchID,
            intervalMs: finite(intervalMs), sinceMs: finite(sinceMs), typed: typed.map { String($0.prefix(64)) },
            keystrokes: clippedKeystrokes, durationMs: finite(durationMs), backspaces: backspaces,
            confidence: finite(confidence) ?? snapshotConfidence,
            candidateEvidence: candidateEvidence ?? snapshotEvidence,
            glide: glide, geometry: geometry,
            model: model, requestedModel: "nss",
            language: "english",
            build: build))
    }
}
