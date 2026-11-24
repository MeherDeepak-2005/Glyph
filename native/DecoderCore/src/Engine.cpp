#include "../include/Engine.hpp"
#include "../include/NssRules.hpp"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <limits>
#include <stdexcept>
namespace kb {
namespace {
const PersonalCounts emptyCounts;
const PersonalCounts& counts(const EngineView& view) { return view.personal ? *view.personal : emptyCounts; }
void placeDecision(DecodeOutput& out, const DecodeInput& input) {
    if (out.correction.word) {
        std::erase(out.suggestions, *out.correction.word); out.suggestions.insert(out.suggestions.begin(), *out.correction.word);
    } else {
        std::erase(out.suggestions, input.normalized); std::erase(out.suggestions, input.word);
        out.suggestions.insert(out.suggestions.begin(), input.word);
    }
    if (out.suggestions.size() > 3) out.suggestions.resize(3);
}
}
double EngineView::penalty(std::string_view word) const {
    if (penalties && !penalties->empty()) if (auto it = penalties->find(std::string(word)); it != penalties->end()) return it->second;
    return 0;
}
UnigramModel::UnigramModel(const PackedLexicon& packed) : packed_(packed), total_(double(packed.wordCount())) {
    for (std::uint32_t id = 0; id < packed.wordCount(); ++id) total_ += double(packed.frequency(id));
}
double UnigramModel::logProbability(std::string_view word) const {
    const auto id = packed_.wordID(word);
    const double count = id ? double(packed_.frequency(std::uint32_t(*id))) + 1 : 0.5;
    return std::log(std::max(count / total_, std::numeric_limits<double>::denorm_min()));
}
namespace {
const PackedLexicon& require(const std::shared_ptr<const PackedLexicon>& packed, const std::shared_ptr<const NeuralWordModel>& neural) {
    if (!packed) throw std::invalid_argument("the neural search space needs a packed lexicon");
    if (!neural) throw std::invalid_argument("the neural search space needs a model");
    return *packed;
}
}
Engine::Engine(std::shared_ptr<const PackedLexicon> packed, std::shared_ptr<const NeuralWordModel> neural, EngineOptions options)
    : packed_(std::move(packed)), neural_(std::move(neural)), options_(options),
      neuralLexicon_(std::make_shared<NeuralLexicon>(require(packed_, neural_))), unigram_(*packed_) {}
std::unique_ptr<EngineSession> Engine::createSession() { return std::make_unique<EngineSession>(shared_from_this()); }
std::shared_ptr<const NeuralFst::Tables> Engine::neuralTables() const {
    std::call_once(neuralTablesOnce_, [&] {
        neuralTables_ = std::make_shared<NeuralFst::Tables>(neural_, neuralLexicon_,
            NeuralFst::Options{options_.nssExact, options_.nssUnigramFloor, options_.nssUnknownExponent});
    });
    return neuralTables_;
}
NeuralFst& EngineSession::graph() {
    if (!graph_) graph_ = std::make_unique<NeuralFst>(engine_->neuralTables());
    return *graph_;
}
DecodeOutput EngineSession::decode(const DecodeInput& input, const EngineView& view, const CancellationToken* token) {
    DecodeOutput out; out.identity = input.identity;
    auto cancelled = [&] { return token && token->cancelled(); };
    if (cancelled()) { out.status = EngineStatus::cancelled; return out; }
    if (view.lexicon.packed != engine_->packed_.get()) throw std::invalid_argument("engine/view dictionary mismatch");
    const auto& typed = input.normalized;
    if (!validUTF8(input.word) || !validUTF8(typed) || std::any_of(input.context.begin(), input.context.end(), [](const auto& word) { return !validUTF8(word); }))
        throw std::invalid_argument("invalid UTF-8 request");
    auto& g = graph();
    const bool newField = !identityReady_ || identity_.fieldRevision != input.identity.fieldRevision ||
        identity_.vocabularyEpoch != input.identity.vocabularyEpoch || identity_.personalizationEpoch != input.identity.personalizationEpoch;
    const bool newWord = newField || identity_.wordSessionID != input.identity.wordSessionID;
    if (newField) g.resetContext();
    g.update(input.context, newWord || !typed.starts_with(typed_));
    if (!search_) search_ = std::make_unique<NeuralFstSearch>(g, NeuralFstSearch::Options{16, 512});
    if (newWord || identity_.layoutRevision != input.identity.layoutRevision) search_->reset();
    identity_ = input.identity; identityReady_ = true; typed_ = typed;
    if (cancelled()) { out.status = EngineStatus::cancelled; return out; }
    auto blocked = [&](const RankedRow& row) { return view.lexicon.isBlocked(row.key); };
    if (typed.empty()) {
        for (const auto& [id, language] : g.best(0, 16)) {
            (void)language;
            std::string word(engine_->packed_->word(id));
            if (view.lexicon.isBlocked(word)) continue;
            out.suggestions.push_back(std::move(word));
            if (out.suggestions.size() == 3) break;
        }
        return out;
    }
    auto ranked = search_->decode(typed, input.taps, cancelled);
    auto complete = search_->completed();
    if (cancelled()) { g.update(input.context, true); search_->reset(); out.status = EngineStatus::cancelled; return out; }
    std::erase_if(ranked, blocked); std::erase_if(complete, blocked);
    double literal;
    bool typedIsWord = false;
    if (auto id = engine_->packed_->wordID(typed); id && std::isfinite(engine_->neuralLexicon_->unigram[std::size_t(*id)])) {
        literal = g.wordScore(0, std::uint32_t(*id));
        typedIsWord = true;
    } else if (engine_->options_.nssExact && engine_->options_.nssTypedUnknown)
        literal = g.typedUnknown();
    else
        literal = engine_->unigram_.logProbability(typed);
    RankedRow typedRow{{typed, 0, 0}, typed, 0, literal, literal, {}};
    std::erase_if(ranked, [&](const auto& row) { return row.key == typed; });
    std::erase_if(complete, [&](const auto& row) { return row.key == typed; });
    if (nssRuleOn(nssRuleFirstLetter)) for (auto* rows : {&ranked, &complete}) for (auto& row : *rows)
        if (const double extra = nssFirstLetterCost(typed, row.key); extra > 0) { row.channel.cost += extra; row.score -= channelWeight * extra; }
#ifdef KB_TUNING
    out.complete = complete; out.ranked = ranked; out.typedIsWord = typedIsWord; out.literal = literal;
#endif
    if (nssRuleOn(nssRuleFrequency)) {
        const auto prior = [&](RankedRow& row) {
            if (row.key.find(' ') != std::string::npos) return;
            if (auto id = engine_->packed_->wordID(row.key)) {
                const double add = nssFrequencyWeight * std::log(double(std::max(engine_->packed_->frequency(std::uint32_t(*id)), 1u)) + 1);
                row.language += add; row.score += add;
            }
        };
        for (auto& row : ranked) prior(row);
        for (auto& row : complete) prior(row);
        prior(typedRow);
    }
    const bool start = input.context.empty();
    if (start && nssStartUnigramWeight > 0) {
        const double w = nssStartUnigramWeight;
        const auto rescore = [&](RankedRow& row) {
            if (row.key.find(' ') != std::string::npos) return;
            const double unigram = engine_->unigram_.logProbability(row.key);
            const double hi = std::max(row.language, unigram), lo = std::min(row.language, unigram);
            const double a = row.language >= unigram ? 1 - w : w;
            const double mixed = hi + std::log(a + (1 - a) * std::exp(lo - hi));
            row.score += mixed - row.language;
            row.language = mixed;
        };
        for (auto& row : ranked) rescore(row);
        for (auto& row : complete) rescore(row);
        rescore(typedRow);
    }
    const auto higher = [](const auto& a, const auto& b) { return a.score == b.score ? a.key > b.key : a.score < b.score; };
    auto best = std::max_element(complete.begin(), complete.end(), higher);
    if (nssRuleOn(nssRuleSplitMargin) && best != complete.end() && best->key.find(' ') != std::string::npos && best->score - typedRow.score <= nssSplitMargin) {
        best = complete.end();
        for (auto it = complete.begin(); it != complete.end(); ++it)
            if (it->key.find(' ') == std::string::npos && (best == complete.end() || higher(*best, *it))) best = it;
    }
    const auto upper = [](char c) { return c >= 'A' && c <= 'Z'; };
    const bool capitalized = !input.context.empty() && !input.word.empty() && upper(input.word[0]) &&
        !std::all_of(input.word.begin(), input.word.end(), [&](char c) { return upper(c) || !std::isalpha(static_cast<unsigned char>(c)); });
    const double margin = typedIsWord ? 0 : start ? nssStartCommitMargin : capitalized ? nssCapitalizedCommitMargin : nssRawCommitMargin;
    double allowance = margin;
    if (best != complete.end() && !typedIsWord && nssRuleOn(nssRuleSameSound)) {
        double next = -std::numeric_limits<double>::infinity();
        for (const auto& row : complete) if (&row != &*best) next = std::max(next, row.score);
        allowance += nssSameSoundAllowance(typed, best->key, best->score - next);
    }
    if (best != complete.end() && best->score > typedRow.score - allowance && !input.kept)
        out.correction = {best->key, best->score - typedRow.score};
    if (out.correction.word && (engine_->packed_->preserves(typed) || !engine_->packed_->allowsCorrection(*out.correction.word)))
        out.correction = {};
    ranked.push_back(typedRow);
    std::sort(ranked.begin(), ranked.end(), [](const auto& a, const auto& b) { return a.score == b.score ? a.key < b.key : a.score > b.score; });
    for (const auto& row : ranked) {
        if (out.suggestions.size() < 3 && row.key != typed) out.suggestions.push_back(row.key);
        if (out.candidates.size() < 24) out.candidates.push_back({row, row.key == typed ? CandidateSource::typed
            : row.key.find(' ') != std::string::npos ? CandidateSource::splitCorrection : CandidateSource::fuzzyLexicon, row.score - typedRow.score});
    }
    placeDecision(out, input);
    return out;
}
void EngineSession::beginGlide(std::vector<std::string> context) {
    search_.reset(); graph_.reset(); identityReady_ = false; glideContext_ = std::move(context);
}
std::vector<RankedRow> EngineSession::updateGlide(std::span<const Point> path, const GlideLayout& layout, const EngineView& view,
        std::span<const std::string> dynamic, const CancellationToken* token) {
    if (token && token->cancelled()) return {};
    auto& g = graph();
    g.update(glideContext_);
    std::vector<Point> points;
    for (auto point : path) points.push_back(toGrid(point, layout));
    auto stop = [&] { return token && token->cancelled(); };
    auto rows = decodeGlide(points, *engine_->packed_, 512, 4, 0, 0, 1.3, 8, stop,
        [&](std::size_t node) { return g.lookahead(0, std::uint32_t(node)); });
    for (const auto& word : dynamic) if (!view.lexicon.isBlocked(word))
        if (auto cost = shapeCost(word, points, 4, 0)) rows.push_back({word, *cost, 0});
    std::vector<RankedRow> result;
    for (const auto& row : rows) {
        if (view.lexicon.isBlocked(row.word)) continue;
        double prior;
        if (auto id = engine_->packed_->wordID(row.word)) prior = g.wordScore(0, std::uint32_t(*id));
        else prior = engine_->unigram_.logProbability(row.word) + personalBoost(row.word, counts(view), view.lexicon);
        prior += personalBoost(row.word, counts(view), view.lexicon);
        auto safety = view.penalty(row.word);
        result.push_back({row, row.word, safety, prior, -row.cost / 0.1 + 0.6 * prior - safety, {}});
    }
    std::sort(result.begin(), result.end(), [](const auto& a, const auto& b) { return a.score == b.score ? a.key < b.key : a.score > b.score; });
    return stop() ? std::vector<RankedRow>{} : result;
}
}

namespace kb {
namespace {
bool glideWord(std::string_view word) { return word.size()>=2 && std::all_of(word.begin(),word.end(),[](unsigned char c){return(c>='a'&&c<='z')||c=='\'';}); }
}
EngineView EngineState::view() const {
    return {{packed_.get(),nullptr,&supplementary_,&adopted_,vocabulary_.snapshot().get()},personal_.counts().get(),&residual_,personal_.revision(),vocabularyRevision_};
}
void EngineState::setSafety(std::unordered_map<std::string,double> penalties){
    penalties_=std::move(penalties);residual_.clear();std::unordered_set<std::string> blocked;
    for(const auto&[word,cost]:penalties_){if(!std::isfinite(cost))blocked.insert(word);else if(packed_&&packed_->wordID(word))residual_.emplace(word,cost);}
    if(packed_){std::vector<std::string> terms(blocked.begin(),blocked.end());packed_->installBlocked(terms);}
    vocabulary_.setBlocked(std::move(blocked));++vocabularyRevision_;}
void EngineState::note(const std::string&word,std::int64_t count){auto lexicon=view().lexicon;bool allow=personal_.allowsAdoption(word,count,lexicon);if(vocabulary_.noteUse(lexicon,adopted_,word,count,allow,8,glideWord(word)))++vocabularyRevision_;}
void EngineState::apply(const UserEvent& event){
    switch(event.kind){
    case UserEventKind::learn:if(event.learnable&&!event.word.empty()&&!penalties_.contains(event.word)){personal_.learn(event.word);personal_.prune();note(event.word,personal_.counts()->uni(event.word));}break;
    case UserEventKind::confirmSpelling:personal_.confirm(event.word);break;
    case UserEventKind::correctionStood:personal_.releaseKeep(event.word);break;
    case UserEventKind::wordReplaced:personal_.releaseKeep(event.word);personal_.demote(event.word);break;
    case UserEventKind::reset:personal_.reset(event.epoch);adopted_=MutableTrie();vocabulary_.resetPersonalization();++vocabularyRevision_;break;
    case UserEventKind::supplementary:if(event.learnable&&!event.word.empty()&&!penalties_.contains(event.word)&&!view().lexicon.contains(event.word)){supplementary_.insert(event.word,50);vocabulary_.supplementary(event.word,50,glideWord(event.word));++vocabularyRevision_;}break;
    }
}
void EngineState::importPersonalization(PersonalizationSnapshot snapshot){
    personal_.install(std::move(snapshot));personal_.prune();adopted_=MutableTrie();vocabulary_.resetPersonalization();++vocabularyRevision_;
    std::vector<std::string> words;for(const auto&[word,count]:personal_.counts()->unigram){(void)count;words.push_back(word);}std::sort(words.begin(),words.end(),utf8Less);for(const auto&word:words)note(word,std::min<std::int64_t>(personal_.counts()->uni(word),50));
}
}
