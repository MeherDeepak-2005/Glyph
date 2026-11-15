#import "KBDecoderBridge.h"
#import <os/log.h>
#include "../DecoderCore/include/Adaptation.hpp"
#include "../DecoderCore/include/Engine.hpp"
#include "../DecoderCore/include/Glide.hpp"
#include "../DecoderCore/include/PackedLexicon.hpp"
#include "../DecoderCore/include/Personalization.hpp"
#include "../DecoderCore/include/Safety.hpp"
#include "../DecoderCore/include/SpatialModel.hpp"
#include "../DecoderCore/include/Vocabulary.hpp"
#include <cmath>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

// Native accessors for other bridge classes; not visible to Swift.
@interface KBNativeSafetyLexicon ()
- (const kb::SafetyLexicon *)nativeLexicon;
@end
@interface KBPackedLexicon ()
- (const kb::PackedLexicon *)nativeLexicon;
@end

static void KBSetError(NSError **error, const std::exception& failure) {
    if (error) *error = [NSError errorWithDomain:@"KBDecoderCore" code:1
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:failure.what()] ?: @"Native read failed"}];
}

// The two string crossings every bridge call makes. They are total functions on purpose:
// a C++ exception thrown here would unwind through Swift frames and terminate the keyboard.
//
// NSString -> UTF-8 in one allocation and one pass (-dataUsingEncoding: made an autoreleased
// NSData copy, then std::string copied it again). Swift strings are always valid UTF-16, so
// the lossy option only matters for an unpaired surrogate from Foundation, which becomes '?'.
// The engine validates the UTF-8 of every decode request itself.
static std::string KBText(NSString *text) {
    const NSUInteger length = text.length;
    if (!length) return {};
    std::string out([text maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding], '\0');
    NSUInteger used = 0;
    [text getBytes:out.data() maxLength:out.size() usedLength:&used encoding:NSUTF8StringEncoding
           options:NSStringEncodingConversionAllowLossy range:NSMakeRange(0, length) remainingRange:nullptr];
    out.resize(used);
    return out;
}
// UTF-8 -> NSString, never nil (a nil element raises in NSArray, and the properties that
// carry these strings are nonnull in Swift). Engine output is lexicon text or validated
// input, so the Latin-1 fallback, which maps every byte, is unreachable in practice.
static NSString *KBString(std::string_view text) {
    return [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSISOLatin1StringEncoding];
}
static std::vector<std::string> KBTexts(NSArray<NSString *> *values) {
    std::vector<std::string> out; for (NSString *value in values) out.push_back(KBText(value)); return out;
}
// Read numeric buffers with memcpy: caller alignment is deliberately unspecified.
static std::vector<std::optional<kb::TouchOffset>> KBTaps(NSData *offsets, NSData *validity, std::size_t count) {
    if (!offsets && !validity) return {};
    if (!offsets || !validity || count > SIZE_MAX / (2 * sizeof(double)) ||
        offsets.length != count * 2 * sizeof(double) || validity.length != count)
        throw std::invalid_argument("invalid tap buffer shape");
    auto bytes = static_cast<const std::byte *>(offsets.bytes);
    auto flags = static_cast<const std::uint8_t *>(validity.bytes);
    std::vector<std::optional<kb::TouchOffset>> taps(count);
    for (std::size_t i = 0; i < count; ++i) {
        if (flags[i] > 1) throw std::invalid_argument("invalid tap validity flag");
        if (flags[i]) {
            kb::TouchOffset tap;
            std::memcpy(&tap.dx, bytes + 2 * sizeof(double) * i, sizeof(double));
            std::memcpy(&tap.dy, bytes + (2 * i + 1) * sizeof(double), sizeof(double));
            taps[i] = tap;
        }
    }
    return taps;
}

@implementation KBPackedLexicon {
    NSData *_backingData;
    std::unique_ptr<kb::PackedLexicon> _reader;
}
- (instancetype)initWithBacking:(NSObject *)backing error:(NSError **)error {
    if ((self = [super init])) {
        // A mutable object would permit pointer invalidation after validation.
        if (![backing isKindOfClass:[NSData class]] || [backing isKindOfClass:[NSMutableData class]]) {
            if (error) *error = [NSError errorWithDomain:@"KBDecoderCore" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"Packed vocabulary backing must be immutable"}];
            return nil;
        }
        NSData *data = (NSData *)backing;
        _backingData = data;
        try { _reader = std::make_unique<kb::PackedLexicon>(std::span{
            static_cast<const std::byte *>(data.bytes), data.length}); }
        catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
    }
    return self;
}
- (void)installBlockedFromSafety:(KBNativeSafetyLexicon *)safety { _reader->installBlocked([safety nativeLexicon]->blockedTerms()); }
- (BOOL)installModernData:(NSData *)data {
    return _reader->installModern({static_cast<const std::byte *>(data.bytes), data.length});
}
- (const void *)backingAddress { return _reader->backingAddress(); }
- (const kb::PackedLexicon *)nativeLexicon { return _reader.get(); }
- (NSUInteger)formatVersion { return _reader->version(); }
- (NSUInteger)wordCount { return _reader->wordCount(); }
@end

@implementation KBKeyGrid
+ (BOOL)installRows:(NSArray<NSString *> *)rows offsets:(NSArray<NSNumber *> *)offsets {
    std::vector<std::string> storage; std::vector<std::string_view> views; std::vector<double> values;
    for (NSString *row in rows) {
        const char *utf8 = row.UTF8String;
        if (!utf8) return NO;
        storage.emplace_back(utf8);
    }
    for (const auto& row : storage) views.emplace_back(row);
    for (NSNumber *offset in offsets) values.push_back(offset.doubleValue);
    return kb::installGrid(views, values);
}
+ (NSString *)letters {
    const auto letters = kb::gridLetters();
    return [[NSString alloc] initWithBytes:letters.data() length:letters.size() encoding:NSASCIIStringEncoding];
}
+ (BOOL)position:(uint8_t)letter x:(double *)x y:(double *)y {
    const auto point = kb::grid(letter);
    if (!point) return NO;
    if (x) *x = point->x;
    if (y) *y = point->y;
    return YES;
}
@end

@interface KBMutableTrie ()
- (std::shared_ptr<const kb::MutableTrie>)nativeSnapshot;
- (kb::MutableTrie&)nativeMutable;
@end
@implementation KBMutableTrie {
    std::shared_ptr<kb::MutableTrie> _trie;
}
- (instancetype)init {
    if ((self = [super init])) _trie = std::make_shared<kb::MutableTrie>();
    return self;
}
- (std::shared_ptr<const kb::MutableTrie>)nativeSnapshot { return _trie; }
- (kb::MutableTrie&)nativeMutable { [self prepareMutation]; return *_trie; }
- (void)prepareMutation {
    if (_trie.use_count() != 1) _trie = std::make_shared<kb::MutableTrie>(*_trie);
}
- (void)insertWord:(NSString *)word frequency:(int64_t)frequency wordID:(int32_t)wordID {
    [self prepareMutation]; _trie->insert(KBText(word), frequency, wordID);
}
- (BOOL)containsWord:(NSString *)word { return _trie->contains(KBText(word)); }
@end

@interface KBGenerationSnapshot ()
- (const kb::GenerationSnapshot *)nativeSnapshot;
- (instancetype)initWithSharedGeneration:(std::shared_ptr<const kb::GenerationSnapshot>)generation;
@end
@implementation KBGenerationSnapshot {
    kb::GenerationSnapshot _snapshot;
    std::shared_ptr<const kb::GenerationSnapshot> _sharedGeneration;
}
- (instancetype)initWithBoosts:(NSDictionary<NSString *, NSNumber *> *)boosts blockedWords:(NSArray<NSString *> *)blocked {
    if ((self = [super init])) {
        for (NSString *key in boosts) _snapshot.boosts.emplace(KBText(key), boosts[key].longLongValue);
        for (NSString *key in blocked) _snapshot.blocked.insert(KBText(key));
    }
    return self;
}
- (const kb::GenerationSnapshot *)nativeSnapshot { return _sharedGeneration ? _sharedGeneration.get() : &_snapshot; }
- (instancetype)initWithSharedGeneration:(std::shared_ptr<const kb::GenerationSnapshot>)generation { if ((self = [super init])) _sharedGeneration = std::move(generation); return self; }
@end

@interface KBGenerationLexicon ()
- (kb::GenerationLexicon)nativeLexicon;
- (KBPackedLexicon *)packedOwner;
@end
@implementation KBGenerationLexicon {
    KBPackedLexicon *_packed;
    KBGenerationSnapshot *_snapshot;
    std::shared_ptr<const kb::MutableTrie> _supplementary, _personal;
}
- (instancetype)initWithPacked:(KBPackedLexicon *)packed supplementary:(KBMutableTrie *)supplementary
    personal:(KBMutableTrie *)personal snapshot:(KBGenerationSnapshot *)snapshot {
    if ((self = [super init])) {
        _packed = packed; _snapshot = snapshot;
        _supplementary = [supplementary nativeSnapshot]; _personal = [personal nativeSnapshot];
    }
    return self;
}
- (KBPackedLexicon *)packedOwner { return _packed; }
- (kb::GenerationLexicon)nativeLexicon {
    return {[_packed nativeLexicon], nullptr, _supplementary.get(), _personal.get(), [_snapshot nativeSnapshot]};
}
- (BOOL)containsWord:(NSString *)word { return [self nativeLexicon].contains(KBText(word)); }
@end

@interface KBPersonalCounts ()
- (const kb::PersonalCounts&)nativeCounts;
- (instancetype)initWithSharedCounts:(std::shared_ptr<const kb::PersonalCounts>)counts revision:(std::uint64_t)revision;
@end
@implementation KBPersonalCounts {
    kb::PersonalCounts _counts;
    std::shared_ptr<const kb::PersonalCounts> _shared;
    std::uint64_t _revision;
}
- (instancetype)initWithUnigrams:(NSDictionary<NSString *, NSNumber *> *)unigrams {
    if ((self = [super init])) {
        for (NSString *key in unigrams) _counts.unigram.emplace(KBText(key), unigrams[key].longLongValue);
    }
    return self;
}
- (const kb::PersonalCounts&)nativeCounts { return _shared ? *_shared : _counts; }
- (instancetype)initWithSharedCounts:(std::shared_ptr<const kb::PersonalCounts>)counts revision:(std::uint64_t)revision { if ((self = [super init])) { _shared = std::move(counts); _revision = revision; } return self; }
- (uint64_t)revision { return _revision; }
@end

@interface KBScoredRow ()
- (instancetype)initWithRanked:(const kb::RankedRow&)row;
@end
@implementation KBScoredRow
- (instancetype)initWithRanked:(const kb::RankedRow&)row {
    if ((self = [super init])) {
        _word = KBString(row.channel.word);
        _cost = row.channel.cost; _logFrequency = row.channel.logFrequency;
        _language = row.language; _score = row.score;
    } return self;
}
@end
static NSArray<KBScoredRow *> *KBRankedRows(const std::vector<kb::RankedRow>& rows) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.size()];
    for (const auto& row : rows) [out addObject:[[KBScoredRow alloc] initWithRanked:row]];
    return out;
}
@interface KBCorrectionResult ()
- (instancetype)initWithCorrection:(const kb::CorrectionResult&)result;
@end
@implementation KBCorrectionResult
- (instancetype)initWithCorrection:(const kb::CorrectionResult&)result {
    if ((self = [super init])) {
        if (result.word) _word = KBString(*result.word);
        _margin = result.margin;
    } return self;
}
@end

static std::vector<kb::Point> KBPoints(NSData *data) {
    static_assert(sizeof(kb::Point) == 2 * sizeof(double));
    if (data.length % sizeof(kb::Point)) throw std::invalid_argument("invalid point buffer shape");
    std::vector<kb::Point> out(data.length / sizeof(kb::Point));
    if (data.length) std::memcpy(out.data(), data.bytes, data.length); return out;
}
static NSData *KBPointData(const std::vector<kb::Point>& points) { return [NSData dataWithBytes:points.data() length:points.size() * sizeof(kb::Point)]; }
static kb::GlideLayout KBGlideLayout(NSData *keys, NSData *centers, double x, double y) {
    auto points = KBPoints(centers);
    if (keys.length != points.size()) throw std::invalid_argument("invalid key layout shape");
    kb::GlideLayout out{{}, x, y}; auto labels = static_cast<const std::uint8_t *>(keys.bytes);
    for (std::size_t i = 0; i < points.size(); ++i) out.centers.emplace_back(labels[i], points[i]); return out;
}
@interface KBProcessedGlide ()
- (instancetype)initWithGlide:(const kb::ProcessedGlide&)glide;
@end
@implementation KBProcessedGlide
- (instancetype)initWithGlide:(const kb::ProcessedGlide&)glide {
    if ((self = [super init])) {
        _points = KBPointData(glide.points); _dwell = [NSData dataWithBytes:glide.dwell.data() length:glide.dwell.size()];
        NSMutableArray *values = [NSMutableArray array]; for (auto index : glide.pivots) [values addObject:@(index)]; _pivots = values;
    } return self;
}
@end
@implementation KBNativeGlide
+ (KBProcessedGlide *)preprocess:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)x yPitch:(double)y spacing:(double)spacing times:(NSData *)times {
    std::vector<double> stamps;
    if (times) { if (times.length % sizeof(double)) throw std::invalid_argument("invalid timestamps"); stamps.resize(times.length / sizeof(double)); if (times.length) std::memcpy(stamps.data(), times.bytes, times.length); }
    auto result = kb::preprocess(KBPoints(points), KBGlideLayout(keys, centers, x, y), spacing, stamps);
    return result ? [[KBProcessedGlide alloc] initWithGlide:*result] : nil;
}
+ (NSData *)toGrid:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)x yPitch:(double)y {
    auto values = KBPoints(points); auto layout = KBGlideLayout(keys, centers, x, y);
    for (auto& value : values) value = kb::toGrid(value, layout); return KBPointData(values);
}
+ (NSNumber *)shapeCost:(NSString *)word points:(NSData *)points band:(int)band direction:(double)direction {
    auto cost = kb::shapeCost(KBText(word), KBPoints(points), band, direction); return cost ? @(*cost) : nil;
}
@end

@implementation KBNumericPolicy
+ (NSArray<NSNumber *> *)touch:(NSArray<NSNumber *> *)state x:(double)x y:(double)y observe:(BOOL)observe {
    if(state.count!=5)return @[];kb::TouchStatistics s;for(size_t i=0;i<5;++i)s[i]=state[i].doubleValue;
    if(observe){s=kb::observeTouch(s,{x,y});return @[@(s[0]),@(s[1]),@(s[2]),@(s[3]),@(s[4])];}
    const auto adjusted=kb::adjustTouch(s,{x,y});return @[@(adjusted.dx),@(adjusted.dy)];
}
+ (NSArray<NSNumber *> *)characterPriors:(NSArray<NSNumber *> *)frequencies {std::vector<double> f;for(NSNumber *n in frequencies)f.push_back(n.doubleValue);NSMutableArray *out=[NSMutableArray array];for(auto v:kb::characterPriors(f))[out addObject:@(v)];return out;}
+ (NSArray<NSNumber *> *)contextualPriors:(NSArray<NSString *> *)letters baseLetters:(NSArray<NSString *> *)baseLetters values:(NSArray<NSNumber *> *)values {std::vector<double> f;for(NSNumber *n in values)f.push_back(n.doubleValue);NSMutableArray *out=[NSMutableArray array];for(auto v:kb::contextualPriors(KBTexts(letters),KBTexts(baseLetters),f))[out addObject:@(v)];return out;}
@end

@interface KBCancellationToken ()
- (const kb::CancellationToken *)nativeToken;
@end
@implementation KBCancellationToken { kb::CancellationToken _token; }
- (void)cancel { _token.cancel(); }
- (const kb::CancellationToken *)nativeToken { return &_token; }
@end
@interface KBEngineResult ()
- (instancetype)initWithOutput:(const kb::DecodeOutput&)output;
@end
@implementation KBEngineResult
- (instancetype)initWithOutput:(const kb::DecodeOutput&)output {
    if ((self = [super init])) {
        // Indexed by kb::CandidateSource; the raw values of Swift's DecodeCandidateSource.
        static NSString *const sourceNames[] = {@"typed", @"fuzzyLexicon", @"splitCorrection"};
        NSMutableArray *suggestions = [NSMutableArray arrayWithCapacity:output.suggestions.size()];
        NSMutableArray *rows = [NSMutableArray arrayWithCapacity:output.candidates.size()];
        NSMutableArray *sources = [NSMutableArray arrayWithCapacity:output.candidates.size()];
        for (const auto& word : output.suggestions) [suggestions addObject:KBString(word)];
        for (const auto& row : output.candidates) {
            [rows addObject:[[KBScoredRow alloc] initWithRanked:row.ranked]];
            [sources addObject:sourceNames[static_cast<std::size_t>(row.source)]];
        }
        _suggestions = suggestions; _rows = rows; _sources = sources;
        _correction = [[KBCorrectionResult alloc] initWithCorrection:output.correction];
        _cancelled = output.status == kb::EngineStatus::cancelled;
    } return self;
}
@end
@implementation KBNativeSafetyLexicon {
    NSData *_bytes; // Retains the exact bytes the lexicon views.
    std::unique_ptr<const kb::SafetyLexicon> _lexicon;
}
- (instancetype)initWithData:(NSData *)data error:(NSError **)error {
    if ((self = [super init])) {
        try {
            _bytes = [data copy];
            _lexicon = std::make_unique<const kb::SafetyLexicon>(std::string_view(static_cast<const char *>(_bytes.bytes), _bytes.length));
        } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
    } return self;
}
- (NSUInteger)entryCount { return _lexicon->size(); }
- (uint8_t)actionForNormalized:(NSString *)term { return static_cast<uint8_t>(_lexicon->action(KBText(term))); }
- (uint8_t)languageForNormalized:(NSString *)term { auto language = _lexicon->language(KBText(term)); return language ? static_cast<uint8_t>(*language) : 0; }
- (double)penaltyForNormalized:(NSString *)term { return _lexicon->penalty(KBText(term)); }
- (NSArray<NSString *> *)blockedTerms {
    const auto terms = _lexicon->blockedTerms();
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:terms.size()];
    for (const auto& term : terms) [out addObject:KBString(term)];
    return out;
}
- (const kb::SafetyLexicon *)nativeLexicon { return _lexicon.get(); }
@end
@interface KBNeuralWordModel ()
- (std::shared_ptr<const kb::NeuralWordModel>)nativeModel;
@end
@implementation KBNeuralWordModel {
    NSData *_mapping;
    std::shared_ptr<const kb::NeuralWordModel> _model;
}
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    if ((self = [super init])) {
        NSData *mapping = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedAlways error:error];
        if (!mapping) return nil;
        try {
            _model = kb::NeuralWordModel::load({static_cast<const std::byte *>(mapping.bytes), mapping.length},
                std::shared_ptr<const void>(mapping.bytes, [owner = mapping](const void *) { (void)owner; }));
        } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
        _mapping = mapping;
    } return self;
}
- (NSUInteger)byteCount { return _mapping.length; }
- (std::shared_ptr<const kb::NeuralWordModel>)nativeModel { return _model; }
@end
@implementation KBSharedEngine {
    KBPackedLexicon *_resourceOwner;
    std::shared_ptr<kb::Engine> _engine;
    std::unique_ptr<kb::EngineSession> _session;
    // Immutable after init; Glide sessions share it rather than copying per gesture.
    std::shared_ptr<const std::unordered_map<std::string, double>> _penalties;
}
- (instancetype)initWithLexicon:(KBGenerationLexicon *)lexicon neural:(KBNeuralWordModel *)neural
    safety:(KBNativeSafetyLexicon *)safety {
    if (!(self = [super init])) return nil;
    // kb::Engine throws for a missing or corrupt dictionary or model. Escaping, the exception
    // unwinds through Swift and terminates the extension on every launch; nil lets the
    // keyboard keep running (KeyboardEngine records "native-engine" in Keyboard health).
    try {
        _resourceOwner = [lexicon packedOwner];
        const auto view = [lexicon nativeLexicon];
        // The engine borrows the mapped dictionary; this deleter only keeps its owner alive.
        // EngineSession retains Engine. The model keeps its own mapping alive.
        std::shared_ptr<const kb::PackedLexicon> packed(view.packed, [owner = _resourceOwner](const kb::PackedLexicon *) { (void)owner; });
        _engine = std::make_shared<kb::Engine>(packed, [neural nativeModel]);
        _session = _engine->createSession();
        // Blocked words are excluded from the search (the dictionary's blocked bitset is
        // installed at load), so ranking only applies residual in-dictionary demote penalties.
        auto residual = std::make_shared<std::unordered_map<std::string, double>>();
        if (safety) {
            view.packed->installBlocked([safety nativeLexicon]->blockedTerms());   // no-op if already installed
            for (const auto& [term, penalty] : [safety nativeLexicon]->penalties())
                if (std::isfinite(penalty) && view.packed->wordID(term)) residual->emplace(term, penalty);
        }
        _penalties = std::move(residual);
    } catch (const std::exception& failure) {
        os_log_error(OS_LOG_DEFAULT, "KBSharedEngine unavailable: %{public}s", failure.what());
        return nil;
    }
    return self;
}
- (void)prepareNeuralSearchSpace {
    try { _session->prepareNeural(); } catch (const std::exception&) {}   // the first decode reports it
}
- (KBEngineResult *)decodeWord:(NSString *)word normalized:(NSString *)normalized context:(NSArray<NSString *> *)context
    identity:(NSData *)identity tapOffsets:(NSData *)offsets tapValidity:(NSData *)validity
    lexicon:(KBGenerationLexicon *)lexicon personal:(KBPersonalCounts *)personal
    kept:(BOOL)kept token:(KBCancellationToken *)token error:(NSError **)error {
    try {
        if (identity.length != 7 * sizeof(std::uint64_t)) throw std::invalid_argument("invalid identity shape");
        kb::DecodeInput input; std::uint64_t fields[7]; std::memcpy(fields, identity.bytes, sizeof(fields));
        input.identity = {fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6]};
        input.word = KBText(word); input.normalized = KBText(normalized); input.context = KBTexts(context); input.kept = kept;
        input.taps = KBTaps(offsets, validity, input.normalized.size());
        kb::EngineView view{[lexicon nativeLexicon], &[personal nativeCounts], _penalties.get(), personal.revision};
        return [[KBEngineResult alloc] initWithOutput:_session->decode(input, view, [token nativeToken])];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
- (void)memoryPressure { _session->memoryPressure(); }
@end
static NSDictionary *KBExportCounts(const std::unordered_map<std::string, std::int64_t>& counts) {
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:counts.size()];
    for (const auto& [key,count] : counts) out[KBString(key)] = @(count);
    return out;
}
@implementation KBPersonalState { kb::Personalization _state; }
- (uint64_t)epoch { return _state.epoch(); }
- (NSDictionary *)unigrams { return KBExportCounts(_state.counts()->unigram); }
- (NSDictionary *)confirmed { return KBExportCounts(_state.confirmed()); }
- (KBPersonalCounts *)snapshot { return [[KBPersonalCounts alloc] initWithSharedCounts:_state.counts() revision:_state.revision()]; }
- (void)install:(KBPersonalCounts *)counts confirmed:(NSDictionary<NSString *,NSNumber *> *)confirmed epoch:(uint64_t)epoch {
    kb::PersonalizationSnapshot snapshot; snapshot.counts = [counts nativeCounts]; snapshot.epoch = epoch;
    for (NSString *word in confirmed) snapshot.confirmed.emplace(KBText(word), confirmed[word].longLongValue);
    _state.install(std::move(snapshot));
}
- (void)reset:(uint64_t)epoch { _state.reset(epoch); }
- (void)learn:(NSString *)word { _state.learn(KBText(word)); }
- (void)demote:(NSString *)word { _state.demote(KBText(word)); }
- (void)confirm:(NSString *)word { _state.confirm(KBText(word)); }
- (void)releaseKeep:(NSString *)word { _state.releaseKeep(KBText(word)); }
- (BOOL)kept:(NSString *)word { return _state.kept(KBText(word)); }
- (NSInteger)count:(NSString *)word { return _state.counts()->uni(KBText(word)); }
- (BOOL)prune { return _state.prune(); }
- (BOOL)allowsAdoption:(NSString *)word count:(NSInteger)count lexicon:(KBGenerationLexicon *)lexicon { return _state.allowsAdoption(KBText(word), count, [lexicon nativeLexicon]); }
@end
@interface KBSharedGlide ()
- (instancetype)initWithEngine:(std::shared_ptr<kb::Engine>)engine penalties:(std::shared_ptr<const std::unordered_map<std::string,double>>)penalties context:(NSArray<NSString *> *)context;
@end
@implementation KBSharedEngine (Glide)
- (KBSharedGlide *)glideSessionWithContext:(NSArray<NSString *> *)context {
    return [[KBSharedGlide alloc] initWithEngine:_engine penalties:_penalties context:context];
}
@end
@implementation KBSharedGlide {
    std::unique_ptr<kb::EngineSession> _session;
    std::shared_ptr<const std::unordered_map<std::string,double>> _penalties;
    kb::CancellationToken _token;
}
- (instancetype)initWithEngine:(std::shared_ptr<kb::Engine>)engine penalties:(std::shared_ptr<const std::unordered_map<std::string,double>>)penalties context:(NSArray<NSString *> *)context {
    if ((self = [super init])) { _session = engine->createSession(); _session->beginGlide(KBTexts(context)); _penalties = std::move(penalties); } return self;
}
- (NSArray<KBScoredRow *> *)update:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)x yPitch:(double)y
    lexicon:(KBGenerationLexicon *)lexicon personal:(KBPersonalCounts *)personal dynamicWords:(NSArray<NSString *> *)dynamic error:(NSError **)error {
    try {
        auto layout = KBGlideLayout(keys,centers,x,y); auto path = KBPoints(points); auto words = KBTexts(dynamic);
        kb::EngineView view{[lexicon nativeLexicon], &[personal nativeCounts], _penalties.get(), personal.revision};
        return KBRankedRows(_session->updateGlide(path,layout,view,words,&_token));
    } catch (const std::exception& e) { KBSetError(error,e); return nil; }
}
- (void)cancel { _token.cancel(); }
@end
@implementation KBVocabularyState { kb::VocabularyState _state; }
- (instancetype)initWithSafety:(KBNativeSafetyLexicon *)safety {if((self=[super init])){std::unordered_set<std::string> words;if(safety)for(auto&word:[safety nativeLexicon]->blockedTerms())words.insert(std::move(word));_state.setBlocked(std::move(words));}return self;}
- (KBGenerationSnapshot *)snapshot {return [[KBGenerationSnapshot alloc] initWithSharedGeneration:_state.snapshot()];}
- (NSDictionary *)boosts {return KBExportCounts(_state.snapshot()->boosts);}
- (void)supplementary:(NSString *)word frequency:(NSInteger)frequency glide:(BOOL)glide {_state.supplementary(KBText(word),frequency,glide);}
- (BOOL)note:(NSString *)word count:(NSInteger)count allowAdoption:(BOOL)allow threshold:(NSInteger)threshold glide:(BOOL)glide
    packed:(KBPackedLexicon *)packed supplementary:(KBMutableTrie *)supplementary personal:(KBMutableTrie *)personal {
    auto supp=[supplementary nativeSnapshot];
    auto& mutablePersonal=[personal nativeMutable];kb::GenerationLexicon lexicon{[packed nativeLexicon],nullptr,supp.get(),&mutablePersonal,nullptr};
    return _state.noteUse(lexicon,mutablePersonal,KBText(word),count,allow,threshold,glide);
}
- (NSArray<NSString *> *)dynamicWords:(NSUInteger)limit {
    const auto words = _state.dynamicWords(limit);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:words.size()];
    for (const auto& word : words) [out addObject:KBString(word)];
    return out;
}
- (void)resetPersonalization {_state.resetPersonalization();}
@end
