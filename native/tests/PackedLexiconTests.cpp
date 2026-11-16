#include "../DecoderCore/include/PackedLexicon.hpp"
#include "../DecoderCore/include/Personalization.hpp"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

using Bytes = std::vector<std::byte>;
static void put(Bytes& bytes, std::uint32_t value, unsigned width = 4) {
    for (unsigned i = 0; i < width; ++i) bytes.push_back(std::byte((value >> (8 * i)) & 255));
}
static void replace(Bytes& bytes, std::size_t offset, std::uint32_t value, unsigned width = 4) {
    for (unsigned i = 0; i < width; ++i) bytes.at(offset + i) = std::byte((value >> (8 * i)) & 255);
}
constexpr std::uint32_t none = 0xffffffff;
constexpr std::size_t freqAt = 16, offsetsAt = freqAt + 3 * 4, trieAt = offsetsAt + 4 * 4, nodeSize = 14;
static Bytes fixture() {
    Bytes b;
    for (auto v : {0x4B424C4Du, 7u, 3u, 7u}) put(b, v);
    for (auto v : {11u, 22u, 33u}) put(b, v);
    for (auto v : {0u, 1u, 3u, 6u}) put(b, v);
    auto node = [&](char label, unsigned count, unsigned first, std::uint32_t word, unsigned maxFrequency) {
        put(b, std::uint8_t(label), 1); put(b, count, 1); put(b, first); put(b, word); put(b, maxFrequency);
    };
    node(0, 3, 1, none, 33);
    node('a', 0, 0, 0, 11); node('b', 1, 4, none, 22); node('c', 1, 5, none, 33);
    node('b', 0, 0, 1, 22); node('c', 1, 6, none, 33); node('c', 0, 0, 2, 33);
    for (char c : std::string("abbccc")) b.push_back(std::byte(c));
    return b;
}
static void rejects(const Bytes& bytes) {
    bool rejected = false;
    try { kb::PackedLexicon view{bytes}; }
    catch (const std::invalid_argument&) { rejected = true; }
    assert(rejected);
}
static bool found(const std::vector<kb::ChannelCandidate>& rows, std::string_view word) {
    return std::any_of(rows.begin(), rows.end(), [&](const auto& row) { return row.word == word; });
}
static void testFormat() {
    auto bytes = fixture();
    kb::PackedLexicon view{bytes};
    assert(view.backingAddress() == bytes.data());
    assert(view.version() == 7 && view.wordCount() == 3 && view.trieNodeCount() == 7 && view.hasTrie());
    assert(view.word(0) == "a" && view.word(1) == "bb" && view.word(2) == "ccc");
    assert(view.frequency(0) == 11 && view.frequency(2) == 33);
    assert(view.wordID("a") == 0 && view.wordID("bb") == 1 && view.wordID("ccc") == 2);
    assert(!view.wordID("b") && !view.wordID("cc") && !view.wordID("x") && !view.wordID("bbb"));
    auto root = view.trieRecord(0);
    assert(root.label == 0 && root.childCount == 3 && root.firstChild == 1 && !root.wordID && root.maxFrequency == 33);
    auto leaf = view.trieRecord(6);
    assert(leaf.label == 'c' && leaf.childCount == 0 && leaf.wordID == 2 && leaf.maxFrequency == 33);
    bool bounds = false;
    try { (void)view.word(3); } catch (const std::out_of_range&) { bounds = true; }
    assert(bounds);
    bounds = false;
    try { (void)view.trieRecord(7); } catch (const std::out_of_range&) { bounds = true; }
    assert(bounds);
    auto exact = view.search("bb", 0);
    assert(exact.size() == 1 && exact[0].word == "bb" && exact[0].cost == 0 && exact[0].logFrequency == std::log(23.0));
    assert(found(view.search("cc", 0.3), "ccc") && !found(view.search("cc", 0.29), "ccc"));
    assert(view.search("", 3).empty());
    bool radius = false;
    try { (void)view.search("bb", -1); } catch (const std::invalid_argument&) { radius = true; }
    assert(radius);
    view.installBlocked(std::vector<std::string>{"bb", "zz"});
    assert(view.blocked(1) && !view.blocked(0) && view.blockedCount() == 1);
    assert(view.search("bb", 0).empty() && found(view.search("ccc", 0), "ccc"));
    view.installBlocked(std::vector<std::string>{"ccc"});
    assert(!view.blocked(2) && view.blockedCount() == 1);
    for (std::size_t cut = 0; cut < bytes.size(); ++cut) rejects(Bytes(bytes.begin(), bytes.begin() + std::ptrdiff_t(cut)));
    auto bad = bytes; replace(bad, 0, 0); rejects(bad);
    bad = bytes; replace(bad, 4, 6); rejects(bad);
    bad = bytes; replace(bad, 4, 8); rejects(bad);
    bad = bytes; replace(bad, 8, 0xffffffff); rejects(bad);
    bad = bytes; replace(bad, 12, 8); rejects(bad);
    bad = bytes; replace(bad, offsetsAt + 4, 100); rejects(bad);
    bad = bytes; replace(bad, offsetsAt + 8, 0); rejects(bad);
    bad = bytes; replace(bad, trieAt + 2, 5); rejects(bad);
    bad = bytes; replace(bad, trieAt + nodeSize * 2 + 2, 1); rejects(bad);
    bad = bytes; replace(bad, trieAt + nodeSize * 1 + 6, 3); rejects(bad);
    std::cout << "PASS KBLM v7: words, frequencies, trie, search, blocked words, shared bytes, bounds, "
              << bytes.size() << " truncated prefixes and corrupt fields\n";
}
static void testWideIDs() {
    constexpr unsigned words = 65538;
    Bytes b;
    for (auto v : {0x4B424C4Du, 7u, words, 2u}) put(b, v);
    for (unsigned i = 0; i < words; ++i) put(b, 1);
    for (unsigned i = 0; i <= words; ++i) put(b, i);
    put(b, 0, 1); put(b, 1, 1); put(b, 1); put(b, none); put(b, 17);
    put(b, 'w', 1); put(b, 0, 1); put(b, 0); put(b, 65537); put(b, 17);
    for (unsigned i = 0; i < words; ++i) b.push_back(std::byte('w'));
    kb::PackedLexicon view{b};
    assert(view.wordID("w") == 65537 && view.trieRecord(1).wordID == 65537);
    auto hit = view.search("w", 0);
    assert(hit.size() == 1 && hit[0].word == "w");
    auto bad = b; replace(bad, 16 + 8 * words + 4 + 14 + 6, words); rejects(bad);
    std::cout << "PASS KBLM v7 word IDs above 65535\n";
}
static void testSpatial() {
    auto q = kb::grid('q'), a = kb::grid('a'), z = kb::grid('z');
    assert(q && q->x == 0 && q->y == 0);
    assert(a && a->x == 0.5 && a->y == 1);
    assert(z && z->x == 1.5 && z->y == 2 && !kb::grid('\''));
    assert(kb::substitutionCost('q', 'q') == 0);
    assert(std::abs(kb::substitutionCost('q', 'w') - 1.1) < 1e-12);
    assert(std::abs(kb::substitutionCost('q', 'w', kb::TouchOffset{-1, 0}) - 0.6) < 1e-12);
    assert(std::abs(kb::substitutionCost('s', 'z') - 0.9) < 1e-12);
    assert(std::abs(kb::substitutionCost('c', 'k') - 0.9) < 1e-12);
    assert(kb::substitutionCost('q', 'q', kb::TouchOffset{0, 0}) == 0);
    assert(kb::substitutionCost('q', 'q', kb::TouchOffset{INFINITY, 0}) == 3);
    assert(kb::substitutionCost('?', '?') == 0 && kb::substitutionCost('?', 'q') == 3);
    assert(kb::substitutionCost('e', 'a') == kb::vowelSubstitutionCost);
    assert(kb::deletionCostAt('s', 's', 's') == kb::doubledDeletionCost);
    assert(kb::deletionCostAt('n', 'n', 'e') == kb::deletionCost && kb::deletionCostAt('s', 'o', 's') == kb::deletionCost);
    assert(kb::insertionCostAt('l', 'l', 'l') == kb::doubledInsertionCost);
    assert(kb::insertionCostAt('e', 'e', 'n') == kb::insertionCost);
    assert(kb::firstLetterPenalty(2, 'n', 'm') == 0);
    assert(kb::firstLetterPenalty(3, 'n', 'm') == 0.35);
    assert(kb::firstLetterPenalty(4, 'n', 'm') == 0.2);
    assert(kb::firstLetterPenalty(5, 'n', 'm') == 1.0);
    assert(kb::firstLetterPenalty(5, 'p', 'a') == 2.0);
    assert(kb::firstLetterPenalty(5, 'c', 'o', 'c', 'o') == 0.75);
    assert(kb::firstLetterPenalty(5, 'c', 'o', 'c', 'a') == 2.0);
    assert(kb::firstLetterPenalty(5, 'c', 'o', 'c') == 2.0);
    assert(kb::firstLetterPenalty(20, 'm', 'm') == 0);
    assert(kb::personalLanguageBoost(2, 0.10) == 0);
    assert(std::abs(kb::personalLanguageBoost(3, 0.10) - 0.10 * std::log1p(1)) <= 1e-12);
    std::cout << "PASS spatial channel: geometry, Double costs, first-letter policy and the personal boost\n";
}
int main(int argc, char** argv) {
    testFormat();
    testWideIDs();
    testSpatial();
    if (argc > 1) {
        std::ifstream file(argv[1], std::ios::binary);
        if (!file) throw std::runtime_error("cannot open corpus");
        std::vector<char> storage{std::istreambuf_iterator<char>{file}, {}};
        kb::PackedLexicon corpus{{reinterpret_cast<const std::byte*>(storage.data()), storage.size()}};
        std::size_t terminals = 0;
        for (std::uint32_t id = 0; id < corpus.wordCount(); ++id) {
            auto spelling = corpus.word(id); (void)corpus.frequency(id);
            if (corpus.wordID(spelling) == std::int32_t(id)) ++terminals;
        }
        assert(terminals == corpus.wordCount());
        for (std::uint32_t id = 1; id < corpus.wordCount(); ++id) assert(corpus.frequency(id - 1) >= corpus.frequency(id));
        auto recovery = corpus.search("coeevitjkn", 7.2);
        assert(std::any_of(recovery.begin(), recovery.end(), [](const auto& candidate) {
            return candidate.word == "correction" && std::abs(candidate.cost - 6.775) <= 1e-9;
        }));
        assert(corpus.search("coeevitjkn", 7.2, {}, [] { return true; }).empty());
        std::cout << "PASS production dictionary v" << corpus.version() << ": " << corpus.wordCount()
                  << " words, every one reachable through the trie, " << corpus.trieNodeCount() << " trie nodes\n";
    }
}
