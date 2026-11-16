#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include "SpatialModel.hpp"
namespace kb {
KB_TUNABLE(nssRules, 1);
KB_TUNABLE(nssRuleVowelSwap, 1);
KB_TUNABLE(nssRuleApostrophe, 1);
KB_TUNABLE(nssRuleDoubledLetters, 1);
KB_TUNABLE(nssRuleFirstLetter, 1);
KB_TUNABLE(nssRuleSoundAlike, 1);
KB_TUNABLE(nssRuleSameSound, 1);
KB_TUNABLE(nssSameSoundMargin, 1.5);
KB_TUNABLE(nssSameSoundGap, 1.0);
KB_TUNABLE(nssRuleTouch, 1);
KB_TUNABLE(nssRuleFrequency, 0);
KB_TUNABLE(nssFrequencyWeight, 0.1);
KB_TUNABLE(nssRuleSplitMargin, 1);
KB_TUNABLE(nssSplitMargin, 3.0);

inline bool nssRuleOn(double rule) noexcept { return nssRules != 0 && rule != 0; }
inline bool nssVowel(std::uint8_t c) noexcept { return c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u'; }

inline double nssKeyCost(std::uint8_t intended, std::uint8_t typed, std::optional<TouchOffset> tap) noexcept {
    if (!tap || !std::isfinite(tap->dx) || !std::isfinite(tap->dy) || touchSigma <= 0 || !nssRuleOn(nssRuleTouch))
        return geometricSubstitutionCost(intended, typed, tap);
    if (intended == typed) return 0;
    const auto a = grid(intended), t = grid(typed);
    if (!a || !t) return 3.0;
    const double px = t->x + tap->dx, py = t->y + tap->dy;
    const double toIntended = (a->x - px) * (a->x - px) + (a->y - py) * (a->y - py), toTyped = tap->dx * tap->dx + tap->dy * tap->dy;
    return std::min(3.0, std::max(0.0, toIntended - toTyped) / (2 * touchSigma * touchSigma) + substitutionBase);
}
inline double nssSubstitutionCost(std::uint8_t intended, std::uint8_t typed, std::optional<TouchOffset> tap) noexcept {
    const double geometric = nssKeyCost(intended, typed, tap);
    if (intended == typed) return geometric;
    if (nssVowel(intended) && nssVowel(typed) && nssRuleOn(nssRuleVowelSwap))
        return std::min(geometric, vowelSubstitutionCost);
    const auto pair = [&](char x, char y) { return (intended == x && typed == y) || (intended == y && typed == x); };
    if ((pair('c', 'k') || pair('c', 's') || pair('s', 'z')) && nssRuleOn(nssRuleSoundAlike))
        return std::min(geometric, soundAlikeSubstitutionCost);
    return geometric;
}
inline double nssDeletionCost(std::uint8_t letter, std::uint8_t previous, std::uint8_t typedLetter) noexcept {
    if (letter == apostrophe) return nssRuleOn(nssRuleApostrophe) ? apostropheSkipCost : deletionCost;
    if (letter == previous && letter == typedLetter && nssRuleOn(nssRuleDoubledLetters)) return doubledDeletionCost;
    return deletionCost;
}
inline double nssInsertionCost(std::uint8_t typedLetter, std::uint8_t previousTyped, std::uint8_t wordLetter) noexcept {
    if (typedLetter == previousTyped && typedLetter == wordLetter && nssRuleOn(nssRuleDoubledLetters)) return doubledInsertionCost;
    return insertionCost;
}
inline double nssFirstLetterCost(std::string_view typed, std::string_view word) noexcept {
    if (typed.empty() || word.empty() || !nssRuleOn(nssRuleFirstLetter)) return 0;
    const auto at = [](std::string_view s, std::size_t i) { return i < s.size() ? std::uint8_t(s[i]) : std::uint8_t(0); };
    return firstLetterPenalty(typed.size(), at(word, 0), at(typed, 0), at(typed, 1), at(word, 1));
}
inline std::string nssSpellingSkeleton(std::string_view word) {
    std::string letters;
    for (char c : word) {
        if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
        if (c < 'a' || c > 'z') return {};
        letters += c;
    }
    const auto vowel = [](char c) { return c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u' || c == 'y'; };
    std::string sounds;
    for (std::size_t i = 0; i < letters.size(); ++i) {
        char c = letters[i];
        const char next = i + 1 < letters.size() ? letters[i + 1] : 0;
        if (c == 'p' && next == 'h') { c = 'f'; ++i; }
        else if (c == 'c' && next == 'k') { c = 'k'; ++i; }
        else if (c == 'c') c = next == 'e' || next == 'i' || next == 'y' ? 's' : 'k';
        else if (c == 'z') c = 's';
        else if (i > 0 && vowel(c)) c = '*';
        if (sounds.empty() || sounds.back() != c) sounds += c;
    }
    if (letters.size() > 2 && letters.back() == 'e' && sounds.size() > 1 && sounds.back() == '*' && !vowel(letters[letters.size() - 2])) sounds.pop_back();
    return sounds;
}
inline double nssSameSoundAllowance(std::string_view typed, std::string_view word, double lead) {
    if (!nssRuleOn(nssRuleSameSound) || typed.size() < 4 || lead < nssSameSoundGap || word.find_first_of(" '") != std::string_view::npos) return 0;
    const auto skeleton = nssSpellingSkeleton(typed);
    return !skeleton.empty() && skeleton == nssSpellingSkeleton(word) ? nssSameSoundMargin : 0;
}
}
