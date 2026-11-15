#if RESEARCH_BETA
import SwiftUI

/// Prompted typing: the app shows a word or sentence and the tester enters it with Glyph.
/// The keyboard records the touches as usual; the app adds `prompt-shown` / `prompt-done`
/// events naming what was asked for, so every stroke between them has a known target
/// (tools/research/build_datasets.py joins them by time). Only recorded while research is on.
struct PracticeView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case glide, tap, sentences
        var id: String { rawValue }
        var title: String {
            switch self {
            case .glide: return "Glide words"
            case .tap: return "Tap words"
            case .sentences: return "Sentences"
            }
        }
        var instruction: String {
            switch self {
            case .glide: return "Glide this word in one stroke"
            case .tap: return "Type this word key by key"
            case .sentences: return "Type this the way you normally would"
            }
        }
    }
    private struct Prompts: Decodable { let words: [String]; let sentences: [String] }
    private struct Item { let id: String; let target: String; let mode: Mode }

    private static let sessionLength = 20
    private static let prompts: Prompts = {
        guard let url = Bundle.main.url(forResource: "practice-prompts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let prompts = try? JSONDecoder().decode(Prompts.self, from: data) else { return Prompts(words: [], sentences: []) }
        return prompts
    }()

    @State private var mode = Mode.glide
    @State private var queue: [Item] = []
    @State private var index = 0
    @State private var text = ""
    @State private var finished = false
    @State private var recording = KBTypingRecorder.enabled
    @FocusState private var focused: Bool

    private var current: Item? { queue.indices.contains(index) ? queue[index] : nil }

    var body: some View {
        VStack(spacing: 20) {
            Picker("Practice", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if !recording {
                ContentUnavailableView("Research is off", systemImage: "record.circle",
                    description: Text("Practice is only recorded while typing research is on. Turn it on from the previous screen."))
            } else if finished {
                ContentUnavailableView {
                    Label("Done — thank you", systemImage: "checkmark.circle")
                } description: {
                    Text("This session is being uploaded.")
                } actions: {
                    Button("Another round") { start() }.buttonStyle(.borderedProminent)
                }
            } else if let current {
                Text(mode.instruction).font(.subheadline).foregroundStyle(.secondary)
                Text(current.target)
                    .font(.system(mode == .sentences ? .title2 : .largeTitle, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier("practice.target")
                TextField("Type here with Glyph", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .accessibilityIdentifier("practice.field")
                    .onChange(of: text) { _, entered in
                        // The word (or sentence) and the space or full stop after it: move on by itself.
                        if matches(entered, current.target), entered.last.map({ !$0.isLetter && !$0.isNumber }) == true { advance() }
                    }
                HStack {
                    Button("Skip") { advance() }
                    Spacer()
                    Text("\(index + 1) of \(queue.count)").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Next") { advance() }.buttonStyle(.borderedProminent)
                }
                Text("Use the globe key to switch to Glyph. If the word comes out wrong, fix it the way you usually would — that is useful too.")
                    .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recording = KBTypingRecorder.enabled; start() }
        .onChange(of: mode) { _, _ in start() }
        .onDisappear { if let current, !finished { note("prompt-done", current, result: text, evidence: "left") } }
    }

    private func matches(_ entered: String, _ target: String) -> Bool {
        func folded(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "’", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return folded(entered) == folded(target)
    }

    private func start() {
        guard recording else { return }
        if let current, !finished { note("prompt-done", current, result: text, evidence: "left") }
        let pool = mode == .sentences ? Self.prompts.sentences : Self.prompts.words
        let round = UUID().uuidString.prefix(8)
        queue = pool.shuffled().prefix(mode == .sentences ? 8 : Self.sessionLength).enumerated().map {
            Item(id: "\(round)-\($0.offset)", target: $0.element, mode: mode)
        }
        index = 0
        text = ""
        finished = queue.isEmpty
        focused = true
        if let current { note("prompt-shown", current) }
    }

    private func advance() {
        guard let current else { return }
        note("prompt-done", current, result: text, evidence: matches(text, current.target) ? "matched" : "skipped")
        text = ""
        index += 1
        if let next = self.current {
            note("prompt-shown", next)
        } else {
            finished = true
            focused = false
            Task.detached(priority: .utility) { await ResearchUploader.uploadPending() }
        }
    }

    private func note(_ kind: String, _ item: Item, result: String? = nil, evidence: String? = nil) {
        KBTypingRecorder.record(.init(uptime: ProcessInfo.processInfo.systemUptime, process: KBTypingRecorder.processID,
            session: 0, word: 0, layout: 0, kind: kind, evidence: evidence,
            prompt: .init(id: item.id, target: item.target, mode: item.mode.rawValue, result: result.map { String($0.prefix(512)) }),
            model: "none", language: "english",
            build: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"))
    }
}
#endif
