#pragma once
#include "PackedLexicon.hpp"
#include "Tuning.hpp"
#include <optional>
#include <string>
namespace kb {
// One scored word: its channel evidence (spelling cost and log frequency), the language
// model's log probability and the final score, log P - channelWeight x cost - safety.
struct RankedRow {
    ChannelCandidate channel;
    std::string key;
    double safety = 0, language = 0, score = 0;
    std::optional<double> neural;
};
// The channel cost's weight against log P. The channel weighs 4 (28 Oct): at 1, a frequent
// word one edit further away won (recident -> president, not resident), above all without
// context.
KB_TUNABLE(channelWeight, 4.0);
// The word Space commits in place of the typed text, and by how much its score beats it.
struct CorrectionResult {
    std::optional<std::string> word;
    double margin = 0;
};
} // namespace kb
