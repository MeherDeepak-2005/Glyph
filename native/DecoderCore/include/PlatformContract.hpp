#pragma once
#include <cstdint>

namespace kb {
struct RequestIdentity {
    std::uint64_t fieldRevision = 0;
    std::uint64_t documentRevision = 0;
    std::uint64_t wordSessionID = 0;
    std::uint64_t generation = 0;
    std::uint64_t layoutRevision = 0;
    std::uint64_t vocabularyEpoch = 0;
    std::uint64_t personalizationEpoch = 0;
    bool operator==(const RequestIdentity&) const = default;
};
inline constexpr std::uint32_t platformContractVersion = 3;
inline constexpr std::uint32_t currentLanguagePackVersion = 7;
}
