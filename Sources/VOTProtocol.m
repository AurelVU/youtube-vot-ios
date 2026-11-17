#import "VOTProtocol.h"
#import <CommonCrypto/CommonHMAC.h>
#include <math.h>

// Wire format and public client constants ported from FOSWLY/vot.js (MIT).
NSString *const VOTComponentVersion = @"26.11.0.1993";
NSString *const VOTUserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 YaBrowser/26.11.0.0 Safari/537.36";
static NSString *const VOTPublicProtocolKey = @"bt8xH3VOlb4mqf0nqAibnDOoiPlXsisf";

NSError *VOTError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"YouTubeVOT" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static void Varint(NSMutableData *data, uint64_t n) {
    do { uint8_t b = (n & 0x7f) | (n > 127 ? 0x80 : 0); [data appendBytes:&b length:1]; n >>= 7; } while (n);
}
static void Integer(NSMutableData *d, unsigned field, uint64_t value) {
    Varint(d, (uint64_t)field << 3); Varint(d, value);
}
static void Bytes(NSMutableData *d, unsigned field, NSData *bytes) {
    Varint(d, ((uint64_t)field << 3) | 2); Varint(d, bytes.length); [d appendData:bytes];
}
static void String(NSMutableData *d, unsigned field, NSString *value) {
    Bytes(d, field, [value dataUsingEncoding:NSUTF8StringEncoding]);
}
NSData *VOTEncodeSession(NSString *uuid) {
    NSMutableData *d = [NSMutableData data]; String(d, 1, uuid); String(d, 2, @"video-translation"); return d;
}
NSData *VOTEncodeTranslation(NSString *url, double duration, NSString *language, BOOL first) {
    return VOTEncodeTranslationOptions(url, duration, language, @"ru", first, NO);
}
NSData *VOTEncodeTranslationOptions(NSString *url, double duration, NSString *language, NSString *target, BOOL first, BOOL lively) {
    NSMutableData *d = [NSMutableData data];
    String(d, 3, url);
    if (first) Integer(d, 5, 1);
    Varint(d, (6 << 3) | 1);
    uint64_t raw; memcpy(&raw, &duration, 8); raw = CFSwapInt64HostToLittle(raw); [d appendBytes:&raw length:8];
    Integer(d, 7, 1); String(d, 8, language);
    if (![language isEqual:@"auto"]) Integer(d, 9, 1);
    String(d, 14, target); Integer(d, 15, 1); Integer(d, 16, 2);
    if (lively) Integer(d, 18, 1);
    return d;
}
NSData *VOTEncodeSubtitles(NSString *url, NSString *language) {
    NSMutableData *d = [NSMutableData data]; String(d, 1, url); String(d, 2, language); return d;
}
NSData *VOTEncodeAudioFallback(NSString *url, NSString *translationID, NSString *videoID) {
    NSMutableData *audio = [NSMutableData data];
    String(audio, 1, [@"fallback-empty-audio:video-translation:" stringByAppendingString:videoID]);
    NSMutableData *d = [NSMutableData data]; String(d, 1, translationID); String(d, 2, url); Bytes(d, 6, audio); return d;
}
static BOOL ReadVarint(const uint8_t *bytes, NSUInteger length, NSUInteger *offset, uint64_t *result) {
    uint64_t value = 0;
    for (unsigned i = 0; i < 10; i++) {
        if (*offset >= length) return NO;
        uint8_t b = bytes[(*offset)++];
        if (i == 9 && b > 1) return NO;
        value |= (uint64_t)(b & 0x7f) << (7 * i);
        if (!(b & 0x80)) { *result = value; return YES; }
    }
    return NO;
}
static NSDictionary<NSNumber *, id> *DecodeFields(NSData *data, NSNumber *repeated, NSError **error) {
    if (data.length > 1024 * 1024) { if (error) *error = VOTError(100, @"Слишком большой ответ сервиса перевода."); return nil; }
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    const uint8_t *bytes = data.bytes; NSUInteger offset = 0;
    while (offset < data.length) {
        uint64_t tag, value;
        if (!ReadVarint(bytes, data.length, &offset, &tag) || !(tag >> 3) || (tag >> 3) > 0x1fffffff) goto malformed;
        NSNumber *key = @(tag >> 3);
        switch (tag & 7) {
            case 0:
                if (!ReadVarint(bytes, data.length, &offset, &value)) goto malformed;
                if ([key isEqual:repeated]) goto malformed;
                fields[key] = @(value); break;
            case 1: case 5: case 2: {
                NSUInteger length = (tag & 7) == 1 ? 8 : 4;
                if ((tag & 7) == 2) {
                    if (!ReadVarint(bytes, data.length, &offset, &value) || value > data.length - offset) goto malformed;
                    length = (NSUInteger)value;
                }
                if (length > data.length - offset) goto malformed;
                NSData *part = [data subdataWithRange:NSMakeRange(offset, length)];
                if ([key isEqual:repeated]) {
                    if (!fields[key]) fields[key] = [NSMutableArray array];
                    if (![fields[key] isKindOfClass:NSMutableArray.class]) goto malformed;
                    [fields[key] addObject:part];
                } else fields[key] = part;
                offset += length; break;
            }
            default: goto malformed;
        }
    }
    return fields;
malformed:
    if (error) *error = VOTError(101, @"Сервис вернул повреждённый ответ.");
    return nil;
}
NSDictionary<NSNumber *, id> *VOTDecodeFields(NSData *data, NSError **error) {
    return DecodeFields(data, nil, error);
}
NSDictionary *VOTDecodeSubtitles(NSData *data, NSError **error) {
    NSDictionary *fields = DecodeFields(data, @2, error);
    if (!fields) return nil;
    NSMutableArray *tracks = [NSMutableArray array];
    if (fields[@1] && (![fields[@1] isKindOfClass:NSNumber.class] || [fields[@1] unsignedLongLongValue] > 1)) goto invalid;
    for (NSData *trackData in fields[@2]) {
        if (tracks.count >= 128) goto invalid;
        NSDictionary *trackFields = VOTDecodeFields(trackData, error);
        if (!trackFields) return nil;
        NSMutableDictionary *track = [NSMutableDictionary dictionary];
        for (NSNumber *key in @[@1,@2,@4,@5]) {
            if (!trackFields[key]) continue;
            if (![trackFields[key] isKindOfClass:NSData.class]) goto invalid;
            NSString *value = [[NSString alloc] initWithData:trackFields[key] encoding:NSUTF8StringEncoding];
            if (!value || value.length > 8192) goto invalid;
            track[(@{@1:@"language",@2:@"url",@4:@"translatedLanguage",@5:@"translatedUrl"})[key]] = value;
        }
        [tracks addObject:track];
    }
    return @{@"waiting":@([fields[@1] boolValue]), @"subtitles":tracks};
invalid:
    if (error) *error = VOTError(107, @"Сервис вернул некорректный список субтитров.");
    return nil;
}
NSDictionary *VOTDecodeTranslation(NSData *data, NSError **error) {
    NSDictionary *fields = VOTDecodeFields(data, error);
    if (!fields) return nil;
    NSMutableDictionary *result;
    NSNumber *status = fields[@4];
    if (![status isKindOfClass:NSNumber.class] || ![@[@0,@1,@2,@3,@5,@6,@7] containsObject:status]) goto invalid;
    if (fields[@10] && (![fields[@10] isKindOfClass:NSNumber.class] || [fields[@10] unsignedLongLongValue] > 1)) goto invalid;
    result = [@{@"status":status, @"remainingTime":@5, @"isLivelyVoice":@([fields[@10] boolValue])} mutableCopy];
    if (fields[@5]) {
        if (![fields[@5] isKindOfClass:NSNumber.class]) goto invalid;
        result[@"remainingTime"] = fields[@5];
    }
    for (NSNumber *field in @[@1,@7,@8,@9]) {
        if (!fields[field]) continue;
        if (![fields[field] isKindOfClass:NSData.class]) goto invalid;
        NSString *s = [[NSString alloc] initWithData:fields[field] encoding:NSUTF8StringEncoding];
        if (!s) goto invalid;
        result[(@{@1:@"url", @7:@"translationID", @8:@"language", @9:@"message"})[field]] = s;
    }
    if (status.integerValue == 1 || status.integerValue == 5) {
        NSURL *url = [NSURL URLWithString:result[@"url"] ?: @""];
        if (![url.scheme isEqualToString:@"https"] || !url.host.length) goto invalid;
    }
    return result;
invalid:
    if (error) *error = VOTError(102, @"Неожиданный ответ сервиса перевода. Возможно, протокол изменился.");
    return nil;
}
NSString *VOTSignature(NSData *body) {
    NSData *key = [VOTPublicProtocolKey dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, body.bytes, body.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (unsigned i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
NSDictionary<NSString *, NSString *> *VOTRequestHeaders(NSData *body, NSString *uuid, NSString *secret, NSString *path) {
    NSString *token = [NSString stringWithFormat:@"%@:%@:%@", uuid, path, VOTComponentVersion];
    NSString *prefix = [path hasPrefix:@"/video-subtitles/"] ? @"Vsubs" : @"Vtrans";
    return @{[prefix stringByAppendingString:@"-Signature"]:VOTSignature(body), [NSString stringWithFormat:@"Sec-%@-Sk", prefix]:secret,
             [NSString stringWithFormat:@"Sec-%@-Token", prefix]:[NSString stringWithFormat:@"%@:%@", VOTSignature([token dataUsingEncoding:NSUTF8StringEncoding]), token]};
}
