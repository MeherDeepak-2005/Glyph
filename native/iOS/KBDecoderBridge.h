#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@class KBNativeSafetyLexicon;

// iOS ownership and transport. Portable algorithms live exclusively in DecoderCore.

// The English dictionary, langdata.bin (KBLM v7: unigram frequencies and the spelling trie).
@interface KBPackedLexicon : NSObject
// Retains this exact immutable NSData object; C++ borrows its bytes without a copy.
- (nullable instancetype)initWithBacking:(NSObject *)backing error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSUInteger formatVersion;
@property(nonatomic, readonly) NSUInteger wordCount;
@property(nonatomic, readonly) const void *backingAddress;
// Installs the safety-blocked words as a word-ID bitset, once, before any decode: the
// decoder never emits them afterwards.
- (void)installBlockedFromSafety:(KBNativeSafetyLexicon *)safety;
// Installs the spelling policies (langdata.kbmodern) once, before any decode. NO when the
// sidecar is malformed or was built for a different dictionary; decoding then runs without them.
- (BOOL)installModernData:(NSData *)data;
@end

// The decoder's letter grid (native SpatialModel). The app installs its layout pack's grid
// once, before decoding; the built-in grid is QWERTY.
@interface KBKeyGrid : NSObject
// rows: distinct lowercase ASCII letters, all 26; offsets: one per row, in key widths.
// Returns NO, keeping the current grid, for anything else.
+ (BOOL)installRows:(NSArray<NSString *> *)rows offsets:(NSArray<NSNumber *> *)offsets;
// The installed grid's letters, row by row ("qwertyuiopasdfghjklzxcvbnm").
+ (NSString *)letters;
// Column (with the row offset) and row of a letter; NO for a letter off the grid.
+ (BOOL)position:(uint8_t)letter x:(double *)x y:(double *)y;
@end

// Mutable native trie of dynamic words. Caller serializes mutation (Lexicon's lock).
@interface KBMutableTrie : NSObject
- (void)insertWord:(NSString *)word frequency:(int64_t)frequency wordID:(int32_t)wordID;
- (BOOL)containsWord:(NSString *)word;
@end

// Immutable, cached until a vocabulary-learning event changes the boosts.
@interface KBGenerationSnapshot : NSObject
- (instancetype)initWithBoosts:(NSDictionary<NSString *, NSNumber *> *)boosts
    blockedWords:(NSArray<NSString *> *)blocked;
- (instancetype)init NS_UNAVAILABLE;
@end

// The vocabulary one decode reads. Retains the mapping and copy-on-write mutable
// snapshots. Construct under the Lexicon lock, then release that lock before decoding.
@interface KBGenerationLexicon : NSObject
- (instancetype)initWithPacked:(nullable KBPackedLexicon *)packed supplementary:(KBMutableTrie *)supplementary
    personal:(KBMutableTrie *)personal snapshot:(KBGenerationSnapshot *)snapshot;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)containsWord:(NSString *)word;
@end

// How often the user committed each word, as one immutable snapshot.
@interface KBPersonalCounts : NSObject
@property(nonatomic, readonly) uint64_t revision;
- (instancetype)initWithUnigrams:(NSDictionary<NSString *, NSNumber *> *)unigrams;
@end

@interface KBScoredRow : NSObject
@property(nonatomic, readonly) NSString *word;
@property(nonatomic, readonly) double cost, logFrequency, language, score;
@end
// The word Space commits in place of the typed text (nil: keep it), and by how much its
// score beats the typed text's.
@interface KBCorrectionResult : NSObject
@property(nonatomic, readonly, nullable) NSString *word;
@property(nonatomic, readonly) double margin;
@end

@interface KBProcessedGlide : NSObject
@property(nonatomic, readonly) NSData *points, *dwell;
@property(nonatomic, readonly) NSArray<NSNumber *> *pivots;
@end
@interface KBNativeGlide : NSObject
+ (nullable KBProcessedGlide *)preprocess:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers
    xPitch:(double)xPitch yPitch:(double)yPitch spacing:(double)spacing times:(nullable NSData *)times;
+ (NSData *)toGrid:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)xPitch yPitch:(double)yPitch;
+ (nullable NSNumber *)shapeCost:(NSString *)word points:(NSData *)points band:(int)band direction:(double)direction;
@end

// Touch adaptation and key-target priors (native Adaptation).
@interface KBNumericPolicy : NSObject
+ (NSArray<NSNumber *> *)touch:(NSArray<NSNumber *> *)state x:(double)x y:(double)y observe:(BOOL)observe;
+ (NSArray<NSNumber *> *)characterPriors:(NSArray<NSNumber *> *)frequencies;
+ (NSArray<NSNumber *> *)contextualPriors:(NSArray<NSString *> *)letters baseLetters:(NSArray<NSString *> *)baseLetters values:(NSArray<NSNumber *> *)values;
@end

@interface KBCancellationToken : NSObject
- (void)cancel;
@end
@interface KBEngineResult : NSObject
@property(nonatomic, readonly) NSArray<NSString *> *suggestions;
@property(nonatomic, readonly) NSArray<KBScoredRow *> *rows;
// One per row: "typed", "fuzzyLexicon" or "splitCorrection".
@property(nonatomic, readonly) NSArray<NSString *> *sources;
@property(nonatomic, readonly) KBCorrectionResult *correction;
@property(nonatomic, readonly) BOOL cancelled;
@end
// The word-level neural search space LM (tools/nss `.nsslm`). The file is mapped, not
// copied: its int8 weights stay clean, evictable pages.
@interface KBNeuralWordModel : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSUInteger byteCount;
@end
// The shared English engine: the neural search space over the dictionary
// (kb::Engine with EngineOptions{}: exact scores with the unigram floor).
@interface KBSharedEngine : NSObject
// Nil when the engine cannot be built (no dictionary, or a corrupt one); the reason is logged.
- (nullable instancetype)initWithLexicon:(KBGenerationLexicon *)lexicon neural:(KBNeuralWordModel *)neural
    safety:(nullable KBNativeSafetyLexicon *)safety;
// Builds the NSS graph now, off the first decode that would otherwise pay for it. Call it on
// the queue that serializes this engine's decodes.
- (void)prepareNeuralSearchSpace;
- (nullable KBEngineResult *)decodeWord:(NSString *)word normalized:(NSString *)normalized context:(NSArray<NSString *> *)context
    identity:(NSData *)identity tapOffsets:(nullable NSData *)offsets tapValidity:(nullable NSData *)validity
    lexicon:(KBGenerationLexicon *)lexicon personal:(KBPersonalCounts *)personal
    kept:(BOOL)kept token:(KBCancellationToken *)token error:(NSError **)error
    NS_SWIFT_NAME(decode(word:normalized:context:identity:tapOffsets:tapValidity:lexicon:personal:kept:token:));
- (void)memoryPressure;
@end
@interface KBPersonalState : NSObject
@property(nonatomic, readonly) uint64_t epoch;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *unigrams;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *confirmed;
- (KBPersonalCounts *)snapshot;
- (void)install:(KBPersonalCounts *)counts confirmed:(NSDictionary<NSString *, NSNumber *> *)confirmed epoch:(uint64_t)epoch;
- (void)reset:(uint64_t)epoch;
- (void)learn:(NSString *)word;
- (void)demote:(NSString *)word;
- (void)confirm:(NSString *)word;
- (void)releaseKeep:(NSString *)word;
- (BOOL)kept:(NSString *)word;
- (NSInteger)count:(NSString *)word;
- (BOOL)prune;
- (BOOL)allowsAdoption:(NSString *)word count:(NSInteger)count lexicon:(KBGenerationLexicon *)lexicon;
@end
@class KBSharedGlide;
@interface KBSharedEngine (Glide)
- (KBSharedGlide *)glideSessionWithContext:(NSArray<NSString *> *)context;
@end
// One Glide gesture's stream in the neural search space.
@interface KBSharedGlide : NSObject
- (nullable NSArray<KBScoredRow *> *)update:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)x yPitch:(double)y
    lexicon:(KBGenerationLexicon *)lexicon personal:(KBPersonalCounts *)personal dynamicWords:(NSArray<NSString *> *)dynamic error:(NSError **)error;
- (void)cancel;
@end
// Immutable kb::SafetyLexicon over retained KBGUARD1 bytes: parsing, validation, the
// action/language/penalty policy and lookups are native. Terms must already be normalized
// at the platform boundary (KBSafetyLexicon.normalize). Actions: 0 allow, 1 demote,
// 2 suppress-suggest, 3 suppress-always. Languages: 0 none, 1 English, 2 Telugu, 3 Tenglish.
@interface KBNativeSafetyLexicon : NSObject
- (nullable instancetype)initWithData:(NSData *)data error:(NSError **)error;
@property(nonatomic, readonly) NSUInteger entryCount;
- (uint8_t)actionForNormalized:(NSString *)term;
- (uint8_t)languageForNormalized:(NSString *)term;
- (double)penaltyForNormalized:(NSString *)term;
// Every suppress-action term (normalized, sorted).
@property(nonatomic, readonly) NSArray<NSString *> *blockedTerms;
@end
@interface KBVocabularyState : NSObject
- (instancetype)initWithSafety:(nullable KBNativeSafetyLexicon *)safety;
@property(nonatomic, readonly) KBGenerationSnapshot *snapshot;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *boosts;
- (void)supplementary:(NSString *)word frequency:(NSInteger)frequency glide:(BOOL)glide;
- (BOOL)note:(NSString *)word count:(NSInteger)count allowAdoption:(BOOL)allow threshold:(NSInteger)threshold glide:(BOOL)glide
    packed:(nullable KBPackedLexicon *)packed supplementary:(KBMutableTrie *)supplementary personal:(KBMutableTrie *)personal;
- (NSArray<NSString *> *)dynamicWords:(NSUInteger)limit;
- (void)resetPersonalization;
@end
NS_ASSUME_NONNULL_END
