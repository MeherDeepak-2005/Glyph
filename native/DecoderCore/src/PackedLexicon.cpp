#include "../include/PackedLexicon.hpp"
#include "../include/DictionaryDigest.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <utility>
#include <stdexcept>

namespace kb {
namespace {
constexpr std::uint32_t magic = 0x4B424C4D, none = 0xffffffff;
void require(bool condition, const char* reason) {
    if (!condition) throw std::invalid_argument(reason);
}
}
void PackedLexicon::installBlocked(std::span<const std::string> terms) const {
    std::call_once(blockedOnce_, [&] {
        std::vector<std::uint64_t> bits((std::size_t(words_) + 63) / 64);
        std::size_t count = 0;
        for (const auto& term : terms) if (auto id = wordID(term)) {
            auto& slot = bits[std::uint32_t(*id) >> 6]; auto mask = std::uint64_t(1) << (std::uint32_t(*id) & 63);
            if (!(slot & mask)) { slot |= mask; ++count; }
        }
        blocked_ = std::move(bits); blockedCount_ = count;
    });
}
PackedLexicon::TrieNodeRecord PackedLexicon::trieRecord(std::size_t node) const {
    if (node >= nodes_) throw std::out_of_range("invalid trie node");
    auto offset = trie_ + nodeSize_ * node;
    auto id = u32(offset + 6);
    return {std::to_integer<std::uint8_t>(bytes_[offset]), u32(offset + 2),
        std::to_integer<std::uint8_t>(bytes_[offset + 1]), u32(offset + 10),
        id == none ? std::nullopt : std::optional<std::int32_t>(id)};
}
std::optional<std::size_t> PackedLexicon::trieNode(std::string_view prefix) const {
    if (!nodes_) return {};
    std::size_t at = 0;
    for (std::uint8_t letter : prefix) {
        auto offset = trie_ + nodeSize_ * at;
        auto first = u32(offset + 2);
        auto count = std::to_integer<std::uint8_t>(bytes_[offset + 1]);
        std::size_t next = SIZE_MAX;
        for (std::size_t i = first; i < std::size_t(first) + count; ++i)
            if (std::to_integer<std::uint8_t>(bytes_[trie_ + nodeSize_ * i]) == letter) { next = i; break; }
        if (next == SIZE_MAX) return {};
        at = next;
    }
    return at;
}
std::optional<std::int32_t> PackedLexicon::wordID(std::string_view spelling) const {
    auto at = trieNode(spelling); if (!at) return {};
    auto id = u32(trie_ + nodeSize_ * *at + 6);
    if (id == none) return {};
    return static_cast<std::int32_t>(id);
}
std::uint32_t PackedLexicon::u32(std::size_t offset) const {
    require(offset <= bytes_.size() && bytes_.size() - offset >= 4, "truncated UInt32");
    return std::to_integer<std::uint32_t>(bytes_[offset]) |
           (std::to_integer<std::uint32_t>(bytes_[offset + 1]) << 8) |
           (std::to_integer<std::uint32_t>(bytes_[offset + 2]) << 16) |
           (std::to_integer<std::uint32_t>(bytes_[offset + 3]) << 24);
}
PackedLexicon::PackedLexicon(std::span<const std::byte> bytes) : bytes_(bytes) {
    require(bytes.size() >= headerSize_, "truncated header");
    require(u32(0) == magic, "invalid KBLM magic");
    require(u32(4) == formatVersion, "unsupported KBLM version");
    words_ = u32(8); nodes_ = u32(12);
    require(words_ <= static_cast<std::uint32_t>(INT32_MAX), "word IDs exceed Int32");
    // Add each section only after checked multiplication/subtraction. Corrupt counts
    // must not wrap offsets, even on a platform with a smaller size_t.
    std::size_t cursor = headerSize_;
    auto section = [&](std::size_t width, std::size_t count) {
        require(count <= (bytes.size() - cursor) / width, "section exceeds backing");
        auto start = cursor; cursor += width * count; return start;
    };
    frequencies_ = section(4, words_);
    offsets_ = section(4, std::size_t(words_) + 1);
    trie_ = section(nodeSize_, nodes_);
    blob_ = cursor;
    validate();
}
void PackedLexicon::validate() {
    std::uint32_t previous = 0;
    for (std::size_t i = 0; i <= words_; ++i) {
        auto end = u32(offsets_ + 4 * i);
        require(end >= previous && end <= bytes_.size() - blob_, "invalid word offsets");
        previous = end;
    }
    for (std::size_t i = 0; i < nodes_; ++i) {
        auto base = trie_ + nodeSize_ * i;
        auto count = std::to_integer<unsigned>(bytes_[base + 1]);
        auto first = u32(base + 2), id = u32(base + 6);
        require(first <= nodes_ && count <= nodes_ - first, "invalid trie child range");
        require(count == 0 || first > i, "trie children must follow parent");
        require(id == none || id < words_, "invalid trie terminal ID");
    }
}
std::uint32_t PackedLexicon::frequency(std::uint32_t id) const {
    if (id >= words_) throw std::out_of_range("word ID");
    return u32(frequencies_ + 4 * id);
}
std::string_view PackedLexicon::word(std::uint32_t id) const {
    if (id >= words_) throw std::out_of_range("word ID");
    auto start = u32(offsets_ + 4 * id), end = u32(offsets_ + 4 * (std::size_t(id) + 1));
    return {reinterpret_cast<const char*>(bytes_.data() + blob_ + start), end - start};
}
std::vector<ChannelCandidate> PackedLexicon::search(std::string_view typed, double maxCost,
        std::span<const std::optional<TouchOffset>> taps, const std::function<bool()>& shouldCancel) const {
    if (!nodes_ || typed.empty()) return {};
    if (!std::isfinite(maxCost) || maxCost < 0) throw std::invalid_argument("invalid search radius");
    const auto extra = maxCost / std::min(deletionCost, doubledDeletionCost);
    if (extra >= double(std::numeric_limits<std::size_t>::max() / 2))
        throw std::length_error("search depth overflow");
    const auto allowance = static_cast<std::size_t>(extra) + 2;
    if (typed.size() > SIZE_MAX - allowance - 1) throw std::length_error("search depth overflow");
    const auto n = typed.size(), maxDepth = n + allowance;
    if (maxDepth + 1 > SIZE_MAX / (n + 1)) throw std::length_error("search DP overflow");
    std::vector<double> dp((maxDepth + 1) * (n + 1));
    for (std::size_t i = 0; i <= n; ++i) dp[i] = double(i) * insertionCost;
    // Each candidate label sees the same substitution cost at a typed column.
    // Compute geometry once per column/label rather than once per visited cell.
    if (n > SIZE_MAX / 256) throw std::length_error("search substitution table overflow");
    std::vector<std::array<double, 256>> substitutions(n);
    std::array<bool, 256> substitutionReady{};
    std::vector<std::pair<std::uint32_t, double>> hits;
    std::size_t visits = 0; bool cancelled = false;
    auto byteAt = [&](std::size_t node, std::size_t offset) {
        return std::to_integer<std::uint8_t>(bytes_[trie_ + nodeSize_ * node + offset]);
    };
    const auto typedFirst = std::uint8_t(typed.front()), typedSecondLetter = n > 1 ? std::uint8_t(typed[1]) : std::uint8_t(0);
    // A dropped first letter (bove -> above) gets no first-letter discount: admitting that
    // shape would lower the root bound of every first letter and open most of the trie.
    auto penaltyOf = [&](std::uint8_t candidateFirst, std::uint8_t candidateSecond) {
        if (candidateSecond == typedFirst && !(typedSecondLetter && candidateFirst == typedSecondLetter))
            candidateSecond = 0;
        return firstLetterPenalty(n, candidateFirst, typedFirst, typedSecondLetter, candidateSecond);
    };
    // parentMin is the previous DP row's minimum: a transposition reaches back to it,
    // so a branch may only be pruned when min(rowMin, parentMin + transposition) is over budget.
    auto visit = [&](auto&& self, std::size_t node, std::uint8_t letter, std::uint8_t previousLetter,
                     std::size_t depth, double firstPenalty, double parentMin) -> void {
        if (cancelled || depth > maxDepth) return;
        const double rootPenalty = firstPenalty;   // best case below the root; exact from depth 2
        ++visits;
        if ((visits & 127) == 0 && shouldCancel && shouldCancel()) { cancelled = true; return; }
        if (!substitutionReady[letter]) {
            for (std::size_t column = 0; column < n; ++column)
                substitutions[column][letter] = substitutionCost(letter, std::uint8_t(typed[column]),
                    taps.size() == n ? taps[column] : std::nullopt, column == 0);
            substitutionReady[letter] = true;
        }
        const auto base = depth * (n + 1), previous = base - (n + 1);
        double rowMin = dp[previous] + deletionCostAt(letter, previousLetter, 0); dp[base] = rowMin;
        for (std::size_t column = 1; column <= n; ++column) {
            const auto typedLetter = std::uint8_t(typed[column - 1]);
            const double insertion = dp[base + column - 1] +
                insertionCostAt(typedLetter, column >= 2 ? std::uint8_t(typed[column - 2]) : 0, letter);
            const double deletion = dp[previous + column] + deletionCostAt(letter, previousLetter, typedLetter);
            double value = std::min(insertion, std::min(deletion,
                dp[previous + column - 1] + substitutions[column - 1][letter]));
            if (depth >= 2 && column >= 2 && letter == std::uint8_t(typed[column - 2]) &&
                previousLetter == std::uint8_t(typed[column - 1]))
                value = std::min(value, dp[previous - (n + 1) + column - 2] + transpositionCost);
            dp[base + column] = value; if (value < rowMin) rowMin = value;
        }
        auto offset = trie_ + nodeSize_ * node;
        const std::uint32_t id = u32(offset + 6);
        // The root penalty assumed the best case for the candidate's second letter; settle it.
        if (depth == 1) firstPenalty = std::max(firstPenalty, firstLetterPenalty(n, letter, typedFirst, typedSecondLetter));
        if (depth == 2) firstPenalty = penaltyOf(previousLetter, letter);
        const double finalCost = dp[base + n] + firstPenalty;
        if (id != none && !blocked(id) && finalCost <= maxCost) hits.emplace_back(id, finalCost);
        const double bound = depth == 1 ? rootPenalty : firstPenalty;
        if (std::min(rowMin, parentMin + transpositionCost) + bound <= maxCost) {
            const auto first = u32(offset + 2); const auto count = byteAt(node, 1);
            for (std::size_t child = first; child < std::size_t(first) + count; ++child)
                self(self, child, byteAt(child, 0), letter, depth + 1, bound, rowMin);
        }
    };
    const auto first = u32(trie_ + 2); const auto count = byteAt(0, 1);
    for (std::size_t node = first; node < std::size_t(first) + count; ++node) {
        const auto letter = byteAt(node, 0);
        visit(visit, node, letter, 0, 1, penaltyOf(letter, typedFirst), 0.0);
    }
    if (cancelled) return {};
    std::vector<ChannelCandidate> result; result.reserve(hits.size());
    for (const auto& [id, cost] : hits)
        result.push_back({std::string(word(id)), cost, std::log(double(std::max(frequency(id), 1u)) + 1)});
    return result;
}
bool PackedLexicon::installModern(std::span<const std::byte> sidecar) const {
    constexpr std::string_view sidecarMagic = "KBMODERN";
    constexpr std::size_t header = 56, digest = 32;   // magic, 4 x u32, dictionary SHA-256
    if (!policies_.empty() || sidecar.size() < header + digest || sidecar.size() > 1'000'000) return false;
    auto field = [&](std::size_t at) {
        std::uint32_t value = 0;
        for (unsigned i = 0; i < 4; ++i) value |= std::to_integer<std::uint32_t>(sidecar[at + i]) << (8 * i);
        return value;
    };
    for (std::size_t i = 0; i < sidecarMagic.size(); ++i) if (sidecar[i] != std::byte(sidecarMagic[i])) return false;
    const auto count = field(16);
    // Version 1, this dictionary's word count, no context rows (they fed the n-gram strip).
    if (field(8) != 1 || field(12) != words_ || field(20) != 0 || count > 10'000 ||
        sidecar.size() != header + 8 * std::size_t(count) + digest) return false;
    const auto checksum = dictionarySHA256(sidecar.first(sidecar.size() - digest));
    if (!std::equal(checksum.begin(), checksum.end(), sidecar.end() - digest)) return false;
    const auto dictionary = dictionarySHA256(bytes_);
    if (!std::equal(dictionary.begin(), dictionary.end(), sidecar.begin() + 24)) return false;
    std::vector<Policy> policies;
    policies.reserve(count);
    for (std::size_t i = 0; i < count; ++i) {
        const Policy policy{field(header + 8 * i), field(header + 8 * i + 4)};
        // A preserved spelling is also never an automatic replacement (bit 0 implies bit 1).
        if (policy.word >= words_ || !policy.flags || (policy.flags & ~3u) || ((policy.flags & 1) && !(policy.flags & 2)) ||
            (!policies.empty() && policy.word <= policies.back().word)) return false;
        policies.push_back(policy);
    }
    policies_ = std::move(policies);
    return !policies_.empty();
}
std::uint32_t PackedLexicon::modernFlags(std::string_view text) const {
    if (policies_.empty()) return 0;
    const auto id = wordID(text);
    if (!id) return 0;
    const auto found = std::lower_bound(policies_.begin(), policies_.end(), std::uint32_t(*id),
        [](const Policy& policy, std::uint32_t wanted) { return policy.word < wanted; });
    return found != policies_.end() && found->word == std::uint32_t(*id) ? found->flags : 0;
}
bool PackedLexicon::allowsCorrection(std::string_view text) const {
    while (!text.empty()) {
        const auto end = text.find(' ');
        if (modernFlags(text.substr(0, end)) & 2) return false;
        if (end == text.npos) break;
        text.remove_prefix(end + 1);
    }
    return true;
}
} // namespace kb
