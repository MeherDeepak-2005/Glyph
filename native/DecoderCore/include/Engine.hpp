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
    std::string word, normalized;
    std::vector<std::string> context;
    std::vector<std::optional<TouchOffset>> taps;
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
#ifdef KB_TUNING
    std::vector<RankedRow> complete, ranked;
    bool typedIsWord = false;
    double literal = 0;
#endif
};
struct EngineView {
    GenerationLexicon lexicon;
    const PersonalCounts* personal = nullptr;
    const std::unordered_map<std::string, double>* penalties = nullptr;
    std::uint64_t personalizationRevision = 0, vocabularyRevision = 0;
    double penalty(std::string_view word) const;
};
KB_TUNABLE(nssRawCommitMargin, 2.0);
KB_TUNABLE(nssCapitalizedCommitMargin, 0.0);
KB_TUNABLE(nssStartUnigramWeight, 0.25);
KB_TUNABLE(nssStartCommitMargin, 1.5);
struct EngineOptions {
    bool nssExact = true;
    bool nssUnigramFloor = true;
    double nssUnknownExponent = 1;
    bool nssTypedUnknown = true;
};
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
    mutable std::once_flag neuralTablesOnce_;
    mutable std::shared_ptr<const NeuralFst::Tables> neuralTables_;
    std::shared_ptr<const NeuralFst::Tables> neuralTables() const;
public:
    Engine(std::shared_ptr<const PackedLexicon> packed, std::shared_ptr<const NeuralWordModel> neural, EngineOptions options = {});
    std::unique_ptr<EngineSession> createSession();
    std::unique_ptr<EngineState> createState() const { return std::make_unique<EngineState>(packed_); }
    const PackedLexicon* dictionary() const { return packed_.get(); }
};
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
    void prepareNeural() { graph(); }
    void memoryPressure() { search_.reset(); graph_.reset(); identityReady_ = false; endGlide(); }
    std::uint64_t neuralSteps() const noexcept { return graph_ ? graph_->modelSteps() : 0; }
};
}
