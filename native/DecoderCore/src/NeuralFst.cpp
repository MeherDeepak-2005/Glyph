#include "../include/NeuralFst.hpp"
#include "../include/NssRules.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <unordered_set>
namespace kb {
namespace {
constexpr float negInf = -std::numeric_limits<float>::infinity();
bool letters(std::string_view word) {
    return !word.empty() && std::all_of(word.begin(), word.end(), [](char c) { return (c >= 'a' && c <= 'z') || c == '\''; });
}
}
NeuralLexicon::NeuralLexicon(const PackedLexicon& lex) : packed(lex), trie_(lex.trieData()) {
    terminal.assign(lex.wordCount(), UINT32_MAX);
    parent.assign(std::max<std::size_t>(lex.trieNodeCount(), 1), 0);
    // Packed trie children are contiguous and strictly follow their parent. This one checked
    // walk (trieRecord throws past the last node) covers every node node() can reach.
    std::size_t reach = 1;
    for (std::size_t i = 0; i < reach; ++i) {
        const auto n = lex.trieRecord(i);
        if (n.wordID) {
            if (std::uint32_t(*n.wordID) >= lex.wordCount()) throw std::invalid_argument("invalid trie word ID");
            terminal[std::size_t(*n.wordID)] = std::uint32_t(i);
        }
        const auto end = std::size_t(n.firstChild) + n.childCount;
        if (end > parent.size()) throw std::out_of_range("invalid trie node");
        reach = std::max(reach, end);
        for (auto j = std::size_t(n.firstChild); j < end; ++j) parent[j] = std::uint32_t(i);
    }
    parent.resize(reach); parent.shrink_to_fit();
    for (std::uint32_t w = 0; w < lex.wordCount(); ++w) if (letters(lex.word(w))) mass += double(lex.frequency(w)) + 1;
    unigram.assign(lex.wordCount(), negInf); lookahead.assign(nodeCount(), negInf);
    for (std::uint32_t w = 0; w < lex.wordCount(); ++w) if (letters(lex.word(w))) {
        unigram[w] = float(std::log((double(lex.frequency(w)) + 1) / mass));
        if (terminal[w] != UINT32_MAX) lookahead[terminal[w]] = unigram[w];
    }
    for (std::size_t i = nodeCount(); i-- > 1;) lookahead[parent[i]] = std::max(lookahead[parent[i]], lookahead[i]);
    for (std::uint32_t w = 0; w < lex.wordCount(); ++w) if (std::isfinite(unigram[w]) && terminal[w] != UINT32_MAX) topUnigrams.push_back(w);
    const auto keep = std::min<std::size_t>(64, topUnigrams.size());
    std::partial_sort(topUnigrams.begin(), topUnigrams.begin() + std::ptrdiff_t(keep), topUnigrams.end(),
        [&](auto a, auto b) { return unigram[a] == unigram[b] ? a < b : unigram[a] > unigram[b]; });
    topUnigrams.resize(keep); topUnigrams.shrink_to_fit();
}
void ArcLookahead::build(const NeuralLexicon& lex, std::span<const std::pair<std::uint32_t, float>> wordScores, std::vector<float>& scratch) {
    std::vector<std::uint32_t> touched;
    for (const auto& [word, score] : wordScores) {
        for (auto node = lex.terminal[word];;) {
            if (scratch[node] == negInf) touched.push_back(node);
            else if (scratch[node] >= score) break;   // an ancestor path already holds a better score
            scratch[node] = score;
            if (!node) break;
            node = lex.parent[node];
        }
    }
    std::sort(touched.begin(), touched.end());
    nodes_ = touched; values_.resize(touched.size());
    for (std::size_t i = 0; i < touched.size(); ++i) { values_[i] = scratch[touched[i]]; scratch[touched[i]] = negInf; }
}
float ArcLookahead::at(std::uint32_t node) const {
    auto found = std::lower_bound(nodes_.begin(), nodes_.end(), node);
    return found != nodes_.end() && *found == node ? values_[std::size_t(found - nodes_.begin())] : negInf;
}
NeuralFst::Tables::Tables(std::shared_ptr<const NeuralWordModel> m, std::shared_ptr<const NeuralLexicon> lex, Options o)
    : model(std::move(m)), lexicon(std::move(lex)), options(o) {
    modelToWord.assign(model->vocabularySize(), -1);
    wordToModel.assign(lexicon->unigram.size(), -1);
    for (std::size_t id = 4; id < modelToWord.size(); ++id)
        if (auto word = lexicon->packed.wordID(model->word(std::int32_t(id)))) { modelToWord[id] = *word; wordToModel[std::size_t(*word)] = std::int32_t(id); }
    if (!options.exact) return;
    const auto& lex_ = *lexicon;
    auto outside = [&](std::uint32_t w) { return std::isfinite(lex_.unigram[w]) && wordToModel[w] < 0; };
    // pow(u, 1) is u exactly; skipping it for the shipped exponent saves two passes of pow().
    auto scaled = [&](double u) { return options.unknownExponent == 1 ? u : options.unknownExponent > 0 ? std::pow(u, options.unknownExponent) : 1 + std::log(u); };
    double mass = 0;
    for (std::uint32_t w = 0; w < lex_.unigram.size(); ++w) if (outside(w)) mass += scaled(double(lex_.packed.frequency(w)) + 1);
    outsideMass = mass;
    const double logShare = std::log(double(model->unknownLexiconShare()));
    outsideUnigram.assign(lex_.unigram.size(), negInf); outsideLookahead.assign(lex_.nodeCount(), negInf);
    for (std::uint32_t w = 0; w < lex_.unigram.size(); ++w) if (outside(w)) {
        outsideUnigram[w] = float(logShare + std::log(scaled(double(lex_.packed.frequency(w)) + 1) / mass));
        if (lex_.terminal[w] != UINT32_MAX) { outsideLookahead[lex_.terminal[w]] = outsideUnigram[w]; topOutside.push_back(w); }
    }
    for (std::size_t i = lex_.nodeCount(); i-- > 1;) outsideLookahead[lex_.parent[i]] = std::max(outsideLookahead[lex_.parent[i]], outsideLookahead[i]);
    const auto keep = std::min<std::size_t>(64, topOutside.size());
    std::partial_sort(topOutside.begin(), topOutside.begin() + std::ptrdiff_t(keep), topOutside.end(),
        [&](auto a, auto b) { return outsideUnigram[a] == outsideUnigram[b] ? a < b : outsideUnigram[a] > outsideUnigram[b]; });
    topOutside.resize(keep); topOutside.shrink_to_fit();
    // Every expansion's lookahead covers the same nodes; number them once.
    std::vector<char> marked(lex_.nodeCount());
    for (auto w : modelToWord) if (w >= 0 && lex_.terminal[std::size_t(w)] != UINT32_MAX && std::isfinite(lex_.unigram[std::size_t(w)]))
        for (auto node = lex_.terminal[std::size_t(w)]; !marked[node]; node = lex_.parent[node]) { marked[node] = 1; if (!node) break; }
    vocabularyNode.bits.assign((marked.size() + 63) / 64, 0);
    for (std::size_t node = 0; node < marked.size(); ++node) if (marked[node]) vocabularyNode.bits[node >> 6] |= std::uint64_t(1) << (node & 63);
    vocabularyNode.before.resize(vocabularyNode.bits.size());
    std::uint32_t numbered = 0;
    for (std::size_t block = 0; block < vocabularyNode.bits.size(); ++block) {
        vocabularyNode.before[block] = numbered; numbered += std::uint32_t(std::popcount(vocabularyNode.bits[block]));
    }
    vocabularyParent.reserve(numbered);
    for (std::size_t node = 0; node < marked.size(); ++node) if (marked[node]) vocabularyParent.push_back(vocabularyNode[lex_.parent[node]]);
    vocabularyTerminal.assign(modelToWord.size(), UINT32_MAX);
    for (std::size_t id = 4; id < modelToWord.size(); ++id) if (const auto w = modelToWord[id]; w >= 0 && lex_.terminal[std::size_t(w)] != UINT32_MAX && std::isfinite(lex_.unigram[std::size_t(w)]))
        vocabularyTerminal[id] = vocabularyNode[lex_.terminal[std::size_t(w)]];
}
NeuralFst::NeuralFst(std::shared_ptr<const Tables> tables)
    : tables_(std::move(tables)), model_(tables_->model), lexicon_(tables_->lexicon), options_(tables_->options),
      ring_(std::make_unique<ContextRing>(model_)) {}
void NeuralFst::resetContext() { ring_ = std::make_unique<ContextRing>(model_); context_.clear(); states_.clear(); }
void NeuralFst::update(std::span<const std::string> context, bool newWord) {
    std::vector<std::int32_t> ids;
    for (const auto& word : context) if (auto id = model_->contextID(word); id >= 0) ids.push_back(id);
    if (!states_.empty() && ids == context_) {
        if (!newWord) return;
        // Same committed context: restore the initial graph by truncating its
        // arenas. Reuse the already computed UpdateLM distribution, without an
        // additional dense inference or reconstruction of thousands of arcs.
        const auto count = expansions_[0].count;
        arcs_.resize(count); states_.resize(count + 2); expansions_.resize(1);
        for (std::size_t i = 2; i < states_.size(); ++i) states_[i].expansion = SIZE_MAX;
        extensions_ = 0; ++revision_; ++updates_; return;
    }
    ring_->sync(ids); context_ = std::move(ids);
    arcs_.clear(); states_.clear(); expansions_.clear(); extensions_ = 0;
    states_.push_back({0, 0, SIZE_MAX}); states_.push_back({1, 0, SIZE_MAX});
    modify(0, ring_->state(), ring_->features(), nssUpdateThreshold);
    ++revision_; ++updates_;
}
void NeuralFst::modify(std::uint32_t state, std::span<const float> recurrent, std::span<const float> features, float threshold) {
    std::vector<float> probabilities(model_->vocabularySize());
    model_->wordLogProbabilities(features, probabilities);
    Expansion e;
    e.begin = arcs_.size(); e.epsilon = probabilities[std::size_t(model_->unknown())];
    e.recurrent.assign(recurrent.begin(), recurrent.end());
    std::vector<std::pair<std::uint32_t, float>> scored;
    for (std::size_t id = 4; id < probabilities.size(); ++id) {
        if (probabilities[id] < threshold || tables_->modelToWord[id] < 0) continue;
        const auto word = std::uint32_t(tables_->modelToWord[id]);
        if (lexicon_->terminal[word] == UINT32_MAX || !std::isfinite(lexicon_->unigram[word])) continue;
        const auto next = std::uint32_t(states_.size());
        states_.push_back({state, word, SIZE_MAX});
        arcs_.push_back({word, next, probabilities[id]});
        if (!options_.exact) scored.emplace_back(word, probabilities[id]);
    }
    if (options_.exact) {
        // Each word's score at its terminal, then up the tree; parents are numbered first.
        auto& best = e.vocabularyLookahead;
        best.assign(tables_->vocabularyParent.size(), negInf);
        for (std::size_t id = 4; id < probabilities.size(); ++id) if (const auto at = tables_->vocabularyTerminal[id]; at != UINT32_MAX) best[at] = std::max(best[at], probabilities[id]);
        for (std::size_t at = best.size(); at-- > 1;) best[tables_->vocabularyParent[at]] = std::max(best[tables_->vocabularyParent[at]], best[at]);
        e.distribution = std::move(probabilities);
    } else {
        if (scratch_.empty()) scratch_.assign(lexicon_->nodeCount(), negInf);   // exact mode never needs it
        e.lookahead.build(*lexicon_, scored, scratch_);
    }
    e.count = arcs_.size() - e.begin;
    std::sort(arcs_.begin() + std::ptrdiff_t(e.begin), arcs_.end(), [](const auto& a, const auto& b) { return a.word < b.word; });
    states_[state].expansion = expansions_.size(); expansions_.push_back(std::move(e));
}
bool NeuralFst::expanded(std::uint32_t state) const { return state == 1 || states_.at(state).expansion != SIZE_MAX; }
void NeuralFst::extend(std::uint32_t state) {
    if (expanded(state)) return;
    const auto s = states_.at(state);
    auto recurrent = expansions_.at(states_.at(s.parent).expansion).recurrent;
    std::vector<float> features(model_->featureSize());
    model_->step(model_->contextID(lexicon_->packed.word(s.word)), recurrent, recurrent, features);
    modify(state, recurrent, features, nssExtendThreshold); ++extensions_;
}
std::vector<NeuralFst::Transition> NeuralFst::transitions(std::uint32_t state, std::uint32_t word) const {
    if (state == 1) return {{1, lexicon_->unigram[word]}};
    const auto index = states_.at(state).expansion;
    if (index == SIZE_MAX) return {{1, lexicon_->unigram[word]}};
    const auto& e = expansions_[index];
    auto first = arcs_.begin() + std::ptrdiff_t(e.begin), last = first + std::ptrdiff_t(e.count);
    auto found = std::lower_bound(first, last, word, [](const Arc& a, auto w) { return a.word < w; });
    if (options_.exact) {
        const auto id = tables_->wordToModel[word];
        if (id < 0) return {{1, double(e.epsilon) + tables_->outsideUnigram[word]}};
        const double floor = options_.unigramFloor ? double(e.epsilon) + lexicon_->unigram[word] : double(negInf);
        if (found == last || found->word != word) return {{1, std::max(floor, double(e.distribution[std::size_t(id)]))}};
        if (options_.unigramFloor) return {{1, floor}, {found->next, found->logProbability}};
        return {{found->next, found->logProbability}};
    }
    std::vector<Transition> out{{1, double(e.epsilon) + lexicon_->unigram[word]}};
    if (found != last && found->word == word) out.push_back({found->next, found->logProbability});
    return out;
}
double NeuralFst::wordScore(std::uint32_t state, std::uint32_t word) const {
    double best = negInf;
    for (const auto& t : transitions(state, word)) best = std::max(best, t.logProbability);
    return best;
}
double NeuralFst::lookahead(std::uint32_t state, std::uint32_t node) const {
    const auto index = state == 1 ? SIZE_MAX : states_.at(state).expansion;
    if (index == SIZE_MAX) return lexicon_->lookahead[node];
    const auto& e = expansions_[index];
    if (options_.exact) {
        const auto at = tables_->vocabularyNode[node];
        const double bound = std::max(double(e.epsilon) + tables_->outsideLookahead[node], at == UINT32_MAX ? double(negInf) : double(e.vocabularyLookahead[at]));
        return options_.unigramFloor ? std::max(bound, double(e.epsilon) + lexicon_->lookahead[node]) : bound;
    }
    return std::max(double(e.epsilon) + lexicon_->lookahead[node], double(e.lookahead.at(node)));
}
std::vector<std::pair<std::uint32_t, double>> NeuralFst::best(std::uint32_t state, std::size_t count) const {
    std::vector<std::pair<std::uint32_t, double>> out;
    const auto index = state == 1 ? SIZE_MAX : states_.at(state).expansion;
    auto order = [](const auto& a, const auto& b) { return a.second == b.second ? a.first < b.first : a.second > b.second; };
    if (options_.exact && index != SIZE_MAX) {
        const auto& e = expansions_[index];
        for (std::size_t id = 4; id < e.distribution.size(); ++id) if (const auto w = tables_->modelToWord[id]; w >= 0 && lexicon_->terminal[std::size_t(w)] != UINT32_MAX && std::isfinite(lexicon_->unigram[std::size_t(w)]))
            out.emplace_back(std::uint32_t(w), options_.unigramFloor ? std::max(double(e.distribution[id]), double(e.epsilon) + lexicon_->unigram[std::size_t(w)]) : double(e.distribution[id]));
        for (std::size_t k = 0; k < tables_->topOutside.size() && k < count; ++k) out.emplace_back(tables_->topOutside[k], double(e.epsilon) + tables_->outsideUnigram[tables_->topOutside[k]]);
        if (out.size() > count) { std::partial_sort(out.begin(), out.begin() + std::ptrdiff_t(count), out.end(), order); out.resize(count); }
        else std::sort(out.begin(), out.end(), order);
        return out;
    }
    std::span<const Arc> arcs;
    double epsilon = 0;
    if (index != SIZE_MAX) {
        const auto& e = expansions_[index];
        arcs = std::span<const Arc>(arcs_).subspan(e.begin, e.count); epsilon = e.epsilon;
        for (const auto& arc : arcs) out.emplace_back(arc.word, std::max(double(arc.logProbability), epsilon + lexicon_->unigram[arc.word]));
    }
    // Any other word only has the unigram path, best for the most frequent words.
    std::size_t added = 0;
    for (auto word : lexicon_->topUnigrams) {
        if (added == count) break;
        auto found = std::lower_bound(arcs.begin(), arcs.end(), word, [](const Arc& a, auto w) { return a.word < w; });
        if (found != arcs.end() && found->word == word) continue;
        out.emplace_back(word, epsilon + lexicon_->unigram[word]); ++added;
    }
    if (out.size() > count) { std::partial_sort(out.begin(), out.begin() + std::ptrdiff_t(count), out.end(), order); out.resize(count); }
    else std::sort(out.begin(), out.end(), order);
    return out;
}
NeuralFst::Stats NeuralFst::stats() const { return {updates_, extensions_, arcs_.size(), states_.size()}; }
double NeuralFst::typedUnknown() const {
    const auto index = states_.empty() ? SIZE_MAX : states_[0].expansion;
    if (!options_.exact || index == SIZE_MAX) return negInf;
    // Half a count, scaled like the lexicon's counts (1 + ln 0.5 < 1 would be below any word: use 0.5^0 = 1 there).
    const double half = options_.unknownExponent > 0 ? std::pow(0.5, options_.unknownExponent) : 1.0;
    return double(expansions_[index].epsilon) + std::log(1 - double(model_->unknownLexiconShare())) + std::log(half / tables_->outsideMass);
}

double NeuralFstSearch::bound(const Token& t) const {
    return t.language + graph_.lookahead(t.state, t.node) - options_.channelWeight * t.cost;
}

void NeuralFstSearch::reset() { lastLetter_ = 0; beam_.clear(); complete_.clear(); completeRows_.clear(); typed_.clear(); taps_.clear(); revision_ = graph_.revision(); }
std::vector<NeuralFstSearch::Token> NeuralFstSearch::prune(std::vector<Token> input, bool deletions) {
    auto order = [&](const Token& a, const Token& b) {
        auto x = a.upper, y = b.upper;
        if (x != y) return x < y;
        return std::tie(a.prefix, a.state, a.node, a.pending, a.boundary) > std::tie(b.prefix, b.state, b.node, b.pending, b.boundary);
    };
    // Recombine before selecting the beam. Queue comparisons then use cached
    // lookahead, avoiding repeated hash lookups for every heap comparison.
    struct Key {
        std::uint32_t node, state; std::string prefix; std::uint8_t pending; bool boundary;
        bool operator==(const Key&) const = default;
    };
    struct Hash { std::size_t operator()(const Key& k) const {
        return std::hash<std::string>{}(k.prefix) ^ (std::size_t(k.node) * 0x9e3779b1u) ^
            (std::size_t(k.state) * 0x85ebca6bu) ^ (std::size_t(k.pending) << 2) ^ std::size_t(k.boundary);
    }};
    auto keyOf = [](const Token& t) { return Key{t.node, t.state, t.prefix, t.pending, t.boundary}; };
    std::unordered_map<Key, std::size_t, Hash> positions; positions.reserve(input.size());
    std::vector<Token> unique; unique.reserve(input.size());
    for (auto& t : input) {
        t.upper = bound(t);
        auto [it, fresh] = positions.emplace(keyOf(t), unique.size());
        if (fresh) unique.push_back(std::move(t));
        else if (t.upper > unique[it->second].upper) unique[it->second] = std::move(t);
    }
    if (unique.size() > options_.width) {
        std::nth_element(unique.begin(), unique.begin() + std::ptrdiff_t(options_.width), unique.end(),
            [&](const auto& a, const auto& b) { return order(b, a); });
        unique.resize(options_.width);
    }
    std::priority_queue<Token, std::vector<Token>, decltype(order)> queue(order, std::move(unique));
    if (queue.empty()) return {};
    const auto floor = queue.top().upper - options_.beam;
    std::unordered_set<Key, Hash> seen; seen.reserve(options_.width);
    std::vector<Token> out;
    const auto& lex = graph_.lexicon();
    while (!queue.empty() && out.size() < options_.width) {
        auto t = queue.top(); queue.pop();
        if (t.upper < floor || !std::isfinite(t.upper)) break;
        if (!seen.insert(keyOf(t)).second) continue;
        out.push_back(t);
        if (!deletions || t.pending) continue;
        const auto node = lex.node(t.node);
        const std::uint8_t previous = t.node ? node.label : 0;
        for (auto child = node.firstChild; child < node.firstChild + node.childCount; ++child) {
            auto next = t; next.node = child; next.boundary = false;
            next.cost += nssDeletionCost(lex.node(child).label, previous, lastLetter_);
            next.upper = bound(next);
            if (next.upper >= floor) queue.push(std::move(next));
        }
    }
    return out;
}
std::vector<NeuralFstSearch::End> NeuralFstSearch::endings(std::span<const Token> tokens) const {
    std::vector<End> out;
    const auto& lex = graph_.lexicon();
    for (const auto& t : tokens) {
        const auto word = lex.node(t.node).wordID;
        if (t.pending || !word || lex.packed.blocked(std::uint32_t(*word))) continue;
        for (const auto& edge : graph_.transitions(t.state, std::uint32_t(*word)))
            out.push_back({t, std::uint32_t(*word), edge.next, t.language + edge.logProbability});
    }
    return out;
}
void NeuralFstSearch::advance(std::uint8_t letter, std::optional<TouchOffset> tap) {
    const auto& lex = graph_.lexicon();
    std::vector<Token> next;
    for (const auto& t : beam_) {
        if (t.pending) {
            auto done = t; done.pending = 0;
            done.cost += nssSubstitutionCost(t.pending, letter, tap); next.push_back(std::move(done)); continue;
        }
        auto extra = t;
        extra.cost += nssInsertionCost(letter, lastLetter_, t.node ? lex.node(t.node).label : 0);
        next.push_back(std::move(extra));
        // A space key replaced by c/v/b/n/m consumes a touch without a lexicon letter.
        if (t.boundary && std::string_view("cvbnm").find(char(letter)) != std::string_view::npos) {
            auto space = t; space.boundary = false; space.cost += 0.72 - 1.1; next.push_back(std::move(space));
        }
        const auto n = lex.node(t.node);
        for (auto child = n.firstChild; child < n.firstChild + n.childCount; ++child) {
            const auto c = lex.node(child);
            auto sub = t; sub.node = child; sub.boundary = false;
            sub.cost += nssSubstitutionCost(c.label, letter, tap); next.push_back(std::move(sub));
            // Two-label channel arc for adjacent transposition. The pending input is
            // consumed on the next frame, so no unfinished transposition can emit a word.
            for (auto grand = c.firstChild; grand < c.firstChild + c.childCount; ++grand) if (lex.node(grand).label == letter && c.label != letter) {
                auto swap = t; swap.node = grand; swap.pending = c.label; swap.boundary = false;
                swap.cost += transpositionCost; next.push_back(std::move(swap));
            }
        }
    }
    lastLetter_ = letter;   // deletions after this frame follow this typed letter
    beam_ = prune(std::move(next), true);
    auto ends = endings(beam_);
    std::stable_sort(ends.begin(), ends.end(), [this](const End& a, const End& b) {
        auto x = a.language - options_.channelWeight * a.token.cost, y = b.language - options_.channelWeight * b.token.cost;
        return x == y ? std::tie(a.next, a.word, a.token.prefix) < std::tie(b.next, b.word, b.token.prefix) : x > y;
    });
    expandedLastFrame_ = 0;
    for (const auto& e : ends) {
        if (e.language - options_.channelWeight * e.token.cost <= nssExpansionThreshold) break;
        if (!graph_.expanded(e.next)) {
            graph_.extend(e.next);
            if (++expandedLastFrame_ == nssExpansionsPerFrame) break;
        }
    }
    for (const auto& e : ends) {
        // No zero-input word loops: boundaries are created only after consuming a frame.
        auto root = e.token; root.node = 0; root.state = e.next; root.language = e.language;
        root.prefix += std::string(lex.packed.word(e.word)) + ' '; root.cost += 1.1; root.boundary = true;
        beam_.push_back(std::move(root));
    }
    beam_ = prune(std::move(beam_), false);
}
std::vector<RankedRow> NeuralFstSearch::decode(std::string_view typed, std::span<const std::optional<TouchOffset>> taps,
                                            const std::function<bool()>& cancelled) {
    if (!letters(typed)) { reset(); return {}; }
    bool reuse = revision_ == graph_.revision() && typed.starts_with(typed_);
    if (reuse) for (std::size_t k = 0; k < typed_.size(); ++k) {
        auto a = taps.size() == typed.size() ? taps[k] : std::nullopt, b = taps_[k];
        if (a.has_value() != b.has_value() || (a && (a->dx != b->dx || a->dy != b->dy))) { reuse = false; break; }
    }
    if (!reuse || beam_.empty()) { reset(); beam_ = prune({Token{}}, true); }
    for (std::size_t k = typed_.size(); k < typed.size(); ++k) {
        if (cancelled && cancelled()) { reset(); return {}; }
        const auto tap = taps.size() == typed.size() ? taps[k] : std::nullopt;
        advance(std::uint8_t(typed[k]), tap); typed_ += typed[k]; taps_.push_back(tap);
    }
    auto ends = endings(beam_);
    complete_.clear();
    for (const auto& e : ends) complete_.insert(e.token.prefix + std::string(graph_.lexicon().packed.word(e.word)));
    std::unordered_map<std::string, RankedRow> full;
    for (const auto& e : ends) {
        auto phrase = e.token.prefix + std::string(graph_.lexicon().packed.word(e.word));
        RankedRow row{{phrase, e.token.cost, 0}, phrase, 0, e.language, e.language - options_.channelWeight * e.token.cost, {}};
        auto [it, fresh] = full.emplace(phrase, row);
        if (!fresh && row.score > it->second.score) it->second = row;
    }
    completeRows_.clear();
    for (auto& [word, row] : full) { (void)word; completeRows_.push_back(std::move(row)); }
    // Completion is a final, non-mutating epsilon traversal. It uses neural/spatial
    // bounds, never a frequency-only completion cap, and cannot feed boundary expansion.
    auto completion = beam_;
    for (auto& t : completion) { t.boundary = false; t.upper = bound(t); }
    auto order = [&](const Token& a, const Token& b) {
        return a.upper == b.upper ? std::tie(a.prefix, a.state, a.node) > std::tie(b.prefix, b.state, b.node) : a.upper < b.upper;
    };
    std::priority_queue<Token, std::vector<Token>, decltype(order)> queue(order, std::move(completion));
    std::unordered_map<std::string, double> resultScores;
    auto remember = [&](const End& e) {
        auto key = e.token.prefix + std::string(graph_.lexicon().packed.word(e.word));
        auto score = e.language - options_.channelWeight * e.token.cost;
        auto [it, fresh] = resultScores.emplace(std::move(key), score);
        if (!fresh) it->second = std::max(it->second, score);
    };
    for (const auto& e : ends) remember(e);
    double floor = queue.empty() ? negInf : queue.top().upper - options_.beam;
    auto tighten = [&] {
        if (resultScores.size() < 24) return;
        std::vector<double> scores; scores.reserve(resultScores.size());
        for (const auto& [word, score] : resultScores) { (void)word; scores.push_back(score); }
        std::nth_element(scores.begin(), scores.begin() + 23, scores.end(), std::greater<>());
        floor = std::max(floor, scores[23]);
    };
    tighten();
    std::unordered_set<std::string> visited;
    while (!queue.empty()) {
        if (cancelled && cancelled()) { reset(); return {}; }
        auto t = queue.top(); queue.pop(); if (t.upper < floor) break;
        if (t.pending || t.node == 0) continue;
        auto key = t.prefix + '\t' + std::to_string(t.state) + ':' + std::to_string(t.node);
        if (!visited.insert(std::move(key)).second) continue;
        for (const auto& e : endings(std::span<const Token>(&t, 1))) {
            remember(e); ends.push_back(e);
        }
        if (visited.size() % 16 == 0) tighten();
        const auto node = graph_.lexicon().node(t.node);
        for (auto c = node.firstChild; c < node.firstChild + node.childCount; ++c) {
            auto child = t; child.node = c; child.upper = bound(child);
            if (child.upper >= floor) queue.push(std::move(child));
        }
    }
    std::unordered_map<std::string, RankedRow> best;
    for (std::size_t i = 0; i < ends.size(); ++i) {
        const auto& e = ends[i];
        auto phrase = e.token.prefix + std::string(graph_.lexicon().packed.word(e.word));
        RankedRow row{{phrase, e.token.cost, 0}, phrase, 0, e.language, e.language - options_.channelWeight * e.token.cost, {}};
        auto [it, fresh] = best.emplace(phrase, row); if (!fresh && row.score > it->second.score) it->second = std::move(row);
    }
    std::vector<RankedRow> out;
    for (auto& [word, row] : best) { (void)word; out.push_back(std::move(row)); }
    std::sort(out.begin(), out.end(), [](const auto& a, const auto& b) { return a.score == b.score ? a.key < b.key : a.score > b.score; });
    return out;
}
} // namespace kb
