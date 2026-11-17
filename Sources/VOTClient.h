#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef void (^VOTCompletion)(NSDictionary *_Nullable result, NSError *_Nullable error);
@interface VOTClient : NSObject
@property (nonatomic, readonly) NSString *endpoint;
@property (nonatomic, copy) NSString *responseLanguage;
@property (nonatomic) BOOL livelyVoice;
@property (nonatomic, copy, nullable) NSString *sessionCookie;
- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration;
- (void)translateVideo:(NSString *)videoID duration:(double)duration language:(NSString *)language first:(BOOL)first completion:(VOTCompletion)completion;
- (void)subtitlesForVideo:(NSString *)videoID language:(NSString *)language target:(NSString *)target completion:(VOTCompletion)completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
