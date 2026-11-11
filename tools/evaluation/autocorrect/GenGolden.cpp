// Writes the engine's goldens for tools/evaluation/fixtures/shared-engine, one JSON object per
// line: `decode` for corpus.json (golden-corpus.json), `glide` for glides.json (golden-glide.json).
// native/tests/EngineTests.cpp replays both.
//   gengolden langdata.bin model.nsslm REPO FIXTURES decode|glide
#include "Engine.hpp"
#include "Safety.hpp"
#include "MiniJson.hpp"
#include <cassert>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
using namespace kb;
static std::string slurp(const std::string& path) { std::ifstream in(path, std::ios::binary); assert(in); std::stringstream out; out << in.rdbuf(); return out.str(); }
static std::shared_ptr<const std::vector<std::byte>> bytes(const std::string& path) {
    auto text = slurp(path); auto out = std::make_shared<std::vector<std::byte>>(text.size());
    std::memcpy(out->data(), text.data(), text.size()); return out;
}
static std::string lower(std::string text) { for (auto& c : text) if (static_cast<unsigned char>(c) < 0x80) c = char(std::tolower(static_cast<unsigned char>(c))); return text; }
static const char* sourceName(CandidateSource source) {
    static const char* names[] = {"typed", "fuzzyLexicon", "splitCorrection"};
    return names[static_cast<int>(source)];
}
int main(int argc, char** argv) {
    if (argc != 6) { std::cerr << "usage: gengolden langdata.bin model.nsslm REPO FIXTURES decode|glide\n"; return 2; }
    const std::string root = argv[3], fixtures = argv[4], mode = argv[5];
    auto pack = bytes(argv[1]), weights = bytes(argv[2]);
    auto reader = std::shared_ptr<const PackedLexicon>(new PackedLexicon(*pack), [pack](const PackedLexicon* p) { delete p; });
    auto model = NeuralWordModel::load(*weights, weights);
    auto engine = std::make_shared<Engine>(reader, model); auto state = engine->createState();
    state->setSafety(parseSafetyPenalties(slurp(root + "/keyboard/safety.kbguard")));
    auto session = engine->createSession();
    auto q = [](const std::string& s) { std::string r = "\""; for (char c : s) { if (c == '"' || c == '\\') r += '\\'; r += c; } return r + "\""; };
    if (mode == "decode") {
        auto corpus = json::parse(slurp(fixtures + "/corpus.json"));
        for (std::size_t i = 0; i < corpus.array().size(); ++i) {
            const auto& fixture = corpus.array()[i];
            DecodeInput in; in.word = fixture["typed"].text(); in.normalized = lower(in.word);
            in.identity = {1, i + 1, i + 1, i + 1, 1, 0, 0};
            for (const auto& word : fixture["context"].array()) in.context.push_back(lower(word.text()));
            auto r = session->decode(in, state->view());
            std::printf("{\"id\":%s,\"correction\":%s,\"suggestions\":[", q(fixture["id"].text()).c_str(), r.correction.word ? q(*r.correction.word).c_str() : "null");
            for (std::size_t k = 0; k < r.suggestions.size(); ++k) std::printf("%s%s", k ? "," : "", q(r.suggestions[k]).c_str());
            std::printf("],\"candidates\":[");
            for (std::size_t k = 0; k < r.candidates.size(); ++k) { const auto& c = r.candidates[k];
                std::printf("%s{\"word\":%s,\"source\":\"%s\",\"cost\":%.17g,\"score\":%.17g}", k ? "," : "", q(c.ranked.channel.word).c_str(), sourceName(c.source), c.ranked.channel.cost, c.ranked.score); }
            std::printf("]}\n");
        }
        return 0;
    }
    if (mode != "glide") { std::cerr << "unknown mode " << mode << "\n"; return 2; }
    auto glides = json::parse(slurp(fixtures + "/glides.json"));
    GlideLayout layout{{}, 1, 1}; const char* rows[] = {"qwertyuiop", "asdfghjkl", "zxcvbnm"}; const double shifts[] = {0, 0.5, 1.5};
    for (int y = 0; y < 3; ++y) for (int x = 0; rows[y][x]; ++x) layout.centers.emplace_back(std::uint8_t(rows[y][x]), Point{x + shifts[y], double(y)});
    for (const auto& fixture : glides.array()) {
        std::vector<std::string> context; for (const auto& word : fixture["context"].array()) context.push_back(lower(word.text()));
        std::vector<Point> path; for (const auto& point : fixture["points"].array()) path.push_back({point.array()[0].number(), point.array()[1].number()});
        session->beginGlide(context);
        auto ranked = session->updateGlide(path, layout, state->view(), state->dynamicGlideWords()); session->endGlide();
        std::printf("{\"id\":%s,\"suggestions\":[", q(fixture["id"].text()).c_str());
        for (std::size_t k = 0; k < ranked.size() && k < 4; ++k) std::printf("%s%s", k ? "," : "", q(ranked[k].key).c_str());
        std::printf("]}\n");
    }
}
