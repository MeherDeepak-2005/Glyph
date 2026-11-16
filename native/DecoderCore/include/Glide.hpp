#pragma once
#include "PackedLexicon.hpp"
#include <functional>
namespace kb {
struct Point { double x = 0, y = 0; };
struct GlideLayout { std::vector<std::pair<std::uint8_t, Point>> centers; double xPitch, yPitch; };
struct ProcessedGlide { std::vector<Point> points; std::vector<std::size_t> pivots; std::vector<std::uint8_t> dwell; };
Point toGrid(Point point, const GlideLayout& layout);
std::vector<Point> resample(std::span<const Point> points, double spacing);
std::vector<std::size_t> pivots(std::span<const Point> points, double threshold = 0.5);
std::vector<std::uint8_t> lettersNear(Point point, double radius, std::size_t maxCount);
std::optional<std::uint8_t> nearestLetter(Point point);
std::optional<ProcessedGlide> preprocess(std::span<const Point> points, const GlideLayout& layout,
    double spacing, std::span<const double> times);
std::vector<Point> resampleN(std::span<const Point> points, std::size_t count);
std::optional<std::vector<Point>> idealPath(std::string_view word, std::size_t count);
std::optional<double> shapeCost(std::string_view word, std::span<const Point> observed, int band, double direction);
std::vector<ChannelCandidate> decodeGlide(std::span<const Point> observed, const PackedLexicon& lexicon,
    std::size_t width, int band, double frequency, double direction, double seedRadius, std::size_t window,
    const std::function<bool()>& cancel,
    const std::function<double(std::size_t)>& languageLookahead = {});
}
