#pragma once
#include "NeuralLanguageModel.hpp"
#include "PackedLexicon.hpp"
#include "Ranking.hpp"
#include <bit>
#include <functional>
#include <queue>
#include <unordered_map>
#include <unordered_set>

namespace kb {
inline constexpr float nssUpdateThreshold = -15, nssExtendThreshold = -12;
inline constexpr double nssExpansionThreshold = -12;
inline constexpr std::size_t nssExpansionsPerFrame = 1;

class NeuralLexicon final {
public:
    struct Node { std::uint8_t label; std::uint32_t firstChild, childCount; std::optional<std::int32_t> wordID; };
    const PackedLexicon& packed;
    std::vector<std::uint32_t> parent, terminal;
    std::vector<float> unigram, lookahead;
    std::vector<std::uint32_t> topUnigrams;
    double mass = 0;
    explicit NeuralLexicon(const PackedLexicon&);
    std::size_t nodeCount() const noexcept { return parent.size(); }
    Node node(std::size_t index) const noexcept {
        const auto* at = trie_ + PackedLexicon::trieNodeSize() * index;
        const std::uint32_t id = le32(at + 6);
        return {std::to_integer<std::uint8_t>(at[0]), le32(at + 2), std::to_integer<std::uint8_t>(at[1]),
            id == 0xffffffffu ? std::nullopt : std::optional<std::int32_t>(std::int32_t(id))};
    }
private:
    const std::byte* trie_;
    static std::uint32_t le16(const std::byte* at) noexcept {
        return std::to_integer<std::uint32_t>(at[0]) | std::to_integer<std::uint32_t>(at[1]) << 8;
    }
    static std::uint32_t le32(const std::byte* at) noexcept {
        return le16(at) | std::to_integer<std::uint32_t>(at[2]) << 16 | std::to_integer<std::uint32_t>(at[3]) << 24;
    }
};

class ArcLookahead final {
    std::vector<std::uint32_t> nodes_;
    std::vector<float> values_;
public:
    void build(const NeuralLexicon&, std::span<const std::pair<std::uint32_t, float>> wordScores, std::vector<float>& scratch);
    float at(std::uint32_t node) const;
    std::size_t size() const noexcept { return nodes_.size(); }
};

class NeuralFst final {
public:
    struct Transition { std::uint32_t next; double logProbability; };
    struct Arc { std::uint32_t word, next; float logProbability; };
    struct Stats { std::size_t updates = 0, extensions = 0, arcs = 0, states = 0; };
    struct Options { bool exact = false, unigramFloor = false; double unknownExponent = 1; };
    struct Tables {
        Tables(std::shared_ptr<const NeuralWordModel>, std::shared_ptr<const NeuralLexicon>, Options);
        std::shared_ptr<const NeuralWordModel> model;
        std::shared_ptr<const NeuralLexicon> lexicon;
        Options options;
        std::vector<std::int32_t> modelToWord, wordToModel;
        std::vector<float> outsideUnigram, outsideLookahead;
        double outsideMass = 0;
        std::vector<std::uint32_t> topOutside;
        struct Numbering {
            std::vector<std::uint64_t> bits;
            std::vector<std::uint32_t> before;
            std::uint32_t operator[](std::size_t node) const noexcept {
                const auto word = bits[node >> 6], mask = std::uint64_t(1) << (node & 63);
                return word & mask ? before[node >> 6] + std::uint32_t(std::popcount(word & (mask - 1))) : UINT32_MAX;
            }
        } vocabularyNode;
        std::vector<std::uint32_t> vocabularyParent, vocabularyTerminal;
    };
    explicit NeuralFst(std::shared_ptr<const Tables>);
    NeuralFst(std::shared_ptr<const NeuralWordModel> model, std::shared_ptr<const NeuralLexicon> lex)
        : NeuralFst(std::move(model), std::move(lex), Options{}) {}
    NeuralFst(std::shared_ptr<const NeuralWordModel> model, std::shared_ptr<const NeuralLexicon> lex, Options options)
        : NeuralFst(std::make_shared<Tables>(std::move(model), std::move(lex), options)) {}
    void update(std::span<const std::string> context, bool newWord = false);
    void resetContext();
    bool expanded(std::uint32_t state) const;
    void extend(std::uint32_t state);
    std::vector<Transition> transitions(std::uint32_t state, std::uint32_t word) const;
    double lookahead(std::uint32_t state, std::uint32_t node) const;
    double wordScore(std::uint32_t state, std::uint32_t word) const;
    std::vector<std::pair<std::uint32_t, double>> best(std::uint32_t state, std::size_t count) const;
    const NeuralLexicon& lexicon() const { return *lexicon_; }
    std::uint64_t revision() const { return revision_; }
    double typedUnknown() const;
    Stats stats() const;
    std::uint64_t modelSteps() const { return ring_->steps() + extensions_; }
private:
    struct State { std::uint32_t parent, word; std::size_t expansion = SIZE_MAX; };
    struct Expansion {
        std::size_t begin = 0, count = 0;
        float epsilon = 0;
        std::vector<float> recurrent;
        std::vector<float> distribution;
        std::vector<float> vocabularyLookahead;
        ArcLookahead lookahead;
    };
    std::shared_ptr<const Tables> tables_;
    std::shared_ptr<const NeuralWordModel> model_;
    std::shared_ptr<const NeuralLexicon> lexicon_;
    Options options_;
    std::unique_ptr<ContextRing> ring_;
    std::vector<std::int32_t> context_;
    std::vector<State> states_;
    std::vector<Arc> arcs_;
    std::vector<Expansion> expansions_;
    std::vector<float> scratch_;
    std::uint64_t revision_ = 0;
    std::size_t updates_ = 0, extensions_ = 0;
    void modify(std::uint32_t state, std::span<const float> recurrent,
                std::span<const float> features, float threshold);
};

class NeuralFstSearch final {
public:
    struct Options { double beam = 16; std::size_t width = 512; double channelWeight = kb::channelWeight; };
    explicit NeuralFstSearch(NeuralFst& graph) : graph_(graph) {}
    NeuralFstSearch(NeuralFst& graph, Options options) : graph_(graph), options_(options) {}
    std::vector<RankedRow> decode(std::string_view typed, std::span<const std::optional<TouchOffset>> taps,
                                 const std::function<bool()>& cancelled = {});
    void reset();
    const std::vector<RankedRow>& completed() const { return completeRows_; }
    bool complete(std::string_view word) const { return complete_.contains(std::string(word)); }
    std::size_t expandedLastFrame() const { return expandedLastFrame_; }
private:
    struct Token {
        std::uint32_t node = 0, state = 0;
        std::string prefix;
        double language = 0, cost = 0, upper = 0;
        std::uint8_t pending = 0;
        bool boundary = false;
    };
    struct End { Token token; std::uint32_t word, next; double language; };
    NeuralFst& graph_;
    Options options_;
    std::vector<Token> beam_;
    std::unordered_set<std::string> complete_;
    std::vector<RankedRow> completeRows_;
    std::string typed_;
    std::uint8_t lastLetter_ = 0;
    std::vector<std::optional<TouchOffset>> taps_;
    std::uint64_t revision_ = 0;
    std::size_t expandedLastFrame_ = 0;
    double bound(const Token&) const;
    std::vector<Token> prune(std::vector<Token>, bool deletions);
    std::vector<End> endings(std::span<const Token>) const;
    void advance(std::uint8_t letter, std::optional<TouchOffset> tap);
};
}
