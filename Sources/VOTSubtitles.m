#import "VOTSubtitles.h"
#import "VOTProtocol.h"
#include <math.h>

NSArray<NSDictionary *> *VOTParseSubtitleCues(NSData *data, NSError **error) {
    id json; NSArray *items; NSMutableArray *cues;
    if (!data.length || data.length > 8 * 1024 * 1024) goto invalid;
    json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!json) return nil;
    if (![json isKindOfClass:NSDictionary.class] || ![json[@"subtitles"] isKindOfClass:NSArray.class]) goto invalid;
    items = json[@"subtitles"];
    if (items.count > 50000) goto invalid;
    cues = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        if (![item isKindOfClass:NSDictionary.class]) goto invalid;
        NSString *text = item[@"text"]; NSNumber *start = item[@"startMs"], *duration = item[@"durationMs"];
        if (![text isKindOfClass:NSString.class] || text.length > 16384 ||
            ![start isKindOfClass:NSNumber.class] || ![duration isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)start) == CFBooleanGetTypeID() || CFGetTypeID((__bridge CFTypeRef)duration) == CFBooleanGetTypeID()) goto invalid;
        double begin = start.doubleValue / 1000, length = duration.doubleValue / 1000, end = begin + length;
        if (!isfinite(begin) || !isfinite(length) || !isfinite(end) || begin < 0 || length < 0) goto invalid;
        [cues addObject:@{@"text":text, @"start":@(begin), @"end":@(end)}];
    }
    [cues sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"start"] compare:b[@"start"]]; }];
    return cues;
invalid:
    if (error) *error = VOTError(108, @"Сервис вернул некорректные субтитры.");
    return nil;
}
NSString *VOTSubtitleText(NSArray<NSDictionary *> *cues, double seconds) {
    if (!isfinite(seconds) || seconds < 0 || !cues.count) return @"";
    NSUInteger low = 0, high = cues.count;
    while (low < high) {
        NSUInteger mid = low + (high - low) / 2;
        if ([cues[mid][@"start"] doubleValue] <= seconds) low = mid + 1; else high = mid;
    }
    if (!low) return @"";
    NSDictionary *cue = cues[low - 1];
    return seconds < [cue[@"end"] doubleValue] ? cue[@"text"] : @"";
}
