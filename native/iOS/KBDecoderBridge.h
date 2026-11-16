#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@class KBNativeSafetyLexicon;

@interface KBPackedLexicon : NSObject
- (nullable instancetype)initWithBacking:(NSObject *)backing error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSUInteger formatVersion;
@property(nonatomic, readonly) NSUInteger wordCount;
@property(nonatomic, readonly) const void *backingAddress;
- (void)installBlockedFromSafety:(KBNativeSafetyLexicon *)safety;
- (BOOL)installModernData:(NSData *)data;
@end

@interface KBKeyGrid : NSObject
+ (BOOL)installRows:(NSArray<NSString *> *)rows offsets:(NSArray<NSNumber *> *)offsets;
+ (NSString *)letters;
+ (BOOL)position:(uint8_t)letter x:(double *)x y:(double *)y;
@end

@interface KBMutableTrie : NSObject
- (void)insertWord:(NSString *)word frequency:(int64_t)frequency wordID:(int32_t)wordID;
- (BOOL)containsWord:(NSString *)word;
@end

@interface KBGenerationSnapshot : NSObject
- (instancetype)initWithBoosts:(NSDictionary<NSString *, NSNumber *> *)boosts
    blockedWords:(NSArray<NSString *> *)blocked;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface KBGenerationLexicon : NSObject
- (instancetype)initWithPacked:(nullable KBPackedLexicon *)packed supplementary:(KBMutableTrie *)supplementary
    personal:(KBMutableTrie *)personal snapshot:(KBGenerationSnapshot *)snapshot;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)containsWord:(NSString *)word;
@end

@interface KBPersonalCounts : NSObject
@property(nonatomic, readonly) uint64_t revision;
- (instancetype)initWithUnigrams:(NSDictionary<NSString *, NSNumber *> *)unigrams;
@end

@interface KBScoredRow : NSObject
@property(nonatomic, readonly) NSString *word;
@property(nonatomic, readonly) double cost, logFrequency, language, score;
@end
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
@property(nonatomic, readonly) NSArray<NSString *> *sources;
@property(nonatomic, readonly) KBCorrectionResult *correction;
@property(nonatomic, readonly) BOOL cancelled;
@end
@interface KBNeuralWordModel : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSUInteger byteCount;
@end
@interface KBSharedEngine : NSObject
- (nullable instancetype)initWithLexicon:(KBGenerationLexicon *)lexicon neural:(KBNeuralWordModel *)neural
    safety:(nullable KBNativeSafetyLexicon *)safety;
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
@interface KBSharedGlide : NSObject
- (nullable NSArray<KBScoredRow *> *)update:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)x yPitch:(double)y
    lexicon:(KBGenerationLexicon *)lexicon personal:(KBPersonalCounts *)personal dynamicWords:(NSArray<NSString *> *)dynamic error:(NSError **)error;
- (void)cancel;
@end
@interface KBNativeSafetyLexicon : NSObject
- (nullable instancetype)initWithData:(NSData *)data error:(NSError **)error;
@property(nonatomic, readonly) NSUInteger entryCount;
- (uint8_t)actionForNormalized:(NSString *)term;
- (uint8_t)languageForNormalized:(NSString *)term;
- (double)penaltyForNormalized:(NSString *)term;
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
