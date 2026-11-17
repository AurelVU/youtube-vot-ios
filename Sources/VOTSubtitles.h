#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Returns sorted dictionaries with text, start and end (seconds).
FOUNDATION_EXPORT NSArray<NSDictionary *> *_Nullable VOTParseSubtitleCues(NSData *data, NSError **error);
// Start inclusive, end exclusive. Empty string when no cue is active.
FOUNDATION_EXPORT NSString *VOTSubtitleText(NSArray<NSDictionary *> *cues, double seconds);
NS_ASSUME_NONNULL_END
