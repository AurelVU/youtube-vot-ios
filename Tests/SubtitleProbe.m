#import <Foundation/Foundation.h>
#import "VOTClient.h"
int main(int argc, const char *argv[]) { @autoreleasepool {
    VOTClient *client = [VOTClient new]; __block BOOL done = NO; __block int code = 1;
    [client subtitlesForVideo:argc > 1 ? @(argv[1]) : @"jNQXAC9IVRw" language:@"en" target:@"ru" completion:^(NSDictionary *result, NSError *error) {
        if (error) NSLog(@"Subtitle probe: %@", error.localizedDescription);
        else { NSLog(@"Subtitle probe: waiting=%@, cues=%lu", result[@"waiting"], (unsigned long)[result[@"cues"] count]); code = 0; }
        done = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:110];
    while (!done && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    [client cancel]; return code;
} }
