#pragma once
#include "PackedLexicon.hpp"
#include "Tuning.hpp"
#include <optional>
#include <string>
namespace kb {
struct RankedRow {
    ChannelCandidate channel;
    std::string key;
    double safety = 0, language = 0, score = 0;
    std::optional<double> neural;
};
KB_TUNABLE(channelWeight, 4.0);
struct CorrectionResult {
    std::optional<std::string> word;
    double margin = 0;
};
}
