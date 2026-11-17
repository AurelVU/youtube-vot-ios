#import "VOTClient.h"
#import "VOTProtocol.h"
#import "VOTSubtitles.h"
#include <math.h>

// Keep protocol credentials on their original HTTPS service when following redirects.
@interface VOTRedirectPolicy : NSObject <NSURLSessionTaskDelegate>
@end
@implementation VOTRedirectPolicy
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSString *origin = task.originalRequest.URL.host;
    BOOL protocolRequest = [origin isEqual:@"api.browser.yandex.ru"] || [origin isEqual:@"vot-worker.toil.cc"];
    if (![request.URL.scheme isEqual:@"https"] || (protocolRequest && ![request.URL.host isEqual:origin])) { completionHandler(nil); return; }
    NSMutableURLRequest *safe = [request mutableCopy]; safe.HTTPShouldHandleCookies = NO;
    if (!protocolRequest) { [safe setValue:nil forHTTPHeaderField:@"Cookie"]; [safe setValue:nil forHTTPHeaderField:@"Authorization"]; }
    completionHandler(safe);
}
@end
static BOOL ValidVideo(NSString *videoID) {
    return videoID.length == 11 && [videoID rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet]].location == NSNotFound;
}
static BOOL ValidLanguage(NSString *language) {
    return language.length > 0 && language.length <= 16 && [language rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-"] invertedSet]].location == NSNotFound;
}
// Never forward arbitrary service text: it can echo Cookie, tokens or other secrets.
static NSError *HTTPError(NSInteger status, NSString *path, BOOL cookieAttached, NSData *data) {
    NSDictionary *messages = @{
        @"invalid_cookie":@"Сервис не принял сессию Яндекса. Войдите в аккаунт заново.",
        @"invalid_session":@"Сервис не принял сессию Яндекса. Войдите в аккаунт заново.",
        @"unauthorized":@"Сервис не подтвердил вход в Яндекс. Войдите в аккаунт заново.",
        @"authentication_required":@"Сервис требует вход в Яндекс.",
        @"invalid_token":@"Сервис не принял токен запроса.",
        @"invalid_argument":@"Сервис не принял параметры запроса.",
        @"invalid_request":@"Сервис не принял параметры запроса.",
        @"unsupported_language":@"Сервис не поддерживает выбранный язык.",
        @"unsupported_response_language":@"Сервис не поддерживает выбранный язык перевода."
    };
    NSString *reason;
    if (data.length && data.length <= 8192) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([json isKindOfClass:NSDictionary.class]) {
            for (NSString *key in @[@"code",@"error"]) {
                id candidate = json[key];
                if ([candidate isKindOfClass:NSDictionary.class]) candidate = candidate[@"code"];
                if (![candidate isKindOfClass:NSString.class] || [candidate length] > 64) continue;
                NSString *normalized = [candidate lowercaseString];
                if (messages[normalized]) { reason = normalized; break; }
            }
        }
    }
    NSString *stage = (@{@"/session/create":@"создание сессии", @"/video-translation/translate":@"перевод видео",
                         @"/video-translation/fail-audio-js":@"загрузка исходного аудио", @"/video-translation/audio":@"подготовка аудио",
                         @"/video-subtitles/get-subtitles":@"получение субтитров"})[path] ?: @"запрос перевода";
    NSString *description = [NSString stringWithFormat:@"Сервис перевода: %@ (%@), HTTP %ld.", stage, path, (long)status];
    if (reason) description = [description stringByAppendingFormat:@" %@", messages[reason]];
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey:description,@"VOTRequestPath":path,@"VOTHTTPStatus":@(status),@"VOTCookieAttached":@(cookieAttached)} mutableCopy];
    if (reason) info[@"VOTServiceReason"] = reason;
    return [NSError errorWithDomain:@"YouTubeVOT" code:status userInfo:info];
}
@interface VOTClient ()
@property (nonatomic) NSURLSession *session;
@property (nonatomic) NSURLSessionDataTask *task;
@property (nonatomic, readwrite) NSString *endpoint;
@property (nonatomic) NSString *uuid;
@property (nonatomic) NSString *secret;
@property (nonatomic) NSDate *expires;
@property (nonatomic) NSMutableSet<NSString *> *audioFallbacks;
@property (nonatomic) NSUInteger generation;
@property (nonatomic, copy) NSString *activeCookie;
@property (nonatomic, copy) NSString *activeTarget;
@property (nonatomic) BOOL activeLively;
@end

@implementation VOTClient
- (instancetype)init {
    NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.timeoutIntervalForRequest = 25; c.timeoutIntervalForResource = 40;
    return [self initWithSessionConfiguration:c];
}
- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    if ((self = [super init])) {
        NSURLSessionConfiguration *isolated = [configuration copy];
        isolated.HTTPShouldSetCookies = NO; isolated.HTTPCookieStorage = nil; isolated.URLCredentialStorage = nil;
        _session = [NSURLSession sessionWithConfiguration:isolated delegate:[VOTRedirectPolicy new] delegateQueue:nil];
        _responseLanguage = @"ru";
        _endpoint = @"https://api.browser.yandex.ru";
        _audioFallbacks = [NSMutableSet set];
    }
    return self;
}
- (void)dealloc { [_session invalidateAndCancel]; }
- (void)cancel { self.generation++; [self.task cancel]; self.task = nil; self.activeCookie = nil; }
- (void)request:(NSString *)path body:(NSData *)body headers:(NSDictionary *)extra method:(NSString *)method completion:(void (^)(NSData *, NSError *))completion {
    NSMutableDictionary *headers = [@{@"User-Agent":VOTUserAgent, @"Accept":@"application/x-protobuf",
        @"Accept-Language":@"en", @"Content-Type":@"application/x-protobuf", @"Cache-Control":@"no-cache"} mutableCopy];
    [headers addEntriesFromDictionary:extra];
    // Upstream auth belongs only to translateVideo; session and audio helpers are unauthenticated.
    BOOL cookieAttached = self.activeCookie.length && [self.endpoint isEqual:@"https://api.browser.yandex.ru"] && [path isEqual:@"/video-translation/translate"];
    if (cookieAttached) headers[@"Cookie"] = self.activeCookie;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.endpoint stringByAppendingString:path]]];
    r.HTTPMethod = method; r.HTTPBody = body; r.HTTPShouldHandleCookies = NO;
    if ([self.endpoint containsString:@"vot-worker"]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:headers options:0 error:NULL];
        r.allHTTPHeaderFields = @{@"User-Agent":@"vot.js/3.2.3", @"X-VOT-Headers":[json base64EncodedStringWithOptions:0], @"Content-Type":headers[@"Content-Type"]};
    } else { r.allHTTPHeaderFields = headers; }
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    self.task = [self.session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.generation) return;
            self.task = nil;
            NSError *requestError = error;
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            NSLog(@"[YouTubeVOT] %@ %@: HTTP %ld auth=%@", method, path, (long)status, cookieAttached ? @"yes" : @"no");
            if (!requestError && status != 200) requestError = HTTPError(status, path, cookieAttached, data);
            if (!requestError && (!data.length || data.length > 1024 * 1024)) requestError = VOTError(103, @"Некорректный размер ответа сервиса.");
            completion(requestError ? nil : data, requestError);
        });
    }];
    [self.task resume];
}
- (void)ensureSession:(void (^)(NSError *))completion {
    if (self.secret.length && [self.expires timeIntervalSinceNow] > 30) { completion(nil); return; }
    self.uuid = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] uppercaseString];
    NSData *body = VOTEncodeSession(self.uuid);
    [self request:@"/session/create" body:body headers:@{@"Vtrans-Signature":VOTSignature(body)} method:@"POST" completion:^(NSData *data, NSError *error) {
        if (error) { completion(error); return; }
        NSDictionary *fields = VOTDecodeFields(data, &error);
        NSData *key = fields[@1]; NSNumber *ttl = fields[@2];
        if (![key isKindOfClass:NSData.class] || ![ttl isKindOfClass:NSNumber.class]) {
            completion(error ?: VOTError(104, @"Не удалось создать сессию перевода.")); return;
        }
        self.secret = [[NSString alloc] initWithData:key encoding:NSUTF8StringEncoding];
        if (!self.secret.length || ttl.doubleValue < 1) { completion(VOTError(104, @"Сервис не выдал сессию перевода.")); return; }
        self.expires = [NSDate dateWithTimeIntervalSinceNow:MIN(ttl.doubleValue, 86400)]; completion(nil);
    }];
}
- (void)translateVideo:(NSString *)videoID duration:(double)duration language:(NSString *)language first:(BOOL)first completion:(VOTCompletion)completion {
    [self cancel];
    if (!ValidVideo(videoID) || !isfinite(duration) || duration <= 0 || duration > 14400 || !ValidLanguage(language) || !ValidLanguage(self.responseLanguage)) {
        completion(nil, VOTError(105, @"Нужен обычный ролик YouTube длительностью до 4 часов.")); return;
    }
    self.activeTarget = self.responseLanguage; self.activeLively = self.livelyVoice;
    NSString *cookie = self.livelyVoice ? self.sessionCookie : nil;
    if (cookie.length && (cookie.length > 16384 || [cookie rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)) {
        completion(nil, VOTError(108, @"Некорректный формат Cookie Яндекса.")); return;
    }
    self.activeCookie = cookie;
    if (cookie.length && ![self.endpoint isEqual:@"https://api.browser.yandex.ru"]) { self.endpoint = @"https://api.browser.yandex.ru"; self.secret = nil; }
    [self performTranslation:videoID duration:duration language:language first:first completion:completion];
}
- (void)performTranslation:(NSString *)videoID duration:(double)duration language:(NSString *)language first:(BOOL)first completion:(VOTCompletion)completion {
    VOTCompletion finish = ^(NSDictionary *result, NSError *error) {
        if (error && !self.activeCookie.length && ![self.endpoint containsString:@"vot-worker"]) {
            self.endpoint = @"https://vot-worker.toil.cc"; self.secret = nil;
            [self performTranslation:videoID duration:duration language:language first:first completion:completion]; return;
        }
        completion(result, error);
    };
    [self ensureSession:^(NSError *error) {
        if (error) { finish(nil, error); return; }
        [self sendTranslation:videoID duration:duration language:language first:first completion:finish];
    }];
}
- (void)sendTranslation:(NSString *)videoID duration:(double)duration language:(NSString *)language first:(BOOL)first completion:(VOTCompletion)completion {
    NSString *url = [@"https://youtu.be/" stringByAppendingString:videoID];
    NSString *path = @"/video-translation/translate";
    NSData *body = VOTEncodeTranslationOptions(url, duration, language, self.activeTarget, first, self.activeLively);
    [self request:path body:body headers:VOTRequestHeaders(body, self.uuid, self.secret, path) method:@"POST" completion:^(NSData *data, NSError *error) {
        if (error) { self.secret = nil; completion(nil, error); return; }
        NSDictionary *result = VOTDecodeTranslation(data, &error);
        if (!result) { completion(nil, error); return; }
        NSString *translationID = result[@"translationID"];
        if ([result[@"status"] integerValue] == 6 && translationID.length && ![self.audioFallbacks containsObject:translationID]) {
            [self sendAudioFallback:url videoID:videoID translationID:translationID completion:^(NSError *fallbackError) {
                if (!fallbackError) [self.audioFallbacks addObject:translationID];
                completion(fallbackError ? nil : result, fallbackError);
            }]; return;
        }
        completion(result, nil);
    }];
}
- (void)sendAudioFallback:(NSString *)url videoID:(NSString *)videoID translationID:(NSString *)translationID completion:(void (^)(NSError *))completion {
    // Same server-side audio retrieval fallback used by vot.js for YouTube status 6.
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"video_url":url} options:0 error:NULL];
    [self request:@"/video-translation/fail-audio-js" body:body headers:@{@"Accept":@"application/json", @"Content-Type":@"application/json"} method:@"PUT" completion:^(NSData *data, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (error || ![json isKindOfClass:NSDictionary.class] || ![json[@"status"] isEqual:@1]) {
            completion(error ?: VOTError(106, @"Сервис не смог получить аудио этого ролика.")); return;
        }
        NSString *path = @"/video-translation/audio";
        NSData *audio = VOTEncodeAudioFallback(url, translationID, videoID);
        [self request:path body:audio headers:VOTRequestHeaders(audio, self.uuid, self.secret, path) method:@"PUT" completion:^(NSData *audioData, NSError *audioError) {
            NSDictionary *fields = audioData ? VOTDecodeFields(audioData, &audioError) : nil;
            if (!audioError && ![fields[@1] isKindOfClass:NSNumber.class]) audioError = VOTError(106, @"Сервис не принял запрос получения аудио.");
            completion(audioError);
        }];
    }];
}
- (void)subtitlesForVideo:(NSString *)videoID language:(NSString *)language target:(NSString *)target completion:(VOTCompletion)completion {
    [self cancel];
    if (!ValidVideo(videoID) || !ValidLanguage(language) || !ValidLanguage(target)) {
        completion(nil, VOTError(105, @"Некорректный ролик или язык субтитров.")); return;
    }
    [self fetchSubtitleTracks:videoID language:language target:target completion:completion];
}
- (void)fetchSubtitleTracks:(NSString *)videoID language:(NSString *)language target:(NSString *)target completion:(VOTCompletion)completion {
    void (^finish)(NSData *, NSError *) = ^(NSData *data, NSError *error) {
        if (error && ![self.endpoint containsString:@"vot-worker"]) {
            self.endpoint = @"https://vot-worker.toil.cc"; self.secret = nil;
            [self fetchSubtitleTracks:videoID language:language target:target completion:completion]; return;
        }
        if (error) { completion(nil, error); return; }
        NSDictionary *result = VOTDecodeSubtitles(data, &error);
        if (!result) { completion(nil, error); return; }
        if ([result[@"waiting"] boolValue]) { completion(@{@"waiting":@YES,@"cues":@[]}, nil); return; }
        NSString *trackURL;
        for (NSDictionary *track in result[@"subtitles"]) {
            if ([track[@"translatedLanguage"] isEqual:target] && [track[@"translatedUrl"] length]) { trackURL = track[@"translatedUrl"]; break; }
        }
        if (!trackURL) for (NSDictionary *track in result[@"subtitles"]) {
            if ([track[@"language"] isEqual:target] && [track[@"url"] length]) { trackURL = track[@"url"]; break; }
        }
        NSURL *url = trackURL ? [NSURL URLWithString:trackURL] : nil;
        if (![url.scheme isEqual:@"https"] || !url.host.length || url.user.length || url.password.length) {
            completion(nil, VOTError(109, @"Субтитры на выбранном языке пока недоступны.")); return;
        }
        [self fetchSubtitleJSON:url completion:completion];
    };
    [self ensureSession:^(NSError *error) {
        if (error) { finish(nil, error); return; }
        NSString *path = @"/video-subtitles/get-subtitles";
        NSData *body = VOTEncodeSubtitles([@"https://youtu.be/" stringByAppendingString:videoID], language);
        [self request:path body:body headers:VOTRequestHeaders(body, self.uuid, self.secret, path) method:@"POST" completion:finish];
    }];
}
- (void)fetchSubtitleJSON:(NSURL *)url completion:(VOTCompletion)completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPShouldHandleCookies = NO;
    request.allHTTPHeaderFields = @{@"Accept":@"application/json",@"User-Agent":VOTUserAgent};
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    self.task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.generation) return;
            self.task = nil;
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            if (error) { completion(nil, error); return; }
            if (status != 200) { completion(nil, VOTError(status, @"Не удалось загрузить субтитры.")); return; }
            NSError *parseError;
            NSArray *cues = VOTParseSubtitleCues(data, &parseError);
            completion(cues ? @{@"waiting":@NO,@"cues":cues} : nil, parseError);
        });
    }];
    [self.task resume];
}
@end
