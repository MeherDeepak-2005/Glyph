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

// The English dictionary, langdata.bin (KBLM v7, tools/build_language_data.py): unigram
// frequencies and the spelling trie, nothing else. All fields little-endian:
//   header   magic 'KBLM' u32, version 7 u32, wordCount u32, trieNodes u32
//   freq     u32 x wordCount                      word frequencies, id = index
//   offsets  u32 x (wordCount + 1)                byte offsets into blob, per id
//   trie     (label u8, childCount u8, firstChild u32, wordID u32, maxFreq u32) x trieNodes
//            BFS order, node 0 the root; children contiguous and label-sorted; wordID
//            0xffffffff = not a word; maxFreq the highest frequency in the node's subtree
//   blob     UTF-8 word bytes
// Immutable borrowed view. The caller must retain the backing bytes for this object's
// entire lifetime. No vocabulary bytes are copied; returned string_views share them.
class PackedLexicon final {
public:
    static constexpr std::uint32_t formatVersion = 7;
    explicit PackedLexicon(std::span<const std::byte> bytes);
    std::uint32_t version() const noexcept { return formatVersion; }
    std::uint32_t wordCount() const noexcept { return words_; }
    // Safety-blocked words as a word-ID bitset, installed once at load and before any
    // search. search never emits them (traversal still passes through them: a blocked word
    // can prefix a clean one). Terms not in the dictionary are ignored.
    void installBlocked(std::span<const std::string> terms) const;
    bool blocked(std::uint32_t id) const noexcept { return id < words_ && !blocked_.empty() && (blocked_[id >> 6] >> (id & 63) & 1); }
    std::size_t blockedCount() const noexcept { return blockedCount_; }
    // Spelling policies for modern vocabulary (langdata.kbmodern, KBMODERN v1, built with the
    // dictionary by tools/vocabulary/build_unigram_pack.py): editor-reviewed permissions, not
    // counts. Install once at load, before any decode; a sidecar that is malformed or was
    // built for other dictionary bytes is refused and leaves no policy.
    bool installModern(std::span<const std::byte> sidecar) const;
    bool hasModern() const noexcept { return !policies_.empty(); }
    // Bit 0: keep the typed spelling (never autocorrect it away). Bit 1: never commit this
    // word automatically (it can still be suggested).
    std::uint32_t modernFlags(std::string_view word) const;
    bool preserves(std::string_view word) const { return modernFlags(word) & 1; }
    // False when any word of `text` (a split correction is several) must not be committed
    // automatically.
    bool allowsCorrection(std::string_view text) const;
    struct TrieNodeRecord { std::uint8_t label; std::uint32_t firstChild, childCount, maxFrequency; std::optional<std::int32_t> wordID; };
    bool hasTrie() const noexcept { return nodes_ > 0; }
    TrieNodeRecord trieRecord(std::size_t node) const;
    // The trie as stored, for readers that walk it in place instead of copying it:
    // trieNodeSize() bytes per node - label, child count, first child, word ID (all ones =
    // none), subtree max frequency - little-endian.
    const std::byte* trieData() const noexcept { return bytes_.data() + trie_; }
    static constexpr std::size_t trieNodeSize() noexcept { return nodeSize_; }
    std::size_t trieNodeCount() const noexcept { return nodes_; }
    const void* backingAddress() const noexcept { return bytes_.data(); }
    std::string_view word(std::uint32_t id) const;
    std::uint32_t frequency(std::uint32_t id) const;
    std::optional<std::int32_t> wordID(std::string_view word) const;
    // Every dictionary word within maxCost of `typed` under the edit/touch channel
    // (SpatialModel), blocked words excluded.
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
    mutable std::vector<Policy> policies_;   // ascending word ID; written once, before decoding
    std::optional<std::size_t> trieNode(std::string_view prefix) const;
};
} // namespace kb
