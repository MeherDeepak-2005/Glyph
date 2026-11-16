#include "../DecoderCore/include/Engine.hpp"
#include "../DecoderCore/include/DictionaryDigest.hpp"
#include <cassert>
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
int main(int argc, char** argv) {
    assert(argc == 4);
    const auto pack = read(argv[1]), sidecar = read(argv[2]), modelBytes = read(argv[3]);
    std::size_t checked = 0;

    const char abc[] = {'a', 'b', 'c'};
    const auto digest = dictionarySHA256(std::as_bytes(std::span(abc)));
    constexpr unsigned char expected[]{0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,
        0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad};
    for (int i = 0; i < 32; ++i) assert(digest[std::size_t(i)] == std::byte(expected[i]));

    for (std::size_t at : {std::size_t(0), std::size_t(8), std::size_t(12), std::size_t(20), std::size_t(24),
                           std::size_t(56), std::size_t(60), sidecar.size() - 1}) {
        auto bad = sidecar; bad[at] ^= std::byte(0xff);
        PackedLexicon lexicon(pack);
        assert(!lexicon.installModern(bad) && !lexicon.hasModern()); ++checked;
    }
    for (std::size_t length : {std::size_t(0), std::size_t(8), std::size_t(55), std::size_t(100)}) {
        PackedLexicon lexicon(pack);
        assert(!lexicon.installModern(std::span(sidecar).first(length)) && !lexicon.hasModern()); ++checked;
    }

    auto packed = std::make_shared<PackedLexicon>(pack);
    assert(!packed->hasModern() && !packed->preserves("rizz") && packed->allowsCorrection("rizz"));
    assert(packed->installModern(sidecar) && packed->hasModern());
    assert(!packed->installModern(sidecar));
    for (const char* word : {"rizz", "pookie", "delulu", "ngl", "lowkey"}) { assert(packed->preserves(word) && !packed->allowsCorrection(word)); ++checked; }
    for (const char* word : {"ate", "cooked", "based", "mid", "slay", "aura", "the", "hello", "xqzzy", ""}) {
        assert(!packed->preserves(word) && packed->allowsCorrection(word)); ++checked;
    }
    assert(!packed->allowsCorrection("hello rizz") && !packed->allowsCorrection("rizz hello") && packed->allowsCorrection("hello there"));

    auto model = NeuralWordModel::load(modelBytes);
    auto engine = std::make_shared<Engine>(packed, model);
    auto bare = std::make_shared<Engine>(std::make_shared<PackedLexicon>(pack), model);
    auto state = engine->createState(), bareState = bare->createState();
    std::uint64_t wordSession = 0;
    auto decode = [&](Engine& with, EngineState& view, const std::string& text, std::vector<std::string> context = {}) {
        DecodeInput input; input.word = input.normalized = text; input.context = std::move(context);
        input.identity = {1, 1, ++wordSession, 1, 1, 0, 0};
        return with.createSession()->decode(input, view.view());
    };
    std::size_t preserved = 0, protectedByPolicy = 0;
    for (std::uint32_t id = 0; id < packed->wordCount(); ++id) {
        const std::string word(packed->word(id));
        if (!packed->preserves(word)) continue;
        ++preserved;
        for (auto context : std::vector<std::vector<std::string>>{{}, {"please", "send"}}) {
            const auto out = decode(*engine, *state, word, context);
            assert(out.status == EngineStatus::ok && !out.correction.word && out.suggestions.front() == word); ++checked;
            if (decode(*bare, *bareState, word, context).correction.word) ++protectedByPolicy;
        }
    }
    assert(preserved >= 40);
    for (const char* text : {"pook", "pooki", "rizzz", "delul", "nggl", "lowky", "risk", "rich", "best", "beast", "pocket",
                             "cooking", "said", "this", "miss", "teh", "recieve", "definately"}) {
        const auto out = decode(*engine, *state, text);
        assert(out.status == EngineStatus::ok && (!out.correction.word || packed->allowsCorrection(*out.correction.word))); ++checked;
    }
    for (const char* text : {"teh", "recieve"}) { assert(decode(*engine, *state, text).correction.word); ++checked; }
    CancellationToken token; token.cancel();
    DecodeInput cancelled; cancelled.word = cancelled.normalized = "rizz";
    assert(engine->createSession()->decode(cancelled, state->view(), &token).status == EngineStatus::cancelled);

    std::cout << "modern vocabulary: " << checked << " checks passed; " << preserved << " preserved spellings, "
              << protectedByPolicy << " decodes the policy kept from autocorrecting\n";
}
