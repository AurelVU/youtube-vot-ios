#import <Foundation/Foundation.h>
#import <dlfcn.h>

static int failures;
#define CHECK(test, message) do { if (!(test)) { NSLog(@"FAIL: %s", message); failures++; } } while (0)
static NSData *Hex(NSString *s) {
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i < s.length; i += 2) {
        unsigned int value; [[NSScanner scannerWithString:[s substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&value];
        uint8_t byte = value; [d appendBytes:&byte length:1];
    }
    return d;
}
int main(void) { @autoreleasepool {
    NSData *(*session)(NSString *) = dlsym(RTLD_DEFAULT, "VOTEncodeSession");
    NSData *(*translation)(NSString *, double, NSString *, BOOL) = dlsym(RTLD_DEFAULT, "VOTEncodeTranslation");
    NSDictionary *(*decode)(NSData *, NSError **) = dlsym(RTLD_DEFAULT, "VOTDecodeTranslation");
    NSDictionary *(*fields)(NSData *, NSError **) = dlsym(RTLD_DEFAULT, "VOTDecodeFields");
    NSString *(*signature)(NSData *) = dlsym(RTLD_DEFAULT, "VOTSignature");
    CHECK(session && translation && decode && fields && signature, "VOT wire protocol is available");
    if (failures) return 1;
    CHECK([session(@"AB") isEqual:Hex(@"0a0241421211766964656f2d7472616e736c6174696f6e")], "session wire matches schema");
    NSDictionary *encoded = fields(translation(@"https://youtu.be/abcdefghijk", 120, @"en", YES), NULL);
    CHECK([encoded[@3] isEqual:[@"https://youtu.be/abcdefghijk" dataUsingEncoding:NSUTF8StringEncoding]], "video URL encoded");
    CHECK([encoded[@5] isEqual:@1] && [encoded[@16] isEqual:@2], "first request and protocol version");
    CHECK([encoded[@14] isEqual:[@"ru" dataUsingEncoding:NSUTF8StringEncoding]], "Russian target language");
    CHECK(fields(translation(@"u", 120, @"de", NO), NULL)[@5] == nil, "poll is not a first request");
    // SHA256 HMAC generated independently using Python hmac and upstream public protocol key.
    CHECK([signature([@"test" dataUsingEncoding:NSUTF8StringEncoding]) isEqual:@"ef02ef65d4b0c97334b2e2840177ba354f5b7e530200636dfe5b969eda9442e4"], "body HMAC matches independent fixture");
    NSError *error = nil;
    NSDictionary *ready = decode(Hex(@"0a0968747470733a2f2f6120013a026964"), &error);
    CHECK(!error && [ready[@"status"] isEqual:@1] && [ready[@"url"] isEqual:@"https://a"], "ready response");
    CHECK([ready[@"isLivelyVoice"] isEqual:@NO], "missing lively response flag means classic voice");
    CHECK([decode(Hex(@"0a0968747470733a2f2f6120015001"), NULL)[@"isLivelyVoice"] isEqual:@YES], "server lively voice confirmation is preserved");
    error = nil;
    CHECK(!decode(Hex(@"0a0968747470733a2f2f612001520161"), &error) && error, "malformed lively confirmation is rejected");
    NSDictionary *waiting = decode(Hex(@"200228783a026964"), NULL);
    CHECK([waiting[@"status"] isEqual:@2] && [waiting[@"remainingTime"] isEqual:@120], "waiting response");
    CHECK(decode(Hex(@"2007"), NULL)[@"status"] != nil, "auth-required status is preserved");
    CHECK([decode(Hex(@"2000"), NULL)[@"status"] isEqual:@0], "failed status is preserved");
    for (NSString *bad in @[@"", @"0a80", @"0a1061", @"208080808080808080808080", @"00", @"2300", @"220161", @"2001", @"2063"]) {
        error = nil;
        CHECK(decode(Hex(bad), &error) == nil && error != nil, "malformed or incomplete responses fail safely");
    }
    error = nil;
    CHECK(fields(Hex(@"a00601"), &error) != nil && !error, "unknown valid fields are accepted");
    NSData *(*options)(NSString *, double, NSString *, NSString *, BOOL, BOOL) = dlsym(RTLD_DEFAULT, "VOTEncodeTranslationOptions");
    NSData *(*subRequest)(NSString *, NSString *) = dlsym(RTLD_DEFAULT, "VOTEncodeSubtitles");
    NSDictionary *(*subDecode)(NSData *, NSError **) = dlsym(RTLD_DEFAULT, "VOTDecodeSubtitles");
    CHECK(options && subRequest && subDecode, "language, lively voice and subtitle protocol support is available");
    if (options && subRequest && subDecode) {
        NSDictionary *opts = fields(options(@"u", 9, @"de", @"en", YES, YES), NULL);
        CHECK([opts[@8] isEqual:Hex(@"6465")] && [opts[@14] isEqual:Hex(@"656e")] && [opts[@18] isEqual:@1], "explicit source, target and lively flags encoded");
        CHECK([opts[@9] isEqual:@1], "explicit source language is forced instead of redetected");
        CHECK(fields(options(@"u", 9, @"auto", @"ru", NO, NO), NULL)[@9] == nil, "automatic language detection does not force a source");
        CHECK(fields(options(@"u", 9, @"auto", @"ru", NO, NO), NULL)[@18] == nil, "classic voice omits lively flag");
        CHECK([subRequest(@"u", @"de") isEqual:Hex(@"0a017512026465")], "subtitle request matches upstream schema");
        NSDictionary *subs = subDecode(Hex(@"080112070a02656e12016112070a027275120162"), NULL);
        CHECK([subs[@"waiting"] isEqual:@1] && [subs[@"subtitles"] count] == 2, "repeated subtitle tracks are preserved");
        CHECK([subs[@"subtitles"][0][@"language"] isEqual:@"en"] && [subs[@"subtitles"][1][@"url"] isEqual:@"b"], "subtitle track strings decoded");
        error = nil;
        CHECK(!subDecode(Hex(@"12010a"), &error) && error, "malformed nested subtitle track rejected");
    }
    NSLog(@"Protocol tests: %d failures", failures);
    return failures ? 1 : 0;
} }
