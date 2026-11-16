#include "../include/NeuralLanguageModel.hpp"
#include "../include/PackedLexicon.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <unordered_map>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif
namespace kb {
namespace {
constexpr std::uint32_t lstmArch = 1, gruArch = 2, flagCIFG = 1, flagTied = 2, flagProjection = 4;
constexpr std::uint32_t int8Kind = 1, floatKind = 2, vocabularyKind = 3;
constexpr std::uint32_t embeddingSection = 1, outputSection = 2, outputBiasSection = 3, gruProjectionSection = 9, vocabularySection = 100;
constexpr std::size_t headerBytes = 256, recordBytes = 32;
void require(bool condition, const char* reason) { if (!condition) throw std::invalid_argument(reason); }
std::uint32_t u32(std::span<const std::byte> bytes, std::size_t at) { std::uint32_t v; std::memcpy(&v, bytes.data() + at, 4); return v; }
std::uint64_t u64(std::span<const std::byte> bytes, std::size_t at) { std::uint64_t v; std::memcpy(&v, bytes.data() + at, 8); return v; }
float f32(std::span<const std::byte> bytes, std::size_t at) { float v; std::memcpy(&v, bytes.data() + at, 4); return v; }
std::size_t layerSection(std::size_t layer, std::size_t part) { return 10 + 4 * layer + part; }
float sigmoid(float x) { return 1.0f / (1.0f + std::exp(-x)); }

constexpr std::size_t block = 16;
struct Activations { std::vector<std::int16_t> q; std::vector<float> scale; };
void quantize(const float* x, std::size_t n, Activations& out) {
    out.q.resize(n);
    out.scale.resize((n + block - 1) / block);
    for (std::size_t b = 0, k = 0; k < n; ++b, k += block) {
        const auto end = std::min(n, k + block);
        float peak = 0;
        for (std::size_t i = k; i < end; ++i) peak = std::max(peak, std::fabs(x[i]));
        const float inverse = peak > 0 ? 32767.0f / peak : 0.0f;
        for (std::size_t i = k; i < end; ++i) out.q[i] = std::int16_t(std::lrintf(x[i] * inverse));
        out.scale[b] = peak / 32767.0f;
    }
}
__attribute__((always_inline)) inline float dot(const std::int8_t* q, const Activations& x, std::size_t n) {
    const std::int16_t* v = x.q.data();
    std::size_t k = 0;
    float total = 0;
#if defined(__ARM_NEON)
    float32x4_t acc = vdupq_n_f32(0);
    for (; k + block <= n; k += block) {
        const int8x16_t w = vld1q_s8(q + k);
        const int16x8_t a = vmovl_s8(vget_low_s8(w)), b = vmovl_high_s8(w);
        const int16x8_t x0 = vld1q_s16(v + k), x1 = vld1q_s16(v + k + 8);
        int32x4_t s0 = vmull_s16(vget_low_s16(a), vget_low_s16(x0)), s1 = vmull_high_s16(a, x0);
        s0 = vmlal_s16(s0, vget_low_s16(b), vget_low_s16(x1));
        s1 = vmlal_high_s16(s1, b, x1);
        acc = vfmaq_n_f32(acc, vcvtq_f32_s32(vaddq_s32(s0, s1)), x.scale[k / block]);
    }
    total = vaddvq_f32(acc);
#endif
    for (std::size_t b = k / block; k < n; ++b) {
        std::int32_t sum = 0;
        for (const auto end = std::min(n, k + block); k < end; ++k) sum += std::int32_t(q[k]) * v[k];
        total += float(sum) * x.scale[b];
    }
    return total;
}

#if defined(__ARM_NEON)
inline float32x4_t expNonPositive(float32x4_t x) {
    x = vmaxq_f32(x, vdupq_n_f32(-87.0f));
    const float32x4_t n = vrndnq_f32(vmulq_n_f32(x, 1.44269504088896341f));
    x = vfmsq_f32(x, n, vdupq_n_f32(0.693359375f));
    x = vfmsq_f32(x, n, vdupq_n_f32(-2.12194440e-4f));
    float32x4_t p = vdupq_n_f32(1.9875691500e-4f);
    p = vfmaq_f32(vdupq_n_f32(1.3981999507e-3f), p, x);
    p = vfmaq_f32(vdupq_n_f32(8.3334519073e-3f), p, x);
    p = vfmaq_f32(vdupq_n_f32(4.1665795894e-2f), p, x);
    p = vfmaq_f32(vdupq_n_f32(1.6666665459e-1f), p, x);
    p = vfmaq_f32(vdupq_n_f32(5.0000001201e-1f), p, x);
    p = vfmaq_f32(vaddq_f32(x, vdupq_n_f32(1.0f)), p, vmulq_f32(x, x));
    const int32x4_t power = vshlq_n_s32(vaddq_s32(vcvtq_s32_f32(n), vdupq_n_s32(127)), 23);
    return vmulq_f32(p, vreinterpretq_f32_s32(power));
}
#endif
double sumExp(std::span<const float> values, float best) {
    std::size_t k = 0;
    double sum = 0;
#if defined(__ARM_NEON)
    const float32x4_t shift = vdupq_n_f32(best);
    while (k + 8 <= values.size()) {
        float32x4_t s0 = vdupq_n_f32(0), s1 = vdupq_n_f32(0);
        for (const auto end = std::min(values.size(), k + 512); k + 8 <= end; k += 8) {
            s0 = vaddq_f32(s0, expNonPositive(vsubq_f32(vld1q_f32(values.data() + k), shift)));
            s1 = vaddq_f32(s1, expNonPositive(vsubq_f32(vld1q_f32(values.data() + k + 4), shift)));
        }
        sum += double(vaddvq_f32(vaddq_f32(s0, s1)));
    }
#endif
    for (; k < values.size(); ++k) sum += std::exp(double(values[k] - best));
    return sum;
}
bool emittable(std::string_view word) {
    return !word.empty() && std::all_of(word.begin(), word.end(), [](char c) { return (c >= 'a' && c <= 'z') || c == '\''; });
}
}

std::shared_ptr<const NeuralWordModel> NeuralWordModel::load(std::span<const std::byte> bytes, std::shared_ptr<const void> owner) {
    require(bytes.size() >= headerBytes && std::memcmp(bytes.data(), "NSLM", 4) == 0, "not an NSS language model");
    require(u32(bytes, 4) == 1, "unsupported NSS model version");
    require(reinterpret_cast<std::uintptr_t>(bytes.data()) % 4 == 0, "misaligned NSS model bytes");
    std::shared_ptr<NeuralWordModel> model(new NeuralWordModel());
    auto& m = *model;
    m.owner_ = std::move(owner);
    m.arch_ = u32(bytes, 8);
    const auto flags = u32(bytes, 12);
    m.vocabulary_ = u32(bytes, 16); m.embed_ = u32(bytes, 20); m.hidden_ = u32(bytes, 24);
    m.projection_ = u32(bytes, 28); const std::size_t layers = u32(bytes, 32); m.features_ = u32(bytes, 36);
    m.pad_ = std::int32_t(u32(bytes, 44)); m.unk_ = std::int32_t(u32(bytes, 48));
    m.bos_ = std::int32_t(u32(bytes, 52)); m.eos_ = std::int32_t(u32(bytes, 56));
    m.unkShare_ = f32(bytes, 60);
    const std::size_t sections = u32(bytes, 64);
    m.unkCenter_ = f32(bytes, 68);
    std::memcpy(m.vocabularySHA_.data(), bytes.data() + 80, 32);
    m.cifg_ = flags & flagCIFG;
    const bool tied = flags & flagTied, projected = flags & flagProjection;
    require(m.arch_ == lstmArch || m.arch_ == gruArch, "unsupported NSS architecture");
    require(m.vocabulary_ > 4 && m.vocabulary_ < (1u << 24) && m.embed_ && m.hidden_ && layers && layers <= 8, "invalid NSS dimensions");
    require(projected == (m.projection_ > 0) && m.features_ == (projected ? m.projection_ : m.hidden_), "invalid NSS projection");
    require(!tied || m.features_ == m.embed_, "tied NSS embeddings need features == embed");
    for (auto id : {m.pad_, m.unk_, m.bos_, m.eos_}) require(id >= 0 && std::size_t(id) < m.vocabulary_, "invalid NSS special id");
    require(std::isfinite(m.unkShare_) && m.unkShare_ > 0 && m.unkShare_ <= 1, "invalid NSS <unk> lexicon share");
    require(std::isfinite(m.unkCenter_) && m.unkCenter_ <= 0, "invalid NSS <unk> center");
    require(sections < 256 && headerBytes + sections * recordBytes <= bytes.size(), "truncated NSS section table");

    struct Record { std::uint32_t kind, rows, cols; std::size_t offset, size; };
    std::unordered_map<std::uint32_t, Record> records;
    for (std::size_t i = 0; i < sections; ++i) {
        const auto at = headerBytes + i * recordBytes;
        Record r{u32(bytes, at + 4), u32(bytes, at + 8), u32(bytes, at + 12), std::size_t(u64(bytes, at + 16)), std::size_t(u64(bytes, at + 24))};
        require(r.offset % 4 == 0 && r.offset <= bytes.size() && r.size <= bytes.size() - r.offset, "NSS section out of bounds");
        require(records.emplace(u32(bytes, at), r).second, "duplicate NSS section");
    }
    auto matrix = [&](std::uint32_t id, std::size_t rows, std::size_t cols) {
        auto found = records.find(id);
        require(found != records.end(), "missing NSS matrix");
        const auto& r = found->second;
        const auto values = rows * cols, scales = (values + 3) / 4 * 4;
        require(r.kind == int8Kind && r.rows == rows && r.cols == cols && r.size == scales + 4 * rows, "invalid NSS matrix");
        return Matrix{reinterpret_cast<const std::int8_t*>(bytes.data() + r.offset), reinterpret_cast<const float*>(bytes.data() + r.offset + scales), rows, cols};
    };
    auto floats = [&](std::uint32_t id, std::size_t rows, std::size_t cols) {
        auto found = records.find(id);
        require(found != records.end(), "missing NSS vector");
        const auto& r = found->second;
        require(r.kind == floatKind && r.rows == rows && r.cols == cols && r.size == 4 * rows * cols, "invalid NSS vector");
        return reinterpret_cast<const float*>(bytes.data() + r.offset);
    };
    m.embedding_ = matrix(embeddingSection, m.vocabulary_, m.embed_);
    m.output_ = tied ? m.embedding_ : matrix(outputSection, m.vocabulary_, m.features_);
    m.outputBias_ = floats(outputBiasSection, 1, m.vocabulary_);
    const bool lstm = m.arch_ == lstmArch;
    m.recurrent_ = lstm ? m.features_ : m.hidden_;
    const std::size_t gates = lstm ? (m.cifg_ ? 3 : 4) : 3;
    std::size_t input = m.embed_;
    for (std::size_t layer = 0; layer < layers; ++layer) {
        Layer l;
        l.input = input;
        l.gates = matrix(std::uint32_t(layerSection(layer, 0)), gates * m.hidden_, input + m.recurrent_);
        l.bias = floats(std::uint32_t(layerSection(layer, 1)), lstm ? 1 : 2, gates * m.hidden_);
        if (lstm && projected) l.projection = matrix(std::uint32_t(layerSection(layer, 2)), m.projection_, m.hidden_);
        m.layers_.push_back(l);
        input = m.recurrent_;
    }
    if (!lstm && projected) m.gruProjection_ = matrix(gruProjectionSection, m.projection_, m.hidden_);
    m.stateSize_ = layers * (lstm ? m.recurrent_ + m.hidden_ : m.hidden_);
    for (const auto& matrixView : {m.embedding_, m.output_, m.gruProjection_})
        for (std::size_t row = 0; row < matrixView.rows; ++row) require(std::isfinite(matrixView.scale[row]), "non-finite NSS scale");

    auto vocab = records.find(vocabularySection);
    require(vocab != records.end() && vocab->second.kind == vocabularyKind && vocab->second.rows == m.vocabulary_, "missing NSS vocabulary");
    const auto& v = vocab->second;
    const auto table = 4 * (m.vocabulary_ + 1);
    require(v.size >= table, "truncated NSS vocabulary");
    m.wordOffsets_ = reinterpret_cast<const std::uint32_t*>(bytes.data() + v.offset);
    m.wordText_ = reinterpret_cast<const char*>(bytes.data() + v.offset + table);
    for (std::size_t id = 0; id < m.vocabulary_; ++id)
        require(m.wordOffsets_[id] <= m.wordOffsets_[id + 1] && m.wordOffsets_[id + 1] <= v.size - table, "invalid NSS vocabulary offsets");
    m.sorted_.reserve(m.vocabulary_ - 4);
    for (std::size_t id = 4; id < m.vocabulary_; ++id) m.sorted_.push_back(std::int32_t(id));
    std::sort(m.sorted_.begin(), m.sorted_.end(), [&](auto a, auto b) { return m.word(a) < m.word(b); });
    for (std::size_t i = 1; i < m.sorted_.size(); ++i) require(m.word(m.sorted_[i - 1]) != m.word(m.sorted_[i]), "duplicate NSS vocabulary word");
    return model;
}

std::string_view NeuralWordModel::word(std::int32_t id) const {
    if (id < 0 || std::size_t(id) >= vocabulary_) throw std::out_of_range("NSS word id");
    return {wordText_ + wordOffsets_[id], wordOffsets_[id + 1] - wordOffsets_[id]};
}
std::int32_t NeuralWordModel::exact(std::string_view word) const {
    auto found = std::lower_bound(sorted_.begin(), sorted_.end(), word, [&](std::int32_t id, std::string_view key) { return this->word(id) < key; });
    return found != sorted_.end() && this->word(*found) == word ? *found : unk_;
}
std::int32_t NeuralWordModel::contextID(std::string_view word) const {
    if (word.find_first_not_of('\'') == std::string_view::npos) return -1;
    std::string lower(word);
    for (auto& c : lower) if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
    auto id = exact(lower);
    if (id != unk_) return id;
    auto first = lower.find_first_not_of('\''), last = lower.find_last_not_of('\'');
    return first == 0 && last == lower.size() - 1 ? unk_ : exact(std::string_view(lower).substr(first, last - first + 1));
}

void NeuralWordModel::step(std::int32_t token, std::span<const float> state, std::span<float> next, std::span<float> features) const {
    if (token < 0 || std::size_t(token) >= vocabulary_) throw std::out_of_range("NSS token");
    if (state.size() != stateSize_ || next.size() != stateSize_ || features.size() != features_) throw std::invalid_argument("NSS state size");
    thread_local std::vector<float> previous, input, gates, cell;
    thread_local Activations x, xh;
    previous.assign(state.begin(), state.end());
    if (token == bos_) std::fill(previous.begin(), previous.end(), 0.0f);
    const auto* row = embedding_.q + std::size_t(token) * embed_;
    const auto scale = embedding_.scale[token];
    input.resize(embed_);
    for (std::size_t k = 0; k < embed_; ++k) input[k] = float(row[k]) * scale;
    const bool lstm = arch_ == lstmArch;
    std::size_t offset = 0;
    for (const auto& layer : layers_) {
        const auto& w = layer.gates;
        const float* h = previous.data() + offset;
        gates.resize(w.rows);
        if (lstm) {
            input.resize(layer.input + recurrent_);
            std::copy(h, h + recurrent_, input.begin() + std::ptrdiff_t(layer.input));
            quantize(input.data(), w.cols, x);
            for (std::size_t r = 0; r < w.rows; ++r) gates[r] = w.scale[r] * dot(w.q + r * w.cols, x, w.cols) + layer.bias[r];
            const float* c = h + recurrent_;
            cell.resize(hidden_);
            std::vector<float>& m = input;
            m.assign(hidden_, 0.0f);
            for (std::size_t j = 0; j < hidden_; ++j) {
                float value, gate;
                if (cifg_) {
                    const auto f = sigmoid(gates[j]);
                    value = f * c[j] + (1 - f) * std::tanh(gates[hidden_ + j]);
                    gate = sigmoid(gates[2 * hidden_ + j]);
                } else {
                    value = sigmoid(gates[hidden_ + j]) * c[j] + sigmoid(gates[j]) * std::tanh(gates[2 * hidden_ + j]);
                    gate = sigmoid(gates[3 * hidden_ + j]);
                }
                cell[j] = value;
                m[j] = gate * std::tanh(value);
            }
            float* outH = next.data() + offset;
            if (layer.projection.q) {
                const auto& p = layer.projection;
                quantize(m.data(), p.cols, x);
                for (std::size_t r = 0; r < p.rows; ++r) outH[r] = p.scale[r] * dot(p.q + r * p.cols, x, p.cols);
            } else std::copy(m.begin(), m.end(), outH);
            std::copy(cell.begin(), cell.end(), next.data() + offset + recurrent_);
            input.assign(outH, outH + recurrent_);
            offset += recurrent_ + hidden_;
        } else {
            cell.resize(w.rows);
            quantize(input.data(), layer.input, x);
            quantize(h, hidden_, xh);
            for (std::size_t r = 0; r < w.rows; ++r) {
                const auto* q = w.q + r * w.cols;
                gates[r] = w.scale[r] * dot(q, x, layer.input) + layer.bias[r];
                cell[r] = w.scale[r] * dot(q + layer.input, xh, hidden_) + layer.bias[w.rows + r];
            }
            float* outH = next.data() + offset;
            for (std::size_t j = 0; j < hidden_; ++j) {
                const auto reset = sigmoid(gates[j] + cell[j]), update = sigmoid(gates[hidden_ + j] + cell[hidden_ + j]);
                const auto candidate = std::tanh(gates[2 * hidden_ + j] + reset * cell[2 * hidden_ + j]);
                outH[j] = (1 - update) * candidate + update * h[j];
            }
            input.assign(outH, outH + hidden_);
            offset += hidden_;
        }
    }
    if (gruProjection_.q) {
        quantize(input.data(), gruProjection_.cols, x);
        for (std::size_t r = 0; r < gruProjection_.rows; ++r)
            features[r] = gruProjection_.scale[r] * dot(gruProjection_.q + r * gruProjection_.cols, x, gruProjection_.cols);
    } else std::copy(input.begin(), input.begin() + std::ptrdiff_t(features_), features.begin());
}

void NeuralWordModel::wordLogProbabilities(std::span<const float> features, std::span<float> out) const {
    if (features.size() != features_ || out.size() != vocabulary_) throw std::invalid_argument("NSS output size");
    thread_local Activations x;
    quantize(features.data(), features_, x);
    float best = -std::numeric_limits<float>::infinity();
    for (std::size_t v = 0; v < vocabulary_; ++v) {
        out[v] = output_.scale[v] * dot(output_.q + v * features_, x, features_) + outputBias_[v];
        if (std::int32_t(v) != pad_ && std::int32_t(v) != bos_ && std::int32_t(v) != eos_) best = std::max(best, out[v]);
    }
    for (auto id : {pad_, bos_, eos_}) out[std::size_t(id)] = -std::numeric_limits<float>::infinity();
    const auto norm = float(double(best) + std::log(sumExp(out, best)));
    for (auto& value : out) value -= norm;
}

UnknownWordTable UnknownWordTable::build(const NeuralWordModel& model, const PackedLexicon& lexicon) {
    double mass = 0;
    UnknownWordTable table;
    for (std::uint32_t id = 0; id < lexicon.wordCount(); ++id) {
        auto word = lexicon.word(id);
        if (emittable(word) && model.exact(word) == model.unknown()) { mass += double(lexicon.frequency(id)) + 1; ++table.oovWords; }
    }
    if (mass <= 0) throw std::invalid_argument("lexicon has no words outside the NSS vocabulary");
    table.logShare = std::log(double(model.unknownLexiconShare()));
    table.logOOVMass = std::log(mass);
    return table;
}
double UnknownWordTable::logWordGivenUnknown(double unigramMass) const { return logShare + std::log(unigramMass) - logOOVMass; }

ContextRing::ContextRing(std::shared_ptr<const NeuralWordModel> model, std::size_t capacity, std::size_t window)
    : model_(std::move(model)), capacity_(capacity), window_(window) {
    if (!model_ || !window_ || capacity_ < window_) throw std::invalid_argument("invalid NSS ring");
    rootState_.assign(model_->stateSize(), 0.0f);
    rootFeatures_.assign(model_->featureSize(), 0.0f);
    model_->step(model_->sentenceStart(), rootState_, rootState_, rootFeatures_);
    states_.assign(capacity_ * model_->stateSize(), 0.0f);
    features_.assign(capacity_ * model_->featureSize(), 0.0f);
    ids_.assign(capacity_, -1);
}
std::span<const float> ContextRing::stateAt(std::size_t position) const {
    if (!position) return rootState_;
    const auto n = model_->stateSize();
    return std::span<const float>(states_).subspan((position - 1) % capacity_ * n, n);
}
std::span<const float> ContextRing::featuresAt(std::size_t position) const {
    if (!position) return rootFeatures_;
    const auto n = model_->featureSize();
    return std::span<const float>(features_).subspan((position - 1) % capacity_ * n, n);
}
ContextRing::Sync ContextRing::sync(std::span<const std::int32_t> context) {
    const auto n = context.size(), first = oldest();
    std::size_t bestStart = 0, bestMatched = 0;
    for (std::size_t start = n < window_ ? 0 : length_;; --start) {
        if (start + 1 < first) {
            if (start) break;
        } else {
            std::size_t matched = 0;
            while (matched < n && start + matched < length_ && idAt(start + matched + 1) == context[matched]) ++matched;
            if (matched > bestMatched) { bestStart = start; bestMatched = matched; }
        }
        if (!start) break;
    }
    const auto position = bestStart + bestMatched;
    auto state = stateAt(position), features = featuresAt(position);
    std::vector<float> s(state.begin(), state.end()), f(features.begin(), features.end());
    length_ = position;
    for (std::size_t k = bestMatched; k < n; ++k) {
        model_->step(context[k], s, s, f);
        ++length_; ++steps_;
        const auto slot = (length_ - 1) % capacity_;
        ids_[slot] = context[k];
        std::copy(s.begin(), s.end(), states_.begin() + std::ptrdiff_t(slot * s.size()));
        std::copy(f.begin(), f.end(), features_.begin() + std::ptrdiff_t(slot * f.size()));
    }
    return {bestMatched, n - bestMatched};
}

NeuralSearchSpace::NeuralSearchSpace(std::shared_ptr<const NeuralWordModel> model, UnknownWordTable unknown, std::size_t capacity, std::size_t window)
    : model_(model), unknown_(unknown), ring_(std::move(model), capacity, window), logProbabilities_(model_->vocabularySize()) {}
ContextRing::Sync NeuralSearchSpace::update(std::span<const std::string> context) {
    std::vector<std::int32_t> ids;
    ids.reserve(context.size());
    for (const auto& word : context) if (auto id = model_->contextID(word); id >= 0) ids.push_back(id);
    if (ready_ && ids == ids_) return {ids.size(), 0};
    auto result = ring_.sync(ids);
    model_->wordLogProbabilities(ring_.features(), logProbabilities_);
    ids_ = std::move(ids); ready_ = true; arcsReady_ = false; ++revision_;
    return result;
}
double NeuralSearchSpace::score(std::string_view word, double unigramMass, std::span<const float> values) const {
    const auto id = model_->exact(word);
    if (id != model_->unknown()) return values[std::size_t(id)];
    return double(values[std::size_t(model_->unknown())]) + unknown_.logWordGivenUnknown(unigramMass);
}
double NeuralSearchSpace::logProbability(std::string_view word, double unigramMass) const {
    if (!ready_) throw std::logic_error("NSS distribution read before update");
    return score(word, unigramMass, logProbabilities_);
}
const std::vector<std::pair<std::int32_t, float>>& NeuralSearchSpace::arcs(float threshold, std::size_t limit) const {
    if (!ready_) throw std::logic_error("NSS arcs read before update");
    if (arcsReady_ && arcsThreshold_ == threshold && arcsLimit_ == limit) return arcs_;
    arcs_.clear();
    for (std::size_t id = 4; id < logProbabilities_.size(); ++id)
        if (std::int32_t(id) != model_->unknown() && logProbabilities_[id] > threshold) arcs_.emplace_back(std::int32_t(id), logProbabilities_[id]);
    auto order = [](const auto& a, const auto& b) { return a.second == b.second ? a.first < b.first : a.second > b.second; };
    if (arcs_.size() > limit) { std::partial_sort(arcs_.begin(), arcs_.begin() + std::ptrdiff_t(limit), arcs_.end(), order); arcs_.resize(limit); }
    else std::sort(arcs_.begin(), arcs_.end(), order);
    arcsThreshold_ = threshold; arcsLimit_ = limit; arcsReady_ = true;
    return arcs_;
}
double NeuralSearchSpace::sequence(std::span<const std::string> words, const std::function<double(std::string_view)>& unigramMass) const {
    if (!ready_) throw std::logic_error("NSS sequence read before update");
    double total = 0;
    std::vector<float> state, features, values;
    std::span<const float> current = logProbabilities_;
    for (std::size_t k = 0; k < words.size(); ++k) {
        total += score(words[k], unigramMass(words[k]), current);
        if (k + 1 == words.size()) break;
        auto id = model_->contextID(words[k]);
        if (id < 0) continue;
        if (state.empty()) {
            state.assign(ring_.state().begin(), ring_.state().end());
            features.assign(ring_.features().begin(), ring_.features().end());
            values.resize(model_->vocabularySize());
        }
        model_->step(id, state, state, features);
        model_->wordLogProbabilities(features, values);
        current = values;
    }
    return total;
}
}
