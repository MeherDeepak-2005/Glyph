#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <string>
#include <vector>
#include <memory>
#include <functional>
#include <mutex>
#include "SpatialModel.hpp"

namespace kb {
struct ChannelCandidate { std::string word; double cost, logFrequency; };

class PackedLexicon final {
public:
    static constexpr std::uint32_t formatVersion = 7;
    explicit PackedLexicon(std::span<const std::byte> bytes);
    std::uint32_t version() const noexcept { return formatVersion; }
    std::uint32_t wordCount() const noexcept { return words_; }
    void installBlocked(std::span<const std::string> terms) const;
    bool blocked(std::uint32_t id) const noexcept { return id < words_ && !blocked_.empty() && (blocked_[id >> 6] >> (id & 63) & 1); }
    std::size_t blockedCount() const noexcept { return blockedCount_; }
    bool installModern(std::span<const std::byte> sidecar) const;
    bool hasModern() const noexcept { return !policies_.empty(); }
    std::uint32_t modernFlags(std::string_view word) const;
    bool preserves(std::string_view word) const { return modernFlags(word) & 1; }
    bool allowsCorrection(std::string_view text) const;
    struct TrieNodeRecord { std::uint8_t label; std::uint32_t firstChild, childCount, maxFrequency; std::optional<std::int32_t> wordID; };
    bool hasTrie() const noexcept { return nodes_ > 0; }
    TrieNodeRecord trieRecord(std::size_t node) const;
    const std::byte* trieData() const noexcept { return bytes_.data() + trie_; }
    static constexpr std::size_t trieNodeSize() noexcept { return nodeSize_; }
    std::size_t trieNodeCount() const noexcept { return nodes_; }
    const void* backingAddress() const noexcept { return bytes_.data(); }
    std::string_view word(std::uint32_t id) const;
    std::uint32_t frequency(std::uint32_t id) const;
    std::optional<std::int32_t> wordID(std::string_view word) const;
    std::vector<ChannelCandidate> search(std::string_view typed, double maxCost,
        std::span<const std::optional<TouchOffset>> taps = {},
        const std::function<bool()>& shouldCancel = {}) const;
private:
    static constexpr std::size_t headerSize_ = 16, nodeSize_ = 14;
    std::span<const std::byte> bytes_;
    std::uint32_t words_, nodes_;
    std::size_t frequencies_, offsets_, trie_, blob_;
    std::uint32_t u32(std::size_t offset) const;
    void validate();
    mutable std::once_flag blockedOnce_;
    mutable std::vector<std::uint64_t> blocked_;
    mutable std::size_t blockedCount_ = 0;
    struct Policy { std::uint32_t word, flags; };
    mutable std::vector<Policy> policies_;
    std::optional<std::size_t> trieNode(std::string_view prefix) const;
};
}
