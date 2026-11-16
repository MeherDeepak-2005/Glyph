#include "../DecoderCore/include/Engine.hpp"
#include "../DecoderCore/include/NssRules.hpp"
#include <cassert>
#include <cctype>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
using namespace kb;
static std::vector<std::byte> read(const char* path) {
    std::ifstream in(path, std::ios::binary); assert(in);
    std::stringstream ss; ss << in.rdbuf(); auto s = ss.str();
    std::vector<std::byte> out(s.size()); std::memcpy(out.data(), s.data(), s.size()); return out;
}
static std::vector<std::pair<std::uint32_t, double>> bruteForce(const NeuralFst& graph, const NeuralLexicon& lex, std::size_t count) {
    std::vector<std::pair<std::uint32_t, double>> all;
    for (std::uint32_t w = 0; w < lex.unigram.size(); ++w) if (std::isfinite(lex.unigram[w]) && lex.terminal[w] != UINT32_MAX) all.emplace_back(w, graph.wordScore(0, w));
    std::partial_sort(all.begin(), all.begin() + std::ptrdiff_t(count), all.end(),
        [](const auto& a, const auto& b) { return a.second == b.second ? a.first < b.first : a.second > b.second; });
    all.resize(count); return all;
}
static void admissible(const NeuralFst& graph, const NeuralLexicon& lex, std::uint32_t state) {
    for (std::uint32_t w = 0; w < lex.unigram.size(); w += 13) {
        if (!std::isfinite(lex.unigram[w]) || lex.terminal[w] == UINT32_MAX) continue;
        const auto score = graph.wordScore(state, w);
        for (auto node = lex.terminal[w];;) { assert(graph.lookahead(state, node) + 1e-5 >= score); if (!node) break; node = lex.parent[node]; }
    }
}
int main(int argc, char** argv) {
    assert(argc == 3);
    auto bytes = read(argv[1]), pack = read(argv[2]);
    auto model = NeuralWordModel::load(bytes);
    auto packed = std::make_shared<PackedLexicon>(pack);
    auto lex = std::make_shared<NeuralLexicon>(*packed);

    UnigramModel unigram(*packed);
    double total = 0;
    for (std::uint32_t w = 0; w < packed->wordCount(); ++w) total += double(packed->frequency(w)) + 1;
    std::size_t checked = 0;
    for (std::uint32_t w = 0; w < packed->wordCount(); w += 7) {
        assert(std::abs(unigram.logProbability(packed->word(w)) - std::log((double(packed->frequency(w)) + 1) / total)) < 1e-9); ++checked;
    }
    for (const char* text : {"xqzzy", "ahmetovic", "", "the cat"}) { assert(std::abs(unigram.logProbability(text) - std::log(0.5 / total)) < 1e-12); ++checked; }
    const std::vector<std::string> context{"one"};
    const auto of = std::uint32_t(*packed->wordID("of")), the = std::uint32_t(*packed->wordID("the"));

    NeuralFst neural(model, lex);
    for (std::vector<std::string> c : std::vector<std::vector<std::string>>{{}, {"can", "you"}, {"thank"}}) {
        neural.update(c, true);
        auto best = neural.best(0, 5), brute = bruteForce(neural, *lex, 5);
        for (std::size_t i = 0; i < 5; ++i) assert(best[i].first == brute[i].first && std::abs(best[i].second - brute[i].second) < 1e-6);
    }

    NeuralFst exact(model, lex, NeuralFst::Options{true});
    std::vector<std::int32_t> inside(lex->unigram.size(), -1);
    for (std::int32_t id = 4; id < std::int32_t(model->vocabularySize()); ++id)
        if (auto w = packed->wordID(model->word(id))) inside[std::size_t(*w)] = id;
    double outsideMass = 0;
    for (std::uint32_t w = 0; w < lex->unigram.size(); ++w) if (std::isfinite(lex->unigram[w]) && inside[w] < 0) outsideMass += double(packed->frequency(w)) + 1;
    const double share = model->unknownLexiconShare();
    std::size_t exactChecked = 0, belowThreshold = 0;
    for (std::vector<std::string> c : std::vector<std::vector<std::string>>{{}, {"can", "you"}, {"i", "live", "in"}}) {
        exact.update(c, true); neural.update(c, true);
        ContextRing ring(model);
        std::vector<std::int32_t> ids;
        for (const auto& word : c) if (auto id = model->contextID(word); id >= 0) ids.push_back(id);
        ring.sync(ids);
        std::vector<float> p(model->vocabularySize());
        model->wordLogProbabilities(ring.features(), p);
        const double unk = p[std::size_t(model->unknown())];
        double total = 0, expected = std::exp(unk) * share, published = 0;
        for (std::uint32_t w = 0; w < lex->unigram.size(); ++w) {
            if (!std::isfinite(lex->unigram[w]) || lex->terminal[w] == UINT32_MAX) continue;
            const double score = exact.wordScore(0, w);
            if (inside[w] >= 0) {
                const double direct = p[std::size_t(inside[w])];
                assert(std::abs(score - direct) < 1e-6);
                expected += std::exp(direct); belowThreshold += direct < nssUpdateThreshold;
            } else {
                assert(std::abs(score - (unk + std::log(share) + std::log((double(packed->frequency(w)) + 1) / outsideMass))) < 1e-5);
            }
            total += std::exp(score); published += std::exp(neural.wordScore(0, w)); ++exactChecked;
        }
        assert(std::abs(total - expected) < 1e-4);
        std::cout << "  context \"";
        for (std::size_t i = 0; i < c.size(); ++i) std::cout << (i ? " " : "") << c[i];
        std::cout << "\": lexicon mass exact " << total << ", published graph " << published << ", P(<unk>) " << std::exp(unk) << "\n";
        admissible(exact, *lex, 0);
        auto best = exact.best(0, 5), brute = bruteForce(exact, *lex, 5);
        for (std::size_t i = 0; i < 5; ++i) assert(best[i].first == brute[i].first && std::abs(best[i].second - brute[i].second) < 1e-6);
    }
    assert(belowThreshold > 0);
    exact.update(context, true);
    const auto ofState = exact.transitions(0, of);
    assert(ofState.size() == 1 && ofState.front().next > 1);
    exact.extend(ofState.front().next);
    {
        ContextRing ring(model);
        std::vector<std::int32_t> ids{model->contextID("one"), model->contextID("of")};
        ring.sync(ids);
        std::vector<float> p(model->vocabularySize());
        model->wordLogProbabilities(ring.features(), p);
        assert(std::abs(exact.wordScore(ofState.front().next, the) - p[std::size_t(inside[the])]) < 1e-5);
    }
    admissible(exact, *lex, ofState.front().next);

    NeuralFst floored(model, lex, NeuralFst::Options{true, true});
    for (std::vector<std::string> c : std::vector<std::vector<std::string>>{{"will"}, {"i", "live", "in"}}) {
        floored.update(c, true); exact.update(c, true);
        ContextRing ring(model);
        std::vector<std::int32_t> ids;
        for (const auto& word : c) if (auto id = model->contextID(word); id >= 0) ids.push_back(id);
        ring.sync(ids);
        std::vector<float> p(model->vocabularySize());
        model->wordLogProbabilities(ring.features(), p);
        const double unk = p[std::size_t(model->unknown())];
        std::size_t lifted = 0;
        for (std::uint32_t w = 0; w < lex->unigram.size(); ++w) {
            if (!std::isfinite(lex->unigram[w]) || lex->terminal[w] == UINT32_MAX) continue;
            const double score = floored.wordScore(0, w);
            if (inside[w] >= 0) {
                assert(std::abs(score - std::max(double(p[std::size_t(inside[w])]), unk + lex->unigram[w])) < 1e-5);
                lifted += unk + lex->unigram[w] > p[std::size_t(inside[w])];
            } else assert(std::abs(score - exact.wordScore(0, w)) < 1e-9);
        }
        assert(lifted > 0);
        admissible(floored, *lex, 0);
        auto best = floored.best(0, 5), brute = bruteForce(floored, *lex, 5);
        for (std::size_t i = 0; i < 5; ++i) assert(best[i].first == brute[i].first && std::abs(best[i].second - brute[i].second) < 1e-6);
    }

    for (double a : {0.5, 0.0}) {
        NeuralFst flat(model, lex, NeuralFst::Options{true, true, a});
        auto scale = [&](double u) { return a > 0 ? std::pow(u, a) : 1 + std::log(u); };
        double flatMass = 0;
        for (std::uint32_t w = 0; w < lex->unigram.size(); ++w) if (std::isfinite(lex->unigram[w]) && inside[w] < 0) flatMass += scale(double(packed->frequency(w)) + 1);
        std::vector<std::string> c{"i", "was", "talking", "to"};
        flat.update(c, true);
        ContextRing ring(model);
        std::vector<std::int32_t> ids;
        for (const auto& word : c) if (auto id = model->contextID(word); id >= 0) ids.push_back(id);
        ring.sync(ids);
        std::vector<float> p(model->vocabularySize());
        model->wordLogProbabilities(ring.features(), p);
        const double unk = p[std::size_t(model->unknown())];
        double outside = 0;
        for (std::uint32_t w = 0; w < lex->unigram.size(); ++w) {
            if (!std::isfinite(lex->unigram[w]) || lex->terminal[w] == UINT32_MAX || inside[w] >= 0) continue;
            const double expected = unk + std::log(share) + std::log(scale(double(packed->frequency(w)) + 1) / flatMass);
            assert(std::abs(flat.wordScore(0, w) - expected) < 1e-5);
            outside += std::exp(flat.wordScore(0, w) - unk - std::log(share));
        }
        assert(std::abs(outside - 1) < 1e-3);
        const double half = a > 0 ? std::pow(0.5, a) : 1.0;
        assert(std::abs(flat.typedUnknown() - (unk + std::log(1 - share) + std::log(half / flatMass))) < 1e-9);
        admissible(flat, *lex, 0);
        auto best = flat.best(0, 5), brute = bruteForce(flat, *lex, 5);
        for (std::size_t i = 0; i < 5; ++i) assert(best[i].first == brute[i].first && std::abs(best[i].second - brute[i].second) < 1e-6);
    }
    assert(!std::isfinite(neural.typedUnknown()));

    std::size_t literals = 0;
    for (int variant = 0; variant < 4; ++variant) {
    EngineOptions options; options.nssExact = variant != 2; options.nssUnigramFloor = variant == 1 || variant == 3;
    options.nssTypedUnknown = variant == 1 || variant == 3;
    if (variant == 3) options.nssUnknownExponent = 0.5;
    if (variant == 1) { const EngineOptions shipped; assert(shipped.nssExact == options.nssExact && shipped.nssUnigramFloor == options.nssUnigramFloor
        && shipped.nssUnknownExponent == options.nssUnknownExponent && shipped.nssTypedUnknown == options.nssTypedUnknown); }
    auto engine = std::make_shared<Engine>(packed, model, options);
    auto state = engine->createState();
    {
        for (const char* typed : {"teh", "recieve", "howmny", "hello", "ahmet"}) {
            DecodeInput in; in.word = in.normalized = typed;
            in.context = {"i", "will", "send", "you"}; in.identity.fieldRevision = 1; in.identity.wordSessionID = 7;
            auto one = engine->createSession()->decode(in, state->view()), two = engine->createSession()->decode(in, state->view());
            assert(one.status == EngineStatus::ok && one.suggestions == two.suggestions && one.correction.word == two.correction.word);
            const auto typedRow = std::find_if(one.candidates.begin(), one.candidates.end(), [&](const auto& c) { return c.ranked.key == typed; });
            const double margin = packed->wordID(typed) ? 0 : nssRawCommitMargin;
            if (one.correction.word) {
                assert(one.correction.margin > -margin && one.suggestions.front() == *one.correction.word);
                for (const auto& c : one.candidates) if (c.ranked.key == *one.correction.word) assert(c.typedMargin > -margin);
            } else if (typedRow != one.candidates.end()) {
                const bool splitSetAside = nssRuleOn(nssRuleSplitMargin) && std::any_of(one.candidates.begin(), one.candidates.end(),
                    [](const auto& c) { return c.typedMargin > 0 && c.ranked.key.find(' ') != std::string::npos; });
                if (!splitSetAside) for (const auto& c : one.candidates) if (c.ranked.key.size() == std::strlen(typed) && c.ranked.channel.cost > 0) assert(c.typedMargin <= 0 || c.ranked.key.find(' ') != std::string::npos);
            }
            if (!packed->wordID(typed) && !options.nssTypedUnknown && typedRow != one.candidates.end()) {
                assert(std::abs(typedRow->ranked.language - unigram.logProbability(typed)) < 1e-12);
                ++literals;
            }
        }
        for (const char* typed : {"Recieve", "Ahmet", "Teh"}) {
            DecodeInput in; in.word = typed; in.normalized = typed; in.normalized[0] = char(std::tolower(static_cast<unsigned char>(in.normalized[0])));
            in.context = {"i", "will", "send", "you"}; in.identity.fieldRevision = 4; in.identity.wordSessionID = 11;
            auto out = engine->createSession()->decode(in, state->view());
            if (out.correction.word && !packed->wordID(in.normalized)) assert(out.correction.margin > -nssCapitalizedCommitMargin);
            in.context.clear(); in.identity.wordSessionID = 12;
            out = engine->createSession()->decode(in, state->view());
            if (out.correction.word && !packed->wordID(in.normalized)) assert(out.correction.margin > -nssStartCommitMargin);
        }
        DecodeInput kept; kept.word = kept.normalized = "teh"; kept.context = {"i", "will", "send", "you"};
        kept.identity.fieldRevision = 3; kept.identity.wordSessionID = 9;
        assert(engine->createSession()->decode(kept, state->view()).correction.word);
        kept.kept = true;
        assert(!engine->createSession()->decode(kept, state->view()).correction.word);
        DecodeInput next; next.context = {"thank"}; next.identity.fieldRevision = 2;
        auto predicted = engine->createSession()->decode(next, state->view());
        assert(predicted.suggestions.size() == 3);
    }
    }
    assert(literals >= 3);
    std::cout << "Decoding: UnigramModel matches the dictionary on " << checked << " scores and " << literals << " typed literals; NSS exact scores match the model on "
              << exactChecked << " (" << belowThreshold << " vocabulary scores below e^-15); lookahead bounds, best(), argmax commit passed\n";
}
