#pragma once
#include <cstdint>
#include <vector>
namespace kb {
// Loaded once with the dictionary. Values are editor-reviewed product permissions,
// not corpus counts. No per-user state is stored here.
struct ModernVocabulary {
    struct Policy { std::uint32_t word, flags; };
    struct Context { std::uint32_t first, last, word, priority; };
    std::vector<Policy> policies;
    std::vector<Context> contexts;
};
} // namespace kb
