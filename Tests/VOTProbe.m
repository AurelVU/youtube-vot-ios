#import <Foundation/Foundation.h>
#import "VOTClient.h"
int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "Usage: vot-probe VIDEO_ID DURATION_SECONDS [LANGUAGE] [TARGET] [LIVELY_0_OR_1]\n"); return 2; }
    VOTClient *client = [VOTClient new];
    if (argc > 4) client.responseLanguage = @(argv[4]);
    if (argc > 5) client.livelyVoice = atoi(argv[5]) != 0;
    __block BOOL done = NO; __block int code = 1;
    [client translateVideo:@(argv[1]) duration:atof(argv[2]) language:argc > 3 ? @(argv[3]) : @"en" first:YES completion:^(NSDictionary *result, NSError *error) {
        if (error) NSLog(@"Probe endpoint %@ error: %@", client.endpoint, error.localizedDescription);
        else { NSLog(@"Endpoint: %@; status=%@; wait=%@; audio=%@; lively=%@", client.endpoint, result[@"status"], result[@"remainingTime"], result[@"url"] ? @"received" : @"not ready", result[@"isLivelyVoice"]);
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
            [json writeToFile:@"build/probe-result.json" atomically:YES];
            code = [result[@"status"] integerValue] == 0 || [result[@"status"] integerValue] == 7 ? 1 : 0;
        }
        done = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:110];
    while (!done && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    [client cancel]; if (!done) NSLog(@"Probe exceeded deadline"); return code;
} }
