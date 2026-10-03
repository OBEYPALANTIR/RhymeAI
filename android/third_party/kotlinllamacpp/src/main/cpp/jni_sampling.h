#pragma once

#include <climits>
#include <cmath>

// Per-request repetition-penalty transport for the sampler.
//
// The four penalty fields live in the context's common_params.sampling, which model load fills from
// GGUF metadata (common_init_sampler_from_model). Each completion request must therefore either apply
// the values the caller asked for or restore the load-time baseline; otherwise a request with explicit
// penalties would leak into the next request that leaves them unset. Kotlin passes kUnsetLastN / NaN
// for a field the caller did not set, which means "leave the model's baseline".
namespace jnisampling {

constexpr int kUnsetLastN = INT_MIN;

inline bool isUnset(int value) { return value == kUnsetLastN; }
inline bool isUnset(float value) { return std::isnan(value); }

struct Penalties {
    int last_n;
    float repeat;
    float freq;
    float present;
};

// Values that a sampler would reject or misinterpret fall back to the baseline instead of being applied.
inline bool validLastN(int value) { return value >= -1; }
inline bool validRepeat(float value) { return std::isfinite(value) && value > 0.0f; }
inline bool validSigned(float value) { return std::isfinite(value); }

// This vendored sampler clamps -1 to zero. Resolve the documented context-size request
// only after apply() has selected the explicit value or model-load baseline.
inline int resolveLastN(int value, int contextSize) {
    return value == -1 ? contextSize : value;
}

template <class Sampling>
Penalties read(const Sampling &sampling) {
    return {sampling.penalty_last_n, sampling.penalty_repeat, sampling.penalty_freq, sampling.penalty_present};
}

// Assigns all four fields every time: the requested value when set and valid, else the baseline.
template <class Sampling>
void apply(Sampling &sampling, const Penalties &baseline, const Penalties &requested) {
    sampling.penalty_last_n =
        (!isUnset(requested.last_n) && validLastN(requested.last_n)) ? requested.last_n : baseline.last_n;
    sampling.penalty_repeat =
        (!isUnset(requested.repeat) && validRepeat(requested.repeat)) ? requested.repeat : baseline.repeat;
    sampling.penalty_freq =
        (!isUnset(requested.freq) && validSigned(requested.freq)) ? requested.freq : baseline.freq;
    sampling.penalty_present =
        (!isUnset(requested.present) && validSigned(requested.present)) ? requested.present : baseline.present;
}

}  // namespace jnisampling
