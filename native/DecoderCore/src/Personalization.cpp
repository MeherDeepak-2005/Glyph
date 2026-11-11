#include "../include/Personalization.hpp"
#include "../include/TextOrder.hpp"
#include <algorithm>
#include <limits>
namespace kb {
namespace {
void increment(std::int64_t& count) { if (count < std::numeric_limits<std::int64_t>::max()) ++count; }
}
std::int64_t PersonalCounts::uni(std::string_view word) const {
    auto found = unigram.find(std::string(word)); return found == unigram.end() ? 0 : found->second;
}
double personalBoost(std::string_view word, const PersonalCounts& personal, const GenerationLexicon& lexicon) {
    return personalLanguageBoost(double(lexicon.contains(word) ? personal.uni(word) : 0), 0.10);
}
void Personalization::mutate() { ++revision_; if (counts_.use_count() != 1) counts_ = std::make_shared<PersonalCounts>(*counts_); }
void Personalization::reset(std::uint64_t epoch) { ++revision_; counts_ = std::make_shared<PersonalCounts>(); confirmed_.clear(); kept_.clear(); epoch_ = epoch; }
void Personalization::install(PersonalizationSnapshot snapshot) { reset(snapshot.epoch); counts_ = std::make_shared<PersonalCounts>(std::move(snapshot.counts)); confirmed_ = std::move(snapshot.confirmed); }
void Personalization::learn(std::string word) {
    if (word.empty() || word.size() > maxPersonalWordBytes) return;
    mutate(); increment(counts_->unigram[word]);
}
void Personalization::demote(std::string_view word) {
    mutate(); auto found=counts_->unigram.find(std::string(word));
    if(found!=counts_->unigram.end()) { if(found->second>1) --found->second; else counts_->unigram.erase(found); }
}
void Personalization::confirm(std::string word) {
    if (word.empty() || word.size() > maxPersonalWordBytes) return;
    confirmed_[word]=std::min<std::int64_t>(confirmed_[word]+1,8); kept_.insert(std::move(word));
    if(confirmed_.size()>512){for(auto& [key,count]:confirmed_){(void)key;count=count>=2?count-1:0;}std::erase_if(confirmed_,[](const auto& e){return e.second==0;});}
}
std::int64_t Personalization::confirmations(std::string_view word) const { auto it=confirmed_.find(std::string(word));return it==confirmed_.end()?0:it->second; }
bool Personalization::prune() {
    if(counts_->unigram.size()<=4000)return false;mutate();
    for(auto& [key,count]:counts_->unigram){(void)key;count=count>=2?count>>1:0;}std::erase_if(counts_->unigram,[](const auto& e){return e.second==0;});
    if(counts_->unigram.size()>4000){CountRows rows(counts_->unigram.begin(),counts_->unigram.end());std::sort(rows.begin(),rows.end(),[](const auto& a,const auto& b){return a.second==b.second?utf8Less(a.first,b.first):a.second>b.second;});counts_->unigram.clear();for(std::size_t i=0;i<4000;++i)counts_->unigram.emplace(std::move(rows[i]));}
    return true;
}
bool Personalization::allowsAdoption(std::string_view word,std::int64_t count,const GenerationLexicon& lexicon,std::int64_t threshold) const {
    if(count<threshold)return false;if(lexicon.contains(word)||confirmations(word)>0)return true;
    if(count<threshold*2)return false;
    const auto near=lexicon.packed?lexicon.packed->search(word,1.05):lexicon.base?lexicon.base->search(word,1.05):std::vector<ChannelCandidate>{};
    for(const auto& row:near) if(row.word!=word && row.cost<=1.05)return false;
    return true;
}
}

namespace kb {
static std::vector<std::string> dynamicGlideWords(const CountRows& supplementary, const CountRows& personal, std::size_t limit) {
    std::unordered_map<std::string, std::int64_t> merged;
    for (const auto& [word, count] : supplementary) merged[word] = count;
    for (const auto& [word, count] : personal) merged[word] = std::max(merged[word], count + 100);
    CountRows rows(merged.begin(), merged.end());
    std::sort(rows.begin(), rows.end(), [](const auto& a, const auto& b) { return a.second == b.second ? a.first < b.first : a.second > b.second; });
    std::vector<std::string> out; for (const auto& [word, count] : rows) { (void)count; if (out.size() >= limit) break; out.push_back(word); } return out;
}
void VocabularyState::mutate() { if(generation_.use_count()!=1)generation_=std::make_shared<GenerationSnapshot>(*generation_); }
void VocabularyState::setBlocked(std::unordered_set<std::string> words){mutate();generation_->blocked=std::move(words);}
void VocabularyState::supplementary(std::string word,std::int64_t frequency,bool glide){
    if(glide&&(supplementaryGlide_.size()<768||supplementaryGlide_.contains(word)))supplementaryGlide_[word]=std::max(supplementaryGlide_[word],frequency);
}
bool VocabularyState::noteUse(const GenerationLexicon& lexicon,MutableTrie& personal,std::string word,std::int64_t count,bool allow,std::int64_t threshold,bool glide){
    bool isStatic=(lexicon.packed&&lexicon.packed->wordID(word))||(!lexicon.packed&&lexicon.base&&lexicon.base->contains(word));
    if(isStatic){mutate();auto&boost=generation_->boosts[word];boost=std::min<std::int64_t>(boost+1,100);if(generation_->boosts.size()>3000){for(auto&[key,value]:generation_->boosts){(void)key;value=value>=2?value>>1:0;}std::erase_if(generation_->boosts,[](const auto&e){return e.second==0;});}}
    else if(lexicon.supplementary&&lexicon.supplementary->contains(word)){if(auto it=supplementaryGlide_.find(word);it!=supplementaryGlide_.end())it->second=std::min<std::int64_t>(it->second+1,500);}
    else if(personal.contains(word)){personal.bump(word);auto it=personalGlide_.find(word);personalGlide_[word]=std::min<std::int64_t>((it==personalGlide_.end()?count:it->second)+1,500);}
    else if(allow&&count>=threshold){personal.insert(word,count);if(glide){personalGlide_[word]=count;if(personalGlide_.size()>384){CountRows ordered(personalGlide_.begin(),personalGlide_.end());std::sort(ordered.begin(),ordered.end(),[](const auto&a,const auto&b){return a.second==b.second?utf8Less(a.first,b.first):a.second>b.second;});personalGlide_.clear();for(std::size_t i=0;i<384;++i)personalGlide_.emplace(std::move(ordered[i]));}}return true;}
    return false;
}
std::vector<std::string> VocabularyState::dynamicWords(std::size_t limit) const {return dynamicGlideWords(CountRows(supplementaryGlide_.begin(),supplementaryGlide_.end()),CountRows(personalGlide_.begin(),personalGlide_.end()),limit);}
void VocabularyState::resetPersonalization(){mutate();generation_->boosts.clear();personalGlide_.clear();}
}
