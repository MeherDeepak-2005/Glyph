#include <string>
#include <vector>
#include "../DecoderCore/include/Engine.hpp"
#include "../DecoderCore/include/Safety.hpp"
#include "../DecoderCore/include/SpatialModel.hpp"
#include "MiniJson.hpp"
#include <algorithm>
#include <cassert>
#include <cctype>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
#include <sstream>
using namespace kb;
static DecodeInput input(std::string word, std::uint64_t generation = 1, std::vector<std::string> context = {}) {
    DecodeInput in; in.word = in.normalized = std::move(word); in.context = std::move(context);
    in.identity = {1, generation, generation, generation, 1, 0, 0}; return in;
}
static std::string slurp(const std::string& path) { std::ifstream in(path, std::ios::binary); assert(in); std::stringstream out; out << in.rdbuf(); return out.str(); }
static std::string lower(std::string text) { for (auto& c : text) if (static_cast<unsigned char>(c) < 0x80) c = char(std::tolower(static_cast<unsigned char>(c))); return text; }
static const char* sourceName(CandidateSource source) {
    static const char* names[] = {"typed", "fuzzyLexicon", "splitCorrection"};
    return names[static_cast<int>(source)];
}
static GlideLayout qwerty() {
    GlideLayout layout{{}, 1, 1}; const char* rows[] = {"qwertyuiop", "asdfghjkl", "zxcvbnm"}; const double shifts[] = {0, 0.5, 1.5};
    for (int y = 0; y < 3; ++y) for (int x = 0; rows[y][x]; ++x) layout.centers.emplace_back(std::uint8_t(rows[y][x]), Point{x + shifts[y], double(y)});
    return layout;
}
static void replayGoldens(const std::shared_ptr<Engine>& engine, const std::string& root, const std::string& fixtures) {
    auto state = engine->createState();
    state->setSafety(parseSafetyPenalties(slurp(root + "/keyboard/safety.kbguard")));
    auto session = engine->createSession();
    auto corpus = json::parse(slurp(fixtures + "/corpus.json")), golden = json::parse(slurp(fixtures + "/golden-corpus.json"));
    assert(corpus.array().size() == 132 && golden.array().size() == 132);
    std::size_t mismatches = 0;
    for (std::size_t i = 0; i < corpus.array().size(); ++i) {
        const auto& fixture = corpus.array()[i]; const auto& expected = golden.array()[i];
        assert(fixture["id"].text() == expected["id"].text());
        DecodeInput in; in.word = fixture["typed"].text(); in.normalized = lower(in.word); in.identity = {1, i + 1, i + 1, i + 1, 1, 0, 0};
        for (const auto& word : fixture["context"].array()) in.context.push_back(lower(word.text()));
        auto actual = session->decode(in, state->view());
        std::vector<std::string> suggestions; for (const auto& s : expected["suggestions"].array()) suggestions.push_back(s.text());
        bool same = actual.status == EngineStatus::ok && actual.suggestions == suggestions
            && (expected["correction"].null() ? !actual.correction.word : actual.correction.word == expected["correction"].text())
            && actual.candidates.size() == expected["candidates"].array().size();
        for (std::size_t j = 0; same && j < actual.candidates.size(); ++j) {
            const auto& a = actual.candidates[j]; const auto& b = expected["candidates"].array()[j];
            same = a.ranked.channel.word == b["word"].text() && b["source"].text() == sourceName(a.source)
                && std::abs(a.ranked.channel.cost - b["cost"].number()) <= 1e-9 && std::abs(a.ranked.score - b["score"].number()) <= 1e-4;
        }
        if (!same) { ++mismatches; std::cerr << "golden decode mismatch: " << fixture["id"].text() << " '" << fixture["typed"].text() << "'\n"; }
    }
    auto glides = json::parse(slurp(fixtures + "/glides.json")), glideGolden = json::parse(slurp(fixtures + "/golden-glide.json"));
    assert(glides.array().size() == 60 && glideGolden.array().size() == 60);
    const auto layout = qwerty();
    for (std::size_t i = 0; i < glides.array().size(); ++i) {
        const auto& fixture = glides.array()[i]; std::vector<std::string> context;
        for (const auto& word : fixture["context"].array()) context.push_back(lower(word.text()));
        std::vector<Point> path; for (const auto& point : fixture["points"].array()) path.push_back({point.array()[0].number(), point.array()[1].number()});
        session->beginGlide(context);
        auto ranked = session->updateGlide(path, layout, state->view(), state->dynamicGlideWords()); session->endGlide();
        std::vector<std::string> actual; for (std::size_t k = 0; k < ranked.size() && k < 4; ++k) actual.push_back(ranked[k].key);
        std::vector<std::string> expected; for (const auto& s : glideGolden.array()[i]["suggestions"].array()) expected.push_back(s.text());
        if (actual != expected) { ++mismatches; std::cerr << "golden glide mismatch: " << fixture["id"].text() << "\n"; }
    }
    assert(mismatches == 0);
    std::cout << "Engine matches its 132 decode goldens and 60 Glide goldens\n";
}
static void testSafety(const std::string& root) {
    const auto blob = slurp(root + "/keyboard/safety.kbguard");
    SafetyLexicon safety(blob);
    assert(safety.size() == 997);
    for (const char* word : {"fuck", "5h1t", "2 girls 1 cup", "xxx", "దెంగు"}) assert(safety.blocked(word));
    assert(safety.language("దెంగు") == SafetyLanguage::telugu);
    assert(safety.action("కుక్క") == SafetyAction::demote && safety.penalty("కుక్క") == 4 && !safety.blocked("కుక్క"));
    for (const char* word : {"class", "meher", "telangana", "prolly", "kukka", ""}) assert(safety.action(word) == SafetyAction::allow && safety.penalty(word) == 0);
    assert(!safety.blocked("FUCK"));
    auto table = safety.penalties(); assert(table == parseSafetyPenalties(blob) && table.size() == 997);
    for (const auto& [word, value] : table) assert(safety.penalty(word) == value);
    auto blocked = safety.blockedTerms(); assert(blocked.size() == 991 && std::is_sorted(blocked.begin(), blocked.end()));
    for (std::size_t n = 0; n < blob.size(); ++n) { bool rejected = false; try { SafetyLexicon cut(std::string_view(blob).substr(0, n)); } catch (const std::invalid_argument&) { rejected = true; } assert(rejected); }
    auto expectRejected = [](std::string bytes) { bool rejected = false; try { SafetyLexicon bad(bytes); } catch (const std::invalid_argument&) { rejected = true; } assert(rejected); };
    { auto bad = blob; std::swap_ranges(bad.begin() + 24, bad.begin() + 32, bad.begin() + 48); expectRejected(bad); }
    { auto bad = blob; bad[24] = char(bad[24] ^ 1); expectRejected(bad); }
    std::cout << "Safety lexicon: 997 entries, lookups, penalties, ordering/hash validation and truncation passed\n";
}
static void testBlockedWords(const std::shared_ptr<Engine>& engine, const std::shared_ptr<const PackedLexicon>& reader, const std::string& root) {
    const auto blob = slurp(root + "/keyboard/safety.kbguard");
    SafetyLexicon safety(blob);
    auto state = engine->createState();
    state->setSafety(parseSafetyPenalties(blob));
    std::size_t inDictionary = 0;
    for (const auto& term : safety.blockedTerms()) if (auto id = reader->wordID(term)) { ++inDictionary; assert(reader->blocked(std::uint32_t(*id))); }
    assert(inDictionary == 297 && reader->blockedCount() == 297);
    auto isBlockedWord = [&](const std::string& word) { auto id = reader->wordID(word); return id && reader->blocked(std::uint32_t(*id)); };
    for (const auto& term : safety.blockedTerms()) if (reader->wordID(term))
        for (const auto& hit : reader->search(term, 2.8)) assert(!isBlockedWord(hit.word));
    auto session = engine->createSession(); auto view = state->view();
    assert(view.penalties && view.penalties->empty());
    std::uint64_t generation = 100;
    for (std::uint32_t id = 0; id < 120; ++id) {
        auto predicted = session->decode(input("", ++generation, {std::string(reader->word(id))}), view);
        for (const auto& word : predicted.suggestions) assert(!isBlockedWord(word));
    }
    for (const char* typo : {"biitch", "masterbation", "bicthes", "fuk", "shitt"}) {
        auto decoded = session->decode(input(typo, ++generation), view);
        assert(!decoded.correction.word || !isBlockedWord(*decoded.correction.word));
        for (const auto& s : decoded.suggestions) assert(s == typo || !isBlockedWord(s));
        for (const auto& c : decoded.candidates) assert(c.ranked.key == typo || !isBlockedWord(c.ranked.key));
    }
    std::cout << "Blocked words: 297 dictionary words excluded from search, decoding, predictions and corrections\n";
}
static void testInstalledGrid() {
    using Rows = std::array<std::string_view, 3>; using Offsets = std::array<double, 3>;
    const Rows qwertyRows{"qwertyuiop", "asdfghjkl", "zxcvbnm"}; const Offsets offsets{0.0, 0.5, 1.5};
    assert(gridLetters() == "qwertyuiopasdfghjklzxcvbnm");
    assert(installGrid(qwertyRows, offsets) && grid('a')->x == 0.5 && grid('z')->x == 1.5);
    assert(!installGrid(Rows{"qwertyuiop", "asdfghjkl", "zxcvbn"}, offsets));
    assert(!installGrid(Rows{"qwertyuiop", "asdfghjkl", "zxcvbnmq"}, offsets));
    assert(!installGrid(Rows{"qwertyuiop", "asdfghjkl", "zxcvbnM"}, offsets));
    assert(!installGrid(qwertyRows, std::array<double, 2>{0.0, 0.5}));
    assert(gridLetters() == "qwertyuiopasdfghjklzxcvbnm" && grid('m')->x == 7.5);
    const Rows azerty{"azertyuiop", "qsdfghjklm", "wxcvbn"};
    assert(installGrid(azerty, offsets) && grid('q')->y == 1 && grid('m')->x == 9.5 && !neighbouringKeys('q', 'w'));
    assert(installGrid(qwertyRows, offsets) && grid('q')->x == 0 && grid('q')->y == 0 && neighbouringKeys('q', 'w'));
}
static void testPersonalization(const std::shared_ptr<const PackedLexicon>& reader) {
    Personalization user; user.reset(4);
    user.learn("word"); auto old = user.counts();
    user.learn("word");
    assert(old->uni("word") == 1 && user.counts()->uni("word") == 2);
    user.demote("word"); assert(user.counts()->uni("word") == 1);
    user.demote("word"); assert(!user.counts()->uni("word") && !user.counts()->unigram.contains("word"));
    user.learn("word");
    user.confirm("word"); assert(user.kept("word") && user.confirmations("word") == 1); user.releaseKeep("word"); assert(!user.kept("word"));
    auto snapshot = user.exportSnapshot(); assert(snapshot.epoch == 4 && snapshot.counts.uni("word") == 1 && snapshot.confirmed.at("word") == 1);
    Personalization restored; restored.install(snapshot); assert(restored.epoch() == 4 && restored.counts()->uni("word") == 1 && restored.confirmations("word") == 1);
    std::string longWord(1100, 'x');
    user.learn(longWord); user.learn(""); user.confirm(""); user.confirm(longWord);
    assert(!user.counts()->uni(longWord) && !user.counts()->unigram.contains("") && user.confirmations(longWord) == 0);
    user.reset(5); assert(user.counts()->unigram.empty() && old->uni("word") == 1 && !user.kept("word") && user.epoch() == 5);
    for (int i = 0; i < 4100; ++i) user.learn("word" + std::to_string(i));
    assert(user.prune() && user.counts()->unigram.empty() && !user.prune());
    for (int i = 0; i < 4100; ++i) { user.learn("w" + std::to_string(i)); user.learn("w" + std::to_string(i)); user.learn("w" + std::to_string(i)); }
    assert(user.prune() && user.counts()->unigram.size() == 4000);
    GenerationSnapshot generation; MutableTrie supplementary, adopted;
    const GenerationLexicon lexicon{reader.get(), nullptr, &supplementary, &adopted, &generation};
    PersonalCounts counts; counts.unigram = {{"hello", 5}, {"zorblat", 5}, {"world", 2}};
    assert(std::abs(personalBoost("hello", counts, lexicon) - 0.10 * std::log1p(3)) < 1e-12);
    assert(personalBoost("world", counts, lexicon) == 0 && personalBoost("zorblat", counts, lexicon) == 0);
    adopted.insert("zorblat", 5); assert(personalBoost("zorblat", counts, lexicon) > 0);
    Personalization adoption; adoption.reset(1);
    assert(!adoption.allowsAdoption("blorptastic", 7, lexicon) && !adoption.allowsAdoption("blorptastic", 15, lexicon));
    assert(adoption.allowsAdoption("blorptastic", 16, lexicon));
    adoption.confirm("blorptastic"); assert(adoption.allowsAdoption("blorptastic", 8, lexicon));
    assert(!adoption.allowsAdoption("helllo", 40, lexicon));
    assert(adoption.allowsAdoption("hello", 8, lexicon));
    EngineState state(reader);
    for (int i = 0; i < 15; ++i) state.apply({UserEventKind::learn, "blorptastic"});
    assert(!state.view().lexicon.contains("blorptastic"));
    state.apply({UserEventKind::learn, "blorptastic"});
    assert(state.view().lexicon.contains("blorptastic") && state.dynamicGlideWords() == std::vector<std::string>{"blorptastic"});
    state.apply({UserEventKind::reset, "", 2});
    assert(!state.view().lexicon.contains("blorptastic") && state.view().personal->unigram.empty());
    state.apply({UserEventKind::supplementary, "meherdeepak"});
    assert(state.view().lexicon.contains("meherdeepak"));
    std::cout << "Personalization: unigram counts, copy-on-write snapshots, keep/undo, limits, prune, boost, adoption and reset passed\n";
}
static void installPolicies(const PackedLexicon& lexicon, std::string path) {
    if (auto dot = path.rfind('.'); dot != std::string::npos) path.resize(dot);
    std::ifstream in(path + ".kbmodern", std::ios::binary);
    if (!in) return;
    std::vector<char> sidecar((std::istreambuf_iterator<char>(in)), {});
    lexicon.installModern({reinterpret_cast<const std::byte*>(sidecar.data()), sidecar.size()});
}
int main(int argc, char** argv) {
    assert(argc == 3 || argc == 5);
    testInstalledGrid();
    std::ifstream stream(argv[1], std::ios::binary); std::vector<char> chars((std::istreambuf_iterator<char>(stream)), {}); assert(!chars.empty());
    auto backing = std::make_shared<std::vector<char>>(std::move(chars));
    auto reader = std::shared_ptr<const PackedLexicon>(new PackedLexicon({reinterpret_cast<const std::byte*>(backing->data()), backing->size()}), [backing](const PackedLexicon* p) { delete p; });
    installPolicies(*reader, argv[1]);
    std::ifstream modelStream(argv[2], std::ios::binary); std::vector<char> modelChars((std::istreambuf_iterator<char>(modelStream)), {}); assert(!modelChars.empty());
    auto modelBacking = std::make_shared<std::vector<char>>(std::move(modelChars));
    auto model = NeuralWordModel::load({reinterpret_cast<const std::byte*>(modelBacking->data()), modelBacking->size()}, modelBacking);
    testPersonalization(reader);
    bool refused = false;
    try { Engine missing(reader, nullptr); } catch (const std::invalid_argument&) { refused = true; }
    assert(refused);
    refused = false;
    try { Engine missing(nullptr, model); } catch (const std::invalid_argument&) { refused = true; }
    assert(refused);
    auto engine = std::make_shared<Engine>(reader, model); auto session = engine->createSession();
    GenerationSnapshot generation; MutableTrie supplemental, personal; PersonalCounts counts;
    EngineView view{{reader.get(), nullptr, &supplemental, &personal, &generation}, &counts, {}, 0, 0};
    std::uint64_t n = 0;
    for (const auto& word : {"t", "teh", "the", "hello", "hell", "helo", "coeevitjkn", "alot", "avlot", "cant", "id", "qzvaxon"}) {
        auto in = input(word, ++n, {"i", "think"});
        auto actual = session->decode(in, view); auto fresh = engine->createSession()->decode(in, view);
        assert(actual.status == EngineStatus::ok && actual.suggestions == fresh.suggestions && actual.correction.word == fresh.correction.word);
        assert(actual.candidates.size() == fresh.candidates.size() && !actual.suggestions.empty() && actual.suggestions.size() <= 3);
        for (std::size_t i = 0; i < actual.candidates.size(); ++i) {
            assert(actual.candidates[i].ranked.channel.word == fresh.candidates[i].ranked.channel.word);
            assert(actual.candidates[i].ranked.score == fresh.candidates[i].ranked.score);
        }
        assert(actual.suggestions.front() == (actual.correction.word ? *actual.correction.word : std::string(word)));
    }
    for (const char* prefix : {"h", "he", "hel", "hell"}) (void)session->decode(input(prefix, 50), view);
    auto retained = session->decode(input("hello", 50), view), oneShot = engine->createSession()->decode(input("hello", 50), view);
    assert(retained.suggestions == oneShot.suggestions && retained.correction.word == oneShot.correction.word);
    auto predicted = session->decode(input("", 60, {"thank"}), view);
    assert(predicted.suggestions.size() == 3 && !predicted.correction.word && predicted.candidates.empty());
    CancellationToken token; token.cancel();
    auto cancelled = session->decode(input("hello", 61), view, &token);
    assert(cancelled.status == EngineStatus::cancelled && cancelled.suggestions.empty());
    bool mismatch = false;
    EngineView other{{nullptr, nullptr, &supplemental, &personal, &generation}, &counts, {}, 0, 0};
    try { (void)session->decode(input("hello", 62), other); } catch (const std::invalid_argument&) { mismatch = true; }
    assert(mismatch);
    bool invalid = false;
    try { (void)session->decode(input("\xff", 63), view); } catch (const std::invalid_argument&) { invalid = true; }
    assert(invalid);
    auto keptInput = input("teh", 64, {"i", "will", "send", "you"});
    assert(session->decode(keptInput, view).correction.word);
    keptInput.kept = true; keptInput.identity.wordSessionID = 65;
    auto kept = session->decode(keptInput, view);
    assert(!kept.correction.word && kept.suggestions.front() == "teh");
    session->memoryPressure();
    assert(session->decode(input("hello", 66), view).suggestions == engine->createSession()->decode(input("hello", 66), view).suggestions);
    const auto layout = qwerty();
    auto glide = engine->createSession();
    for (const char* word : {"the", "thanks", "something"}) {
        glide->beginGlide({});
        auto ranked = glide->updateGlide(*idealPath(word, 40), layout, view, {});
        assert(!ranked.empty() && ranked.front().key == word);
    }
    personal.insert("zorblat", 9);
    glide->beginGlide({"the"});
    auto adopted = glide->updateGlide(*idealPath("zorblat", 40), layout, view, std::vector<std::string>{"zorblat"});
    assert(std::any_of(adopted.begin(), adopted.end(), [](const auto& row) { return row.key == "zorblat"; }));
    CancellationToken stop; stop.cancel();
    assert(glide->updateGlide(*idealPath("hello", 40), layout, view, {}, &stop).empty());
    if (argc == 5) { testSafety(argv[3]); testBlockedWords(engine, reader, argv[3]); replayGoldens(engine, argv[3], argv[4]); }
    std::cout << "Engine: determinism, retained search, prediction, cancellation, validation, kept words, memory pressure and Glide passed\n";
}
