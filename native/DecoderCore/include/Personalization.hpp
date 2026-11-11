#pragma once
#include "Vocabulary.hpp"
#include <cmath>
#include <unordered_set>
namespace kb {
using CountRows = std::vector<std::pair<std::string, std::int64_t>>;
// How often the user committed each word (unigram counts; no word context is kept).
struct PersonalCounts {
    std::unordered_map<std::string, std::int64_t> unigram;
    std::int64_t uni(std::string_view word) const;
};
// A word the user committed at least three times gains weight x log(count - 2) nats:
// personal history is a bounded tie-breaker, never a near-certain prediction.
inline double personalLanguageBoost(double count, double weight) {
    return count >= 3 ? weight * std::log1p(count - 3 + 1) : 0;
}
// The boost a dictionary word gets from the user's own counts (log space).
double personalBoost(std::string_view word, const PersonalCounts&, const GenerationLexicon&);
// Anything learned must survive persistence, so writes enforce the limits loaders check.
inline constexpr std::size_t maxPersonalWordBytes = 1024;
struct PersonalizationSnapshot {
    PersonalCounts counts;
    std::unordered_map<std::string, std::int64_t> confirmed;
    std::uint64_t epoch = 0;
};
// Hosts serialize access and persist exported snapshots. Searchers retain immutable
// COW count snapshots so learning/reset cannot invalidate an active decode.
class Personalization final {
    std::shared_ptr<PersonalCounts> counts_ = std::make_shared<PersonalCounts>();
    std::unordered_map<std::string, std::int64_t> confirmed_;
    std::unordered_set<std::string> kept_;
    std::uint64_t epoch_ = 0, revision_ = 0;
    void mutate();
public:
    std::shared_ptr<const PersonalCounts> counts() const { return counts_; }
    const auto& confirmed() const { return confirmed_; }
    std::uint64_t revision() const { return revision_; }
    std::uint64_t epoch() const { return epoch_; }
    void install(PersonalizationSnapshot snapshot);
    PersonalizationSnapshot exportSnapshot() const { return {*counts_, confirmed_, epoch_}; }
    void reset(std::uint64_t epoch);
    void learn(std::string word);
    void demote(std::string_view word);
    void confirm(std::string word);
    void releaseKeep(std::string_view word) { kept_.erase(std::string(word)); }
    bool kept(std::string_view word) const { return kept_.contains(std::string(word)); }
    std::int64_t confirmations(std::string_view word) const;
    bool prune();
    // An unknown spelling enters the vocabulary once the user typed it `threshold` times and
    // confirmed it (undid its correction), or typed it twice as often; never a one-edit
    // neighbour of a dictionary word (a repeated typo).
    bool allowsAdoption(std::string_view word, std::int64_t count, const GenerationLexicon&, std::int64_t threshold = 8) const;
};
}
namespace kb {
class VocabularyState final {
    std::shared_ptr<GenerationSnapshot> generation_ = std::make_shared<GenerationSnapshot>();
    std::unordered_map<std::string,std::int64_t> supplementaryGlide_, personalGlide_;
    void mutate();
public:
    std::shared_ptr<const GenerationSnapshot> snapshot() const { return generation_; }
    void setBlocked(std::unordered_set<std::string> words);
    void supplementary(std::string word, std::int64_t frequency, bool glideSpelling);
    bool noteUse(const GenerationLexicon&, MutableTrie& personal, std::string word, std::int64_t count,
        bool allowAdoption, std::int64_t adoptAfter, bool glideSpelling);
    std::vector<std::string> dynamicWords(std::size_t limit) const;
    void resetPersonalization();
};
}
