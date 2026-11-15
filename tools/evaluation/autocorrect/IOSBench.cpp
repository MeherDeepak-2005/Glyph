// iOSKeyboard side of the autocorrect/suggestion comparison (27 Oct 2026), on the shipped
// decoder: the neural search space over langdata.bin (EngineOptions{}: exact scores with the
// unigram floor), safety.kbguard penalties via EngineState. Context words follow
// KeyboardViewController.contextWords(_:max: 8): word characters are letters and
// apostrophes, stop at . ! ? or newline, lowercased like DecodeContract.
// No personalization. Simulated taps come from an optional sixth column (make_taps.py).
//
// KB_NSS=model.nsslm (required) is mapped read-only like langdata.bin. Variants of the graph
// for experiments: KB_NSS_PAPER=1 the published graph's fallback and arc-only scores,
// KB_NSS_FLOOR=0 exact scores without the unigram floor, KB_NSS_ALPHA=a unknown-word
// frequencies as u^a, KB_NSS_TYPED=1 typed text outside the lexicon scored from P(<unk>).
//
// Same TSV/JSONL contract as CoreBench.cpp.
#include <string>
#include <vector>
#include <iterator>
#include "Engine.hpp"
#include "Safety.hpp"
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cctype>
#include <fstream>
#include <iostream>
#include <sstream>
#include <fcntl.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/resource.h>
using namespace kb;
using Clock = std::chrono::steady_clock;
static double ms(Clock::time_point a, Clock::time_point b) { return std::chrono::duration<double, std::milli>(b - a).count(); }
static std::string quote(const std::string& s) {
    std::string r = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') r += '\\';
        if (c < 0x20) continue;
        r += char(c);
    }
    return r + '"';
}
static std::string slurp(const std::string& path) { std::ifstream in(path, std::ios::binary); std::stringstream out; out << in.rdbuf(); return out.str(); }
static std::string lower(std::string text) { for (auto& c : text) if (static_cast<unsigned char>(c) < 0x80) c = char(std::tolower(static_cast<unsigned char>(c))); return text; }
static std::vector<std::size_t> boundaries(std::string_view text) {
    std::vector<std::size_t> out{0};
    for (std::size_t i = 0; i < text.size();) {
        auto c = static_cast<unsigned char>(text[i]); std::size_t n = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
        bool combining = n == 2 && (c == 0xcc || (c == 0xcd && static_cast<unsigned char>(text[i + 1]) < 0xb0));
        i += n; if (combining && out.size() > 1) out.back() = i; else out.push_back(i);
    }
    return out;
}
static bool wordChar(unsigned char c) { return std::isalpha(c) || c == '\'' || c >= 0x80; }
static std::vector<std::string> contextWords(const std::string& s, std::size_t max = 8) {
    std::vector<std::string> words; std::size_t end = s.size();
    while (end && wordChar(s[end - 1])) --end;   // drop trailing partial (none: context ends before the word)
    while (words.size() < max) {
        while (end && !wordChar(s[end - 1])) { char c = s[end - 1]; if (c == '.' || c == '!' || c == '?' || c == '\n') return words; --end; }
        if (!end) break;
        std::size_t start = end; while (start && wordChar(s[start - 1])) --start;
        words.insert(words.begin(), lower(s.substr(start, end - start))); end = start;
    }
    return words;
}
static DecodeInput makeInput(const std::string& typed, const std::vector<std::string>& context, std::uint64_t word, std::uint64_t gen) {
    DecodeInput in; in.word = typed; in.normalized = lower(typed); in.context = context;
    in.identity = {1, word, word, gen, 1, 0, 0};
    return in;
}
// Same rule as CoreBench.cpp: rank among the first three non-literal entries.
static int rankOf(const std::vector<std::string>& list, const std::string& prefix, const std::string& target) {
    int slot = 0;
    for (const auto& w : list) {
        auto l = lower(w);
        if (l == prefix) continue;
        if (slot == 3) break;
        if (l == target) return slot;
        ++slot;
    }
    return -1;
}
static void words(std::ostream& o, const std::vector<std::string>& w) {
    o << '['; for (std::size_t i = 0; i < w.size(); ++i) { if (i) o << ','; o << quote(w[i]); } o << ']';
}
static void processRecord(std::ostream& out, const char* label) {
    rusage usage{}; getrusage(RUSAGE_SELF, &usage);
    task_vm_info_data_t info{}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count);
    // heap_in_use = live malloc bytes; footprint minus it is allocator-retained and other dirty memory.
    malloc_statistics_t heap{}; malloc_zone_statistics(nullptr, &heap);
    out << "{\"kind\":\"process\",\"at\":" << quote(label) << ",\"peak_rss_bytes\":" << usage.ru_maxrss
        << ",\"footprint_bytes\":" << info.phys_footprint << ",\"heap_in_use_bytes\":" << heap.size_in_use
        << ",\"heap_allocated_bytes\":" << heap.size_allocated << "}\n";
}
// The spelling policies that ship beside the dictionary (langdata.kbmodern), installed as the
// extension installs them (LangData.swift). A dictionary without the sidecar runs without.
static void installPolicies(const PackedLexicon& lexicon, std::string path) {
    if (auto dot = path.rfind('.'); dot != std::string::npos) path.resize(dot);
    std::ifstream in(path + ".kbmodern", std::ios::binary);
    if (!in) return;
    std::vector<char> sidecar((std::istreambuf_iterator<char>(in)), {});
    lexicon.installModern({reinterpret_cast<const std::byte*>(sidecar.data()), sidecar.size()});
}
int main(int argc, char** argv) {
    if (argc < 5) { std::cerr << "langdata.bin safety.kbguard cases.tsv output.jsonl\n"; return 2; }
    std::ofstream out(argv[4]);
    auto initStart = Clock::now();
    // Mapped read-only, as the extension maps it.
    int fd = open(argv[1], O_RDONLY); struct stat st{}; fstat(fd, &st);
    void* data = mmap(nullptr, std::size_t(st.st_size), PROT_READ, MAP_PRIVATE, fd, 0); close(fd);
    if (data == MAP_FAILED) { std::cerr << "cannot map " << argv[1] << "\n"; return 3; }
    auto reader = std::shared_ptr<const PackedLexicon>(new PackedLexicon({static_cast<const std::byte*>(data), std::size_t(st.st_size)}));
    installPolicies(*reader, argv[1]);
    EngineOptions options;
    if (std::getenv("KB_NSS_PAPER") && std::string(std::getenv("KB_NSS_PAPER")) == "1") options.nssExact = false;
    if (std::getenv("KB_NSS_FLOOR") && std::string(std::getenv("KB_NSS_FLOOR")) == "0") options.nssUnigramFloor = false;
    if (const char* alpha = std::getenv("KB_NSS_ALPHA")) options.nssUnknownExponent = std::atof(alpha);
    if (std::getenv("KB_NSS_TYPED") && std::string(std::getenv("KB_NSS_TYPED")) == "1") options.nssTypedUnknown = true;
    const char* path = std::getenv("KB_NSS");
    if (!path) { std::cerr << "KB_NSS=model.nsslm is required\n"; return 2; }
    int nfd = open(path, O_RDONLY); struct stat nst{}; fstat(nfd, &nst);
    void* bytes = mmap(nullptr, std::size_t(nst.st_size), PROT_READ, MAP_PRIVATE, nfd, 0); close(nfd);
    if (bytes == MAP_FAILED) { std::cerr << "cannot map " << path << "\n"; return 3; }
    auto neural = NeuralWordModel::load({static_cast<const std::byte*>(bytes), std::size_t(nst.st_size)});
    auto engine = std::make_shared<Engine>(reader, neural, options); auto state = engine->createState();
    state->setSafety(parseSafetyPenalties(slurp(argv[2])));
    auto session = engine->createSession();
    out << "{\"kind\":\"startup\",\"engine\":\"ioskeyboard\",\"tier\":\"nss\",\"words\":" << reader->wordCount() << ",\"startup_ms\":" << ms(initStart, Clock::now()) << "}\n";
    processRecord(out, "after_startup");
    std::ifstream f(argv[3]); std::string line; std::size_t events = 0; std::uint64_t wordID = 0, gen = 0;
    const bool dump = std::getenv("KB_DUMP") && std::string(std::getenv("KB_DUMP")) == "1";
    while (std::getline(f, line)) {
        std::vector<std::string> p; std::size_t s = 0;
        for (std::size_t i = 0; i <= line.size(); ++i) if (i == line.size() || line[i] == '\t') { p.push_back(line.substr(s, i - s)); s = i + 1; }
        // Optional sixth column: one simulated tap per typed character, "dx,dy" in key widths
        // from that key's centre, ';'-separated ("-" = none); see make_taps.py.
        if (p.size() != 5 && p.size() != 6) continue;
        std::vector<std::optional<TouchOffset>> taps;
        if (p.size() == 6) for (std::size_t at = 0; at <= p[5].size();) {
            auto end = std::min(p[5].find(';', at), p[5].size()); auto cell = p[5].substr(at, end - at);
            double dx = 0, dy = 0;
            if (cell != "-" && std::sscanf(cell.c_str(), "%lf,%lf", &dx, &dy) == 2) taps.push_back(TouchOffset{dx, dy}); else taps.push_back(std::nullopt);
            at = end + 1;
        }
        const std::string &id = p[0], &kind = p[1], &raw = p[2], &typed = p[3], target = lower(p[4]);
        if (events && events % 10000 == 0) processRecord(out, ("after_" + std::to_string(events)).c_str());
        ++events; ++wordID; auto context = contextWords(raw + " ");   // the word starts after a space
        if (kind == "ac") {
            auto view = state->view(); auto t = Clock::now();
            auto in = makeInput(typed, context, wordID, ++gen);
            if (taps.size() + 1 == boundaries(in.normalized).size()) in.taps = taps;   // one tap per character
            auto r = session->decode(in, view);
            double elapsed = ms(t, Clock::now());
            out << "{\"id\":" << quote(id) << ",\"s\":"; words(out, r.suggestions);
            out << ",\"c\":" << (r.correction.word ? quote(*r.correction.word) : "null") << ",\"ms\":" << elapsed
                << ",\"ok\":" << (r.status == EngineStatus::ok ? 1 : 0);
            // KB_DUMP=1: the ranked rows (word, channel cost, language, log frequency, score) for offline reranking.
            if (dump) {
                out << ",\"rows\":[";
                for (std::size_t i = 0; i < r.candidates.size(); ++i) {
                    const auto& row = r.candidates[i].ranked;
                    out << (i ? "," : "") << '[' << quote(row.channel.word) << ',' << row.channel.cost << ',' << row.language << ','
                        << row.channel.logFrequency << ',' << row.score << ',' << int(r.candidates[i].source) << ']';
                }
                out << ']';
            }
            out << "}\n";
            continue;
        }
        int r0 = -1, kfound = -1; bool ok = true; double ms0 = 0; std::vector<double> lat; std::vector<std::string> first;
        for (std::size_t k = 0; k < target.size() || k < 2; ++k) {
            if (k > target.size()) break;
            auto view = state->view(); auto t = Clock::now();
            auto r = session->decode(makeInput(target.substr(0, k), context, wordID, ++gen), view);
            double elapsed = ms(t, Clock::now());
            ok = ok && r.status == EngineStatus::ok;
            int rank = k < target.size() ? rankOf(r.suggestions, target.substr(0, k), target) : -1;
            if (k == 0) { r0 = rank; ms0 = elapsed; first = r.suggestions; } else lat.push_back(elapsed);
            if (rank >= 0 && kfound < 0) kfound = int(k);
            // Fixed-prefix latency replay must not stop at a decoder-dependent
            // suggestion rank. Default quality/keystroke-savings replay is unchanged.
            if (kfound >= 0 && k >= 1 && !std::getenv("KB_FULL_PREFIXES")) break;
        }
        if (kfound < 0) kfound = int(target.size());
        out << "{\"id\":" << quote(id) << ",\"r0\":" << r0 << ",\"kf\":" << kfound << ",\"len\":" << target.size() << ",\"s0\":"; words(out, first);
        out << ",\"ms0\":" << ms0 << ",\"msk\":["; for (std::size_t i = 0; i < lat.size(); ++i) out << (i ? "," : "") << lat[i];
        out << "],\"ok\":" << (ok ? 1 : 0) << "}\n";
    }
    processRecord(out, "end");
    out << "{\"kind\":\"nss\",\"model_steps\":" << session->neuralSteps() << "}\n";
    out << "{\"kind\":\"done\",\"events\":" << events << "}\n";
    return 0;
}
