#include "../include/Vocabulary.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace kb {
std::optional<std::size_t> MutableTrie::node(std::string_view word) const {
    std::size_t at = 0;
    for (std::uint8_t byte : word) {
        auto next = SIZE_MAX;
        for (const auto& [label, index] : nodes_[at].children)
            if (label == byte) { next = index; break; }
        if (next == SIZE_MAX) return {};
        at = next;
    }
    return at;
}
void MutableTrie::insert(std::string_view word, std::int64_t frequency, std::int32_t id) {
    std::size_t at = 0;
    for (std::uint8_t byte : word) {
        auto next = SIZE_MAX;
        for (const auto& [label, index] : nodes_[at].children)
            if (label == byte) { next = index; break; }
        if (next == SIZE_MAX) {
            next = nodes_.size(); nodes_[at].children.emplace_back(byte, next); nodes_.emplace_back();
        }
        at = next;
    }
    nodes_[at].word = std::string(word); nodes_[at].wordID = id;
    nodes_[at].logFrequency = std::log(double(std::max<std::int64_t>(frequency, 1)) + 1);
}
bool MutableTrie::contains(std::string_view word) const {
    auto at = node(word); return at && nodes_[*at].word.has_value();
}
std::optional<std::int32_t> MutableTrie::wordID(std::string_view word) const {
    auto at = node(word);
    if (!at || !nodes_[*at].word || nodes_[*at].wordID < 0) return {};
    return nodes_[*at].wordID;
}
std::optional<double> MutableTrie::logFrequency(std::string_view word) const {
    auto at = node(word); if (!at || !nodes_[*at].word) return {};
    return nodes_[*at].logFrequency;
}
void MutableTrie::bump(std::string_view word) {
    auto at = node(word); if (at && nodes_[*at].word)
        nodes_[*at].logFrequency = std::log(std::exp(nodes_[*at].logFrequency) + 1);
}
std::vector<ChannelCandidate> MutableTrie::search(std::string_view typed, double maxCost,
        std::span<const std::optional<TouchOffset>> taps) const {
    if (typed.empty()) return {};
    if (!std::isfinite(maxCost) || maxCost < 0) throw std::invalid_argument("invalid search radius");
    const double extra = maxCost / std::min(deletionCost, doubledDeletionCost);
    if (extra > 1'000'000 || typed.size() > 1'000'000) throw std::length_error("search input too large");
    const auto n = typed.size(), maxDepth = n + std::size_t(extra) + 2;
    if (maxDepth + 1 > SIZE_MAX / (n + 1)) throw std::length_error("search DP overflow");
    if (nodes_.size() == 1) return {};
    std::vector<double> dp((maxDepth + 1) * (n + 1));
    for (std::size_t i = 0; i <= n; ++i) dp[i] = double(i) * insertionCost;
    std::vector<ChannelCandidate> out;
    // As in PackedLexicon::search: a transposition can reach back to the parent row.
    auto visit = [&](auto&& self, std::size_t index, std::uint8_t letter, std::uint8_t previousLetter,
                     std::size_t depth, double penalty, double parentMin) -> void {
        if (depth > maxDepth) return;
        auto base = depth * (n + 1), previous = base - (n + 1);
        double rowMin = dp[previous] + deletionCostAt(letter, previousLetter, 0); dp[base] = rowMin;
        for (std::size_t column = 1; column <= n; ++column) {
            const auto typedLetter = std::uint8_t(typed[column - 1]);
            const auto insertion = dp[base + column - 1] +
                insertionCostAt(typedLetter, column >= 2 ? std::uint8_t(typed[column - 2]) : 0, letter);
            const auto deletion = dp[previous + column] + deletionCostAt(letter, previousLetter, typedLetter);
            auto value = std::min(insertion, std::min(deletion,
                dp[previous + column - 1] + substitutionCost(letter, std::uint8_t(typed[column - 1]),
                    taps.size() == n ? taps[column - 1] : std::nullopt, column == 1)));
            if (depth >= 2 && column >= 2 && letter == std::uint8_t(typed[column - 2]) &&
                previousLetter == std::uint8_t(typed[column - 1]))
                value = std::min(value, dp[previous - (n + 1) + column - 2] + transpositionCost);
            dp[base + column] = value; if (value < rowMin) rowMin = value;
        }
        const auto& item = nodes_[index];
        // The root penalty assumed the best case for the candidate's second letter; settle it.
        const auto typedFirst = std::uint8_t(typed.front()), typedSecond = n > 1 ? std::uint8_t(typed[1]) : std::uint8_t(0);
        const auto bound = depth == 2 ? firstLetterPenalty(n, previousLetter, typedFirst, typedSecond, letter) : penalty;
        const auto settled = depth == 1 ? std::max(penalty, firstLetterPenalty(n, letter, typedFirst, typedSecond)) : bound;
        auto cost = dp[base + n] + settled;
        if (item.word && cost <= maxCost) out.push_back({*item.word, cost, item.logFrequency});
        if (std::min(rowMin, parentMin + transpositionCost) + bound <= maxCost) for (const auto& [label, next] : item.children)
            self(self, next, label, letter, depth + 1, bound, rowMin);
    };
    for (const auto& [label, next] : nodes_[0].children)
        visit(visit, next, label, 0, 1, firstLetterPenalty(n, label, std::uint8_t(typed.front()), n > 1 ? std::uint8_t(typed[1]) : 0, std::uint8_t(typed.front())), 0.0);
    return out;
}

bool GenerationLexicon::isBlocked(std::string_view word) const {
    return snapshot && snapshot->blocked.contains(std::string(word));
}
bool GenerationLexicon::contains(std::string_view word) const {
    return (packed && packed->wordID(word)) || (base && base->contains(word)) ||
        (supplementary && supplementary->contains(word)) || (personal && personal->contains(word));
}
} // namespace kb
