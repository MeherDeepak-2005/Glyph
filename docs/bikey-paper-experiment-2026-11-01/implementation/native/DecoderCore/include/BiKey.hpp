#pragma once
#include "SpatialModel.hpp"
#include "Ranking.hpp"
#include "Glide.hpp"
namespace kb {
// Ouyang et al. (2017), section 3.1: a_b is b with a as left context.
// Zero is the start-of-word context. C rejects inconsistent context labels.
struct BiKey { std::uint8_t left, key; };
std::optional<std::uint8_t> biKeyOutput(std::uint8_t state, BiKey label) noexcept;
// Tied isotropic Gaussians: the papers do not supply learned pair-specific means.
// Absolute Gaussian costs are used for both candidates AND the literal, with the
// common normalizer omitted. No spelling-confusion cap or substitution bonus.
double biKeyTapCost(BiKey, std::uint8_t typed, std::optional<TouchOffset>, double sigma) noexcept;
double biKeyLiteralCost(std::string_view, std::span<const std::optional<TouchOffset>>, double sigma);
// DP for recovery/dynamic candidates; same tap channel as the joint search.
double biKeyWordCost(std::string_view candidate, std::string_view typed,
    std::span<const std::optional<TouchOffset>>, double sigma, bool raw = false);
class SearchGraph;
// Single-word gesture C o L o G. Endpoint states and a_b transition states consume
// samples; transition self-loops emit epsilon. LM lookahead participates in pruning.
// Segment-distance geometry is an explicit reconstruction assumption, NOT a
// recovered minimum-jerk model or Google's trained spatial model.
std::vector<RankedRow> decodeBiKeyGesture(SearchGraph&, std::span<const Point>,
    double sigma, double beam, std::size_t width, double channelWeight,
    const std::function<bool()>& cancelled = {});
}
