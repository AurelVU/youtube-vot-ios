#import <Foundation/Foundation.h>
#import "VOTClient.h"
#import "VOTProtocol.h"
@interface VOTClient (NewAPI)
@property NSString *responseLanguage;
@property BOOL livelyVoice;
@property NSString *sessionCookie;
- (void)subtitlesForVideo:(NSString *)videoID language:(NSString *)language target:(NSString *)target completion:(VOTCompletion)completion;
@end

static NSInteger mode, sessionCount, translationCount, audioCount, failures;
static BOOL workerHeadersValid, sawCookie, leakedCookie, sawOptions, sawVsubs;
static NSInteger mediaCount;
static BOOL sessionCookieSent, translationCookieSent;
static void Field(NSMutableData *d, unsigned char field, NSString *value) {
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char tag[] = {field * 8 + 2, (unsigned char)bytes.length};
    [d appendBytes:tag length:2]; [d appendData:bytes];
}

@interface FixtureProtocol : NSURLProtocol
@end
@implementation FixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return [r.URL.host isEqual:@"api.browser.yandex.ru"] || [r.URL.host isEqual:@"vot-worker.toil.cc"] || [r.URL.host isEqual:@"subtitles.example"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading {
    NSURLRequest *r = self.request;
    BOOL worker = [r.URL.host isEqual:@"vot-worker.toil.cc"];
    sawCookie |= [[r valueForHTTPHeaderField:@"Cookie"] isEqual:@"Session_id=fixture"] && !worker;
    leakedCookie |= [r valueForHTTPHeaderField:@"Cookie"].length && (worker || [r.URL.host isEqual:@"subtitles.example"]);
    if (worker) {
        NSData *headers = [[NSData alloc] initWithBase64EncodedString:[r valueForHTTPHeaderField:@"X-VOT-Headers"] options:0];
        NSDictionary *decoded = headers ? [NSJSONSerialization JSONObjectWithData:headers options:0 error:NULL] : nil;
        workerHeadersValid = [decoded[@"Vtrans-Signature"] length] == 64;
        leakedCookie |= [decoded[@"Cookie"] length] > 0;
    }
    NSInteger status = 200; NSData *body;
    if ([r.URL.path isEqual:@"/session/create"]) {
        sessionCount++;
        sessionCookieSent |= [r valueForHTTPHeaderField:@"Cookie"].length > 0;
        const unsigned char bytes[] = {0x0a,0x03,'k','e','y',0x10,0xb0,0x09};
        body = [NSData dataWithBytes:bytes length:sizeof(bytes)];
        if (mode == 7) { status = 400; body = [@"{\"code\":\"INVALID_ARGUMENT\",\"message\":\"Session_id=fixture\",\"token\":\"do-not-echo\"}" dataUsingEncoding:NSUTF8StringEncoding]; }
    } else if ([r.URL.path isEqual:@"/video-translation/translate"]) {
        translationCount++;
        translationCookieSent |= [[r valueForHTTPHeaderField:@"Cookie"] isEqual:@"Session_id=fixture"];
        NSData *requestBody = r.HTTPBody;
        if (!requestBody && r.HTTPBodyStream) {
            NSMutableData *read = [NSMutableData data]; NSInputStream *stream = r.HTTPBodyStream; [stream open];
            uint8_t buffer[4096]; NSInteger count;
            while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [read appendBytes:buffer length:(NSUInteger)count];
            [stream close]; requestBody = read;
        }
        NSDictionary *encoded = VOTDecodeFields(requestBody, NULL);
        sawOptions = [encoded[@14] isEqual:[@"en" dataUsingEncoding:NSUTF8StringEncoding]] && [encoded[@18] isEqual:@1];
        if ((mode == 1 && !worker) || mode == 2 || mode == 3) { status = 503; body = [@"Unavailable" dataUsingEncoding:NSUTF8StringEncoding]; }
        else {
            NSData *url = [@"https://audio.example/a.mp3" dataUsingEncoding:NSUTF8StringEncoding];
            unsigned char prefix[] = {0x0a, (unsigned char)url.length};
            NSMutableData *ready = [NSMutableData dataWithBytes:prefix length:2]; [ready appendData:url];
            const unsigned char suffix[] = {0x20,1}; [ready appendBytes:suffix length:2]; body = ready;
        }
        if (mode == 8 || mode == 9) { status = 400; body = [(mode == 8 ? @"{\"error\":\"invalid_cookie\",\"message\":\"Session_id=fixture\",\"token\":\"do-not-echo\"}" : @"{\"message\":\"Session_id=fixture do-not-echo\"}") dataUsingEncoding:NSUTF8StringEncoding]; }
    } else if ([r.URL.path isEqual:@"/video-subtitles/get-subtitles"]) {
        sawVsubs = [r valueForHTTPHeaderField:@"Vsubs-Signature"].length == 64 && [r valueForHTTPHeaderField:@"Sec-Vsubs-Sk"].length > 0;
        if (mode == 6) { const unsigned char waiting[] = {8,1}; body = [NSData dataWithBytes:waiting length:2]; }
        else {
            NSMutableData *track = [NSMutableData data]; Field(track, 1, @"de"); Field(track, 2, @"https://subtitles.example/de.json"); Field(track, 4, @"ru"); Field(track, 5, @"https://subtitles.example/ru.json");
            NSMutableData *tracks = [NSMutableData data]; unsigned char prefix[] = {18,(unsigned char)track.length}; [tracks appendBytes:prefix length:2]; [tracks appendData:track];
            [track setLength:0]; Field(track, 1, @"en"); Field(track, 2, @"https://subtitles.example/en.json"); prefix[1] = track.length; [tracks appendBytes:prefix length:2]; [tracks appendData:track]; body = tracks;
        }
    } else if ([r.URL.host isEqual:@"subtitles.example"]) {
        mediaCount++;
        body = [[NSString stringWithFormat:@"{\"subtitles\":[{\"text\":\"%@\",\"startMs\":1000,\"durationMs\":2000}]}", r.URL.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding];
    } else { audioCount++; status = 400; body = NSData.data; }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:r.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/x-protobuf"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:body];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

static VOTClient *Client(void) {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.protocolClasses = @[FixtureProtocol.class];
    return [[VOTClient alloc] initWithSessionConfiguration:config];
}
#define CHECK(c, m) do { if (!(c)) { NSLog(@"FAIL: %s",m); failures++; } } while(0)
static void Run(NSInteger scenario) {
    mode = scenario; sessionCount = translationCount = audioCount = 0; workerHeadersValid = NO;
    VOTClient *client = Client(); __block BOOL done = NO; __block NSDictionary *result; __block NSError *error;
    [client translateVideo:@"jNQXAC9IVRw" duration:19 language:@"en" first:YES completion:^(NSDictionary *r, NSError *e) { result = r; error = e; done = YES; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!done && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(done, "transport completes within deadline");
    CHECK(sessionCount == 2 && translationCount == 2, "one bounded retry creates a worker session and retries translation");
    CHECK(workerHeadersValid, "worker receives encoded VOT signature headers");
    if (scenario == 1) CHECK(!error && [result[@"status"] isEqual:@1], "worker succeeds after direct translation fails");
    else CHECK(error && !result, "worker failure is returned without another retry");
    [client cancel];
}
static void WaitFor(BOOL *done) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!*done && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(*done, "operation completed within deadline");
}
static void NewFeatures(void) {
    VOTClient *client = Client();
    CHECK([client respondsToSelector:@selector(setResponseLanguage:)] && [client respondsToSelector:@selector(subtitlesForVideo:language:target:completion:)], "new translation options and subtitle API available");
    if (![client respondsToSelector:@selector(setResponseLanguage:)] || ![client respondsToSelector:@selector(subtitlesForVideo:language:target:completion:)]) return;
    mode = 3; sessionCount = translationCount = 0; sawCookie = leakedCookie = sawOptions = NO;
    client.responseLanguage = @"en"; client.livelyVoice = YES; client.sessionCookie = @"Session_id=fixture";
    __block BOOL done = NO; __block NSError *error;
    [client translateVideo:@"jNQXAC9IVRw" duration:19 language:@"de" first:YES completion:^(NSDictionary *r, NSError *e) { (void)r; error = e; done = YES; }];
    WaitFor(&done);
    CHECK(error && sessionCount == 1 && translationCount == 1, "authenticated error never retries through worker");
    CHECK(sawCookie && !leakedCookie && sawOptions, "lively request sends selected target and credentials only to direct service");
    mode = 4; done = NO; sawCookie = NO; client.livelyVoice = NO;
    [client translateVideo:@"jNQXAC9IVRw" duration:19 language:@"de" first:NO completion:^(NSDictionary *r, NSError *e) { (void)r; error = e; done = YES; }]; WaitFor(&done);
    CHECK(!error && !sawCookie, "classic voice does not attach saved session cookie");
    for (NSString *target in @[@"ru", @"en"]) {
        mode = 5; done = NO; sawVsubs = NO; mediaCount = 0; __block NSDictionary *result;
        [client subtitlesForVideo:@"jNQXAC9IVRw" language:@"de" target:target completion:^(NSDictionary *r, NSError *e) { result = r; error = e; done = YES; }]; WaitFor(&done);
        CHECK(!error && sawVsubs && mediaCount == 1 && [result[@"waiting"] isEqual:@NO], "subtitle API uses Vsubs signature then fetches one track");
        CHECK([result[@"cues"][0][@"text"] isEqual:[target stringByAppendingString:@".json"]], "selects translated target or matching source track from repeated response");
    }
    mode = 6; done = NO; mediaCount = 0;
    [client subtitlesForVideo:@"jNQXAC9IVRw" language:@"de" target:@"ru" completion:^(NSDictionary *r, NSError *e) { CHECK([r[@"waiting"] isEqual:@YES] && [r[@"cues"] count] == 0 && !e, "subtitle processing remains waiting"); done = YES; }]; WaitFor(&done);
    CHECK(mediaCount == 0, "waiting subtitles do not fetch nonexistent media");
    done = NO;
    [client subtitlesForVideo:@"jNQXAC9IVRw" language:@"de" target:@"ru" completion:^(NSDictionary *r, NSError *e) { (void)r; (void)e; done = YES; }];
    [client cancel];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    CHECK(!done, "cancel suppresses stale subtitle callbacks");
}
static void AuthScopeAndDiagnostics(void) {
    for (NSNumber *scenario in @[@4,@7,@8,@9]) {
        mode = scenario.integerValue; sessionCount = translationCount = 0;
        sessionCookieSent = translationCookieSent = leakedCookie = NO;
        VOTClient *client = Client(); client.livelyVoice = YES; client.sessionCookie = @"Session_id=fixture";
        __block BOOL done = NO; __block NSError *error;
        [client translateVideo:@"jNQXAC9IVRw" duration:19 language:@"en" first:YES completion:^(NSDictionary *result, NSError *e) { (void)result; error = e; done = YES; }];
        WaitFor(&done);
        CHECK(!sessionCookieSent, "Yandex session creation stays unauthenticated like upstream");
        CHECK(!leakedCookie && sessionCount == 1, "authenticated requests never fall back to worker including session errors");
        if (mode == 4) { CHECK(!error && translationCookieSent, "only the translation receives the lively session cookie"); continue; }
        NSString *path = mode == 7 ? @"/session/create" : @"/video-translation/translate";
        CHECK(error.code == 400 && [error.userInfo[@"VOTRequestPath"] isEqual:path], "HTTP error identifies actual failing protocol stage");
        CHECK([error.userInfo[@"VOTHTTPStatus"] isEqual:@400] && [error.userInfo[@"VOTCookieAttached"] isEqual:@(mode != 7)], "HTTP error reports safe status and credential-presence metadata");
        NSString *description = error.userInfo.description;
        CHECK([description rangeOfString:@"fixture"].location == NSNotFound && [description rangeOfString:@"do-not-echo"].location == NSNotFound, "server-echoed secrets never reach error diagnostics");
        if (mode == 8) CHECK([error.userInfo[@"VOTServiceReason"] isEqual:@"invalid_cookie"], "known service auth failure is classified without raw response");
        if (mode == 9) CHECK(!error.userInfo[@"VOTServiceReason"], "arbitrary server message cannot become a diagnostic reason");
        [client cancel];
    }
}
int main(void) { @autoreleasepool {
    Run(1); Run(2); NewFeatures(); AuthScopeAndDiagnostics();
    VOTClient *client = Client(); __block BOOL rejected = NO; sessionCount = 0;
    [client translateVideo:@"invalid" duration:NAN language:@"en" first:YES completion:^(NSDictionary *r, NSError *e) { rejected = !r && e != nil; }];
    CHECK(rejected && !sessionCount, "invalid video is rejected before network access");
    NSLog(@"Client tests: %ld failures",(long)failures); return failures ? 1 : 0;
} }
