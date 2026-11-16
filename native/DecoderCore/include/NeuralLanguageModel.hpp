#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace kb {
class PackedLexicon;

class NeuralWordModel final {
public:
    static std::shared_ptr<const NeuralWordModel> load(std::span<const std::byte> bytes, std::shared_ptr<const void> owner = {});
    std::size_t vocabularySize() const noexcept { return vocabulary_; }
    std::size_t stateSize() const noexcept { return stateSize_; }
    std::size_t featureSize() const noexcept { return features_; }
    std::int32_t unknown() const noexcept { return unk_; }
    std::int32_t sentenceStart() const noexcept { return bos_; }
    float unknownLexiconShare() const noexcept { return unkShare_; }
    float unknownLogCenter() const noexcept { return unkCenter_; }
    std::string_view word(std::int32_t id) const;
    std::int32_t exact(std::string_view word) const;
    std::int32_t contextID(std::string_view word) const;
    void step(std::int32_t token, std::span<const float> state, std::span<float> next, std::span<float> features) const;
    void wordLogProbabilities(std::span<const float> features, std::span<float> out) const;
    const std::array<std::uint8_t, 32>& vocabularySHA256() const noexcept { return vocabularySHA_; }
private:
    struct Matrix { const std::int8_t* q = nullptr; const float* scale = nullptr; std::size_t rows = 0, cols = 0; };
    struct Layer { Matrix gates, projection; const float* bias = nullptr; std::size_t input = 0; };
    NeuralWordModel() = default;
    std::shared_ptr<const void> owner_;
    std::uint32_t arch_ = 0;
    bool cifg_ = false;
    std::size_t vocabulary_ = 0, embed_ = 0, hidden_ = 0, projection_ = 0, features_ = 0, recurrent_ = 0, stateSize_ = 0;
    std::int32_t pad_ = 0, unk_ = 1, bos_ = 2, eos_ = 3;
    float unkShare_ = 0, unkCenter_ = 0;
    Matrix embedding_, output_, gruProjection_;
    const float* outputBias_ = nullptr;
    std::vector<Layer> layers_;
    const std::uint32_t* wordOffsets_ = nullptr;
    const char* wordText_ = nullptr;
    std::vector<std::int32_t> sorted_;
    std::array<std::uint8_t, 32> vocabularySHA_{};
};

struct UnknownWordTable {
    double logShare = 0, logOOVMass = 0;
    std::size_t oovWords = 0;
    static UnknownWordTable build(const NeuralWordModel&, const PackedLexicon&);
    double logWordGivenUnknown(double unigramMass) const;
};

class ContextRing final {
public:
    explicit ContextRing(std::shared_ptr<const NeuralWordModel> model, std::size_t capacity = 64, std::size_t window = 8);
    struct Sync { std::size_t reused = 0, stepped = 0; };
    Sync sync(std::span<const std::int32_t> context);
    std::span<const float> state() const { return stateAt(length_); }
    std::span<const float> features() const { return featuresAt(length_); }
    std::size_t length() const noexcept { return length_; }
    std::uint64_t steps() const noexcept { return steps_; }
private:
    std::shared_ptr<const NeuralWordModel> model_;
    std::size_t capacity_, window_, length_ = 0;
    std::uint64_t steps_ = 0;
    std::vector<float> rootState_, rootFeatures_, states_, features_;
    std::vector<std::int32_t> ids_;
    std::size_t oldest() const noexcept { return length_ > capacity_ ? length_ - capacity_ + 1 : 1; }
    std::int32_t idAt(std::size_t position) const { return ids_[(position - 1) % capacity_]; }
    std::span<const float> stateAt(std::size_t position) const;
    std::span<const float> featuresAt(std::size_t position) const;
};

class NeuralSearchSpace final {
public:
    NeuralSearchSpace(std::shared_ptr<const NeuralWordModel> model, UnknownWordTable unknown, std::size_t capacity = 64, std::size_t window = 8);
    ContextRing::Sync update(std::span<const std::string> context);
    double logProbability(std::string_view word, double unigramMass) const;
    double unknownLogProbability() const { return logProbabilities_[std::size_t(model_->unknown())]; }
    const std::vector<std::pair<std::int32_t, float>>& arcs(float threshold, std::size_t limit) const;
    double sequence(std::span<const std::string> words, const std::function<double(std::string_view)>& unigramMass) const;
    const NeuralWordModel& model() const noexcept { return *model_; }
    std::uint64_t modelSteps() const noexcept { return ring_.steps(); }
    std::uint64_t revision() const noexcept { return revision_; }
private:
    std::shared_ptr<const NeuralWordModel> model_;
    UnknownWordTable unknown_;
    ContextRing ring_;
    std::vector<std::int32_t> ids_;
    std::vector<float> logProbabilities_;
    std::uint64_t revision_ = 0;
    bool ready_ = false;
    mutable std::vector<std::pair<std::int32_t, float>> arcs_;
    mutable float arcsThreshold_ = 0;
    mutable std::size_t arcsLimit_ = 0;
    mutable bool arcsReady_ = false;
    double score(std::string_view word, double unigramMass, std::span<const float> logProbabilities) const;
};
}
