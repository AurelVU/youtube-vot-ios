#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const VOTComponentVersion;
FOUNDATION_EXPORT NSString *const VOTUserAgent;
FOUNDATION_EXPORT NSData *VOTEncodeSession(NSString *uuid);
FOUNDATION_EXPORT NSData *VOTEncodeTranslation(NSString *url, double duration, NSString *language, BOOL first);
FOUNDATION_EXPORT NSData *VOTEncodeTranslationOptions(NSString *url, double duration, NSString *language, NSString *target, BOOL first, BOOL lively);
FOUNDATION_EXPORT NSData *VOTEncodeSubtitles(NSString *url, NSString *language);
FOUNDATION_EXPORT NSDictionary *_Nullable VOTDecodeSubtitles(NSData *data, NSError **error);
FOUNDATION_EXPORT NSData *VOTEncodeAudioFallback(NSString *url, NSString *translationID, NSString *videoID);
FOUNDATION_EXPORT NSDictionary<NSNumber *, id> *_Nullable VOTDecodeFields(NSData *data, NSError **error);
FOUNDATION_EXPORT NSDictionary *_Nullable VOTDecodeTranslation(NSData *data, NSError **error);
FOUNDATION_EXPORT NSString *VOTSignature(NSData *body);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *VOTRequestHeaders(NSData *body, NSString *uuid, NSString *secret, NSString *path);
FOUNDATION_EXPORT NSError *VOTError(NSInteger code, NSString *message);
NS_ASSUME_NONNULL_END
