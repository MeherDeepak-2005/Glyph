#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include "Tuning.hpp"
namespace kb {
struct TouchOffset { double dx, dy; };
struct GridPoint { double x, y; bool operator==(const GridPoint&) const = default; };
inline constexpr std::uint8_t apostrophe = '\'';
KB_TUNABLE(insertionCost, 1.6);
KB_TUNABLE(deletionCost, 1.1);
KB_TUNABLE(transpositionCost, 0.65);
KB_TUNABLE(doubledDeletionCost, 0.3);
KB_TUNABLE(doubledInsertionCost, 0.6);
inline constexpr double apostropheSkipCost = 0.4;
KB_TUNABLE(firstLetterPenalty3, 0.35);
KB_TUNABLE(firstLetterPenalty4, 0.2);
KB_TUNABLE(swappedFirstLetterPenalty, 0.75);
KB_TUNABLE(missingFirstLetterPenalty4, 0.2);
KB_TUNABLE(missingFirstLetterPenalty, 1.5);
KB_TUNABLE(adjacentFirstLetterPenalty, 1.0);
KB_TUNABLE(otherFirstLetterPenalty, 2.0);
KB_TUNABLE(substitutionBase, 0.6);
KB_TUNABLE(touchSigma, 0.7);
KB_TUNABLE(vowelSubstitutionCost, 1.5);
KB_TUNABLE(firstVowelSubstitutionCost, 1.5);
KB_TUNABLE(spellingFirstLetterPenalty, 2.0);
KB_TUNABLE(extraLeadingKeyCost, 1.6);
KB_TUNABLE(soundAlikeSubstitutionCost, 0.9);
inline double deletionCostAt(std::uint8_t letter, std::uint8_t previous, std::uint8_t typedLetter) noexcept {
    return letter == apostrophe ? apostropheSkipCost
        : letter == previous && letter == typedLetter ? doubledDeletionCost : deletionCost;
}
inline double insertionCostAt(std::uint8_t typedLetter, std::uint8_t previous, std::uint8_t candidateLetter) noexcept {
    return typedLetter == previous && typedLetter == candidateLetter ? doubledInsertionCost : insertionCost;
}
std::optional<GridPoint> grid(std::uint8_t letter) noexcept;
std::string_view gridLetters() noexcept;
bool installGrid(std::span<const std::string_view> rows, std::span<const double> offsets) noexcept;
double substitutionCost(std::uint8_t intended, std::uint8_t typed,
                        std::optional<TouchOffset> tap = {}, bool typedFirst = false) noexcept;
double touchSubstitutionCost(std::uint8_t intended, std::uint8_t typed, TouchOffset tap, double sigma, bool typedFirst = false) noexcept;
double geometricSubstitutionCost(std::uint8_t intended, std::uint8_t typed, std::optional<TouchOffset> tap = {}) noexcept;
double seedFirstLetterCost(std::uint8_t label, std::uint8_t typedFirst, std::optional<TouchOffset> tap) noexcept;
bool spellingConfusion(std::uint8_t a, std::uint8_t b) noexcept;
bool neighbouringKeys(std::uint8_t a, std::uint8_t b) noexcept;
double firstLetterPenalty(std::size_t typedLength, std::uint8_t candidateFirst,
                          std::uint8_t typedFirst, std::uint8_t typedSecond = 0,
                          std::uint8_t candidateSecond = 0, bool spelling = true) noexcept;
}
