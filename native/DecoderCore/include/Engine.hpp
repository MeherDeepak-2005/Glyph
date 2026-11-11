#pragma once
#include "PlatformContract.hpp"
#include "NeuralLanguageModel.hpp"
#include "NeuralFst.hpp"
#include "Glide.hpp"
#include "Personalization.hpp"
#include "TextOrder.hpp"
#include <atomic>
#include <mutex>
#include <stdexcept>

namespace kb {
// Cancellation is independently thread safe. Session operations use one host lane.
class CancellationToken final {
    std::atomic<bool> cancelled_{false};
public:
    void cancel() noexcept { cancelled_.store(true, std::memory_order_relaxed); }
    bool cancelled() const noexcept { return cancelled_.load(std::memory_order_relaxed); }
};
enum class EngineStatus { ok, cancelled };
enum class CandidateSource { typed, fuzzyLexicon, splitCorrection };
struct DecodeInput {
    RequestIdentity identity;
    // As typed, and normalized (lowercased) for the dictionary.
    std::string word, normalized;
    std::vector<std::string> context;
    std::vector<std::optional<TouchOffset>> taps;
    // The user undid a correction of this word in this session: it stays as typed.
    bool kept = false;
};
struct CandidateEvidence {
    RankedRow ranked;
    CandidateSource source;
    double typedMargin;
};
struct DecodeOutput {
    RequestIdentity identity;
    EngineStatus status = EngineStatus::ok;
    std::vector<std::string> suggestions;
    std::vector<CandidateEvidence> candidates;
    CorrectionResult correction;
};
// Views are borrowed synchronously; adapter snapshot owners must outlive the call.
// They point directly into native COW lexicons/counts, never platform callbacks.
// `penalties` holds only residual, non-blocking safety penalties (in-dictionary demote
// terms). Blocked words are excluded from the search and never reach ranking.
struct EngineView {
    GenerationLexicon lexicon;
    const PersonalCounts* personal = nullptr;
    const std::unordered_map<std::string, double>* penalties = nullptr;
    std::uint64_t personalizationRevision = 0, vocabularyRevision = 0;
    double penalty(std::string_view word) const;
};
// Decoding commits the best completed word for a typed non-word when it scores above the
// typed text minus this margin (0: only when it outscores it); a typed dictionary word needs a
// better score. Larger commits more of the corrections the strip already shows, and changes
// more unknown words (names, rare words).
KB_TUNABLE(nssRawCommitMargin, 0.0);
// The neural search space (NeuralFst, Zhang et al. EMNLP Industry 2024) over the dictionary.
struct EngineOptions {
    // NeuralFst::Options::exact: exact vocabulary scores and <unk> shared outside the
    // vocabulary. false reproduces the published graph.
    bool nssExact = true;
    // NeuralFst::Options::unigramFloor (with nssExact): vocabulary words keep the
    // published unigram fallback path as a floor.
    bool nssUnigramFloor = true;
    // NeuralFst::Options::unknownExponent (with nssExact).
    double nssUnknownExponent = 1;
    // nssExact: typed text outside the lexicon is scored by NeuralFst::typedUnknown (the
    // model's P(<unk>) in context) instead of UnigramModel's context-free half count.
    bool nssTypedUnknown = false;
};
// The dictionary's context-free unigram distribution, P(w) = (frequency + 1) / (sum of
// frequency + 1 over the dictionary); text outside it counts half. It scores what the NSS
// graph cannot: typed text outside the lexicon and the words the user added.
class UnigramModel final {
    const PackedLexicon& packed_;
    double total_;
public:
    explicit UnigramModel(const PackedLexicon& packed);
    double logProbability(std::string_view word) const;
};
enum class UserEventKind { learn, confirmSpelling, correctionStood, wordReplaced, reset, supplementary };
struct UserEvent {
    UserEventKind kind;
    std::string word;
    std::uint64_t epoch = 0;
    bool learnable = true;
};
// The platform-neutral host state: personal counts, the adopted and supplementary words and
// the safety penalties. The iOS adapter keeps its own equivalents; harnesses use this one.
class EngineState final {
    std::shared_ptr<const PackedLexicon> packed_;
    Personalization personal_;
    VocabularyState vocabulary_;
    MutableTrie supplementary_, adopted_;
    std::unordered_map<std::string,double> penalties_, residual_;
    std::uint64_t vocabularyRevision_ = 0;
    void note(const std::string& word, std::int64_t count);
public:
    explicit EngineState(std::shared_ptr<const PackedLexicon> packed) : packed_(std::move(packed)) {}
    EngineView view() const;
    void setSafety(std::unordered_map<std::string,double> penalties);
    void apply(const UserEvent&);
    void importPersonalization(PersonalizationSnapshot);
    PersonalizationSnapshot exportPersonalization() const { return personal_.exportSnapshot(); }
    std::vector<std::string> dynamicGlideWords(std::size_t limit = 128) const { return vocabulary_.dynamicWords(limit); }
    bool kept(std::string_view word) const { return personal_.kept(word); }
};
class EngineSession;
class Engine final : public std::enable_shared_from_this<Engine> {
    friend class EngineSession;
    std::shared_ptr<const PackedLexicon> packed_;
    std::shared_ptr<const NeuralWordModel> neural_;
    EngineOptions options_;
    std::shared_ptr<const NeuralLexicon> neuralLexicon_;
    UnigramModel unigram_;
    // The NSS graph tables every session's graph shares, built once on first use.
    mutable std::once_flag neuralTablesOnce_;
    mutable std::shared_ptr<const NeuralFst::Tables> neuralTables_;
    std::shared_ptr<const NeuralFst::Tables> neuralTables() const;
public:
    // Throws std::invalid_argument without a dictionary or a model.
    Engine(std::shared_ptr<const PackedLexicon> packed, std::shared_ptr<const NeuralWordModel> neural, EngineOptions options = {});
    std::unique_ptr<EngineSession> createSession();
    std::unique_ptr<EngineState> createState() const { return std::make_unique<EngineState>(packed_); }
    const PackedLexicon* dictionary() const { return packed_.get(); }
};
// One typing lane (or one Glide gesture): the NSS graph for the current context and the
// joint search (C o L o G) for the current word, retained across keystrokes.
class EngineSession final {
    std::shared_ptr<Engine> engine_;
    std::unique_ptr<NeuralFst> graph_;
    std::unique_ptr<NeuralFstSearch> search_;
    std::vector<std::string> glideContext_;
    RequestIdentity identity_;
    std::string typed_;
    bool identityReady_ = false;
    NeuralFst& graph();
public:
    explicit EngineSession(std::shared_ptr<Engine> engine) : engine_(std::move(engine)) {}
    DecodeOutput decode(const DecodeInput&, const EngineView&, const CancellationToken* = nullptr);
    void beginGlide(std::vector<std::string> context);
    std::vector<RankedRow> updateGlide(std::span<const Point> path, const GlideLayout&, const EngineView&,
        std::span<const std::string> dynamicWords, const CancellationToken* = nullptr);
    void endGlide() { glideContext_.clear(); }
    // Builds the NSS graph ahead of the first decode, which otherwise pays for it.
    void prepareNeural() { graph(); }
    void memoryPressure() { search_.reset(); graph_.reset(); identityReady_ = false; endGlide(); }
    // Model steps the session's NSS context ring has run.
    std::uint64_t neuralSteps() const noexcept { return graph_ ? graph_->modelSteps() : 0; }
};
} // namespace kb
