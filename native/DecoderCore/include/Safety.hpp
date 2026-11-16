#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>
namespace kb {
enum class SafetyAction : std::uint8_t { allow = 0, demote = 1, suppressSuggest = 2, suppressAlways = 3 };
enum class SafetyLanguage : std::uint8_t { english = 1, telugu = 2, tenglish = 3 };
class SafetyLexicon final {
    std::string_view blob_;
    std::size_t count_ = 0, terms_ = 0;
    std::uint64_t hash(std::size_t entry) const;
    std::string_view term(std::size_t entry) const;
    std::uint8_t byte(std::size_t entry, std::size_t offset) const;
    std::optional<std::size_t> find(std::string_view normalized) const;
public:
    explicit SafetyLexicon(std::string_view blob);
    static std::uint64_t fnv1a(std::string_view text) noexcept;
    std::size_t size() const noexcept { return count_; }
    SafetyAction action(std::string_view normalized) const;
    std::optional<SafetyLanguage> language(std::string_view normalized) const;
    double penalty(std::string_view normalized) const;
    bool blocked(std::string_view normalized) const;
    std::unordered_map<std::string, double> penalties() const;
    std::vector<std::string> blockedTerms() const;
};
std::unordered_map<std::string, double> parseSafetyPenalties(std::string_view blob);
}
