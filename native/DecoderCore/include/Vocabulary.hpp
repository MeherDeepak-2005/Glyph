#pragma once
#include "PackedLexicon.hpp"
#include <unordered_map>
#include <unordered_set>

namespace kb {
// Mutable words have one authority. Swift owns learning/persistence and sends
// ordered insert/bump/reset events; all trie storage and traversal live here.
class MutableTrie final {
    struct Node {
        std::vector<std::pair<std::uint8_t, std::size_t>> children;
        std::optional<std::string> word;
        std::int32_t wordID = -1;
        double logFrequency = 0;
    };
    std::vector<Node> nodes_{1};
    std::optional<std::size_t> node(std::string_view) const;
public:
    void insert(std::string_view word, std::int64_t frequency, std::int32_t id = -1);
    bool contains(std::string_view word) const;
    std::optional<std::int32_t> wordID(std::string_view word) const;
    std::optional<double> logFrequency(std::string_view word) const;
    void bump(std::string_view word);
    // As PackedLexicon::search, over these words.
    std::vector<ChannelCandidate> search(std::string_view typed, double maxCost,
        std::span<const std::optional<TouchOffset>> taps = {}) const;
};

// Borrowed only for a synchronous call. Platform locks keep mutable tries/boosts
// stable; mapped bytes are retained by the bridge's lexicon owner.
struct GenerationSnapshot {
    std::unordered_map<std::string, std::int64_t> boosts;
    std::unordered_set<std::string> blocked;
};
// The vocabulary a decode reads: the shipped dictionary (packed, or base without one),
// the platform's supplementary words (contacts, text replacements), the user's adopted
// words, and the safety-blocked words.
struct GenerationLexicon {
    const PackedLexicon* packed = nullptr;
    const MutableTrie* base = nullptr;
    const MutableTrie* supplementary = nullptr;
    const MutableTrie* personal = nullptr;
    const GenerationSnapshot* snapshot = nullptr;
    bool isBlocked(std::string_view word) const;
    bool contains(std::string_view word) const;
};
} // namespace kb
