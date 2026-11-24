// For each "typed<TAB>word" line, print the engine's lookup values for the word as a candidate:
// word, allow, mid, lex, out, uni, sameSound, firstLetterCost, blocked  (same fields as IOSBench's "tg").
#include "Engine.hpp"
#include "Safety.hpp"
#include "NssRules.hpp"
#include <cmath>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <sstream>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
using namespace kb;
static std::span<const std::byte> map(const char* path) {
    int fd = open(path, O_RDONLY); struct stat st{}; fstat(fd, &st);
    void* data = mmap(nullptr, std::size_t(st.st_size), PROT_READ, MAP_PRIVATE, fd, 0); close(fd);
    return {static_cast<const std::byte*>(data), std::size_t(st.st_size)};
}
int main(int argc, char** argv) {
    if (argc < 4) { std::cerr << "langdata.bin safety.kbguard model.nsslm < pairs.tsv\n"; return 2; }
    auto reader = std::shared_ptr<const PackedLexicon>(new PackedLexicon(map(argv[1])));
    {
        std::string path = argv[1]; path.resize(path.rfind('.'));
        std::ifstream in(path + ".kbmodern", std::ios::binary);
        if (in) { static std::vector<char> side((std::istreambuf_iterator<char>(in)), {}); reader->installModern({reinterpret_cast<const std::byte*>(side.data()), side.size()}); }
    }
    auto neural = NeuralWordModel::load(map(argv[3]));
    EngineOptions options;
    auto engine = std::make_shared<Engine>(reader, neural, options); auto state = engine->createState();
    std::ifstream sf(argv[2]); std::stringstream ss; ss << sf.rdbuf();
    state->setSafety(parseSafetyPenalties(ss.str()));
    auto view = state->view();
    auto lexicon = std::make_shared<NeuralLexicon>(*reader);
    NeuralFst::Tables tables(neural, lexicon, {options.nssExact, options.nssUnigramFloor, options.nssUnknownExponent});
    UnigramModel unigram(*reader);
    auto num = [](double v) { return std::isfinite(v) ? v : -1e30; };
    std::ios::sync_with_stdio(false);
    std::string line;
    while (std::getline(std::cin, line)) {
        auto tab = line.find('\t'); if (tab == std::string::npos) continue;
        std::string typed = line.substr(0, tab), word = line.substr(tab + 1);
        auto lex = reader->wordID(word);
        int mid = lex ? tables.wordToModel[std::size_t(*lex)] : -1;
        int same = 0;
        if (typed.size() >= 4 && word.find_first_of(" '") == std::string::npos) {
            auto a = nssSpellingSkeleton(typed); same = !a.empty() && a == nssSpellingSkeleton(word);
        }
        std::cout << word << '\t' << (reader->allowsCorrection(word) ? 1 : 0) << '\t' << mid << '\t'
                  << num(lex ? lexicon->unigram[std::size_t(*lex)] : -INFINITY) << '\t'
                  << num(lex && !tables.outsideUnigram.empty() ? tables.outsideUnigram[std::size_t(*lex)] : -INFINITY) << '\t'
                  << num(unigram.logProbability(word)) << '\t' << same << '\t' << nssFirstLetterCost(typed, word) << '\t'
                  << (view.lexicon.isBlocked(word) ? 1 : 0) << '\n';
    }
}
