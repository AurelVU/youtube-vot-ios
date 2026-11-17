#import <Foundation/Foundation.h>
#import <dlfcn.h>
#include <math.h>
static int failures;
#define CHECK(c,m) do { if (!(c)) { NSLog(@"FAIL: %s",m); failures++; } } while(0)
static NSData *JSON(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
int main(void) { @autoreleasepool {
    NSArray *(*parse)(NSData *, NSError **) = dlsym(RTLD_DEFAULT, "VOTParseSubtitleCues");
    NSString *(*text)(NSArray *, double) = dlsym(RTLD_DEFAULT, "VOTSubtitleText");
    CHECK(parse && text, "subtitle parser and timed lookup available");
    if (!parse || !text) return 1;
    NSError *error = nil;
    NSArray *cues = parse(JSON(@"{\"containsTokens\":false,\"subtitles\":[{\"text\":\"second\",\"startMs\":2000,\"durationMs\":1500},{\"text\":\"first\",\"startMs\":500,\"durationMs\":1500}]}"), &error);
    CHECK(!error && cues.count == 2 && [cues[0][@"start"] isEqual:@0.5] && [cues[1][@"end"] isEqual:@3.5], "milliseconds normalize to sorted seconds");
    CHECK([text(cues, 0.49) isEqual:@""] && [text(cues, 0.5) isEqual:@"first"], "cue start is inclusive");
    CHECK([text(cues, 2) isEqual:@"second"] && [text(cues, 3.5) isEqual:@""], "cue end is exclusive and adjacent cue starts immediately");
    CHECK([text(cues, NAN) isEqual:@""] && [text(cues, -1) isEqual:@""] && [text(@[], 1) isEqual:@""], "invalid playback times and empty cues are safe");
    for (NSString *bad in @[@"bad", @"[]", @"{}", @"{\"subtitles\":[null]}", @"{\"subtitles\":[{\"text\":\"x\",\"startMs\":-1,\"durationMs\":1}]}", @"{\"subtitles\":[{\"text\":\"x\",\"startMs\":0,\"durationMs\":-1}]}", @"{\"subtitles\":[{\"text\":\"x\",\"startMs\":\"0\",\"durationMs\":1}]}", @"{\"subtitles\":[{\"text\":\"x\",\"startMs\":1e309,\"durationMs\":1}]}"]) {
        error = nil; CHECK(!parse(JSON(bad), &error) && error, "invalid subtitle documents fail with error");
    }
    error = nil; CHECK(!parse([NSMutableData dataWithLength:8 * 1024 * 1024 + 1], &error) && error, "oversized subtitle input is rejected");
    CHECK([parse(JSON(@"{\"subtitles\":[]}"), NULL) count] == 0, "empty valid subtitle document accepted");
    NSLog(@"Subtitle tests: %d failures", failures); return failures ? 1 : 0;
} }
