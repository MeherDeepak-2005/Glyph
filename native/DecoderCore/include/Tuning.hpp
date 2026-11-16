#pragma once
#ifdef KB_TUNING
#include <cstdlib>
namespace kb {
inline double tunable(const char* name, double fallback) {
    const char* text = std::getenv(name);
    return text ? std::strtod(text, nullptr) : fallback;
}
}
#define KB_TUNABLE(name, value) inline const double name = ::kb::tunable("KB_" #name, value)
#else
#define KB_TUNABLE(name, value) inline constexpr double name = value
#endif
