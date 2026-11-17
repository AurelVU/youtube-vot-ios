#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VOTClient.h"
#import "VOTProtocol.h"
#import "VOTSync.h"
#import "VOTSettingsController.h"
#import "VOTSubtitles.h"
#import "VOTStartupGuard.h"
#import "VOTPlaybackState.h"

static id Object(id target, NSString *name) {
    SEL s = NSSelectorFromString(name);
    return [target respondsToSelector:s] ? ((id (*)(id, SEL))objc_msgSend)(target, s) : nil;
}
static BOOL Flag(id target, NSString *name) {
    SEL s = NSSelectorFromString(name);
    return [target respondsToSelector:s] && ((BOOL (*)(id, SEL))objc_msgSend)(target, s);
}
static double Number(id target, NSString *name) {
    SEL s = NSSelectorFromString(name);
    Method m = target ? class_getInstanceMethod(object_getClass(target), s) : NULL;
    if (!m) return NAN;
    char type[32]; method_getReturnType(m, type, sizeof(type));
    if (type[0] == 'f') return ((float (*)(id, SEL))objc_msgSend)(target, s);
    if (type[0] == 'd') return ((double (*)(id, SEL))objc_msgSend)(target, s);
    return NAN;
}
static void SetFloat(id target, NSString *name, float value) {
    SEL s = NSSelectorFromString(name);
    if ([target respondsToSelector:s]) ((void (*)(id, SEL, float))objc_msgSend)(target, s, value);
}
static NSString *VideoID(id owner) {
    id value = Object(owner, @"contentVideoID") ?: Object(owner, @"currentVideoID");
    return [value isKindOfClass:NSString.class] ? value : nil;
}
static UIViewController *PlayerForView(UIView *view) {
    Class player = NSClassFromString(@"YTPlayerViewController");
    UIResponder *responder = view;
    for (int i = 0; responder && i < 40; i++, responder = responder.nextResponder) {
        if ([responder isKindOfClass:player]) return (UIViewController *)responder;
        if ([responder isKindOfClass:UIViewController.class]) {
            UIViewController *vc = (UIViewController *)responder;
            for (int j = 0; vc && j < 12; j++, vc = vc.parentViewController)
                if ([vc isKindOfClass:player]) return vc;
        }
    }
    @try {
        UIViewController *vc = [view valueForKey:@"_eventsDelegate"];
        for (int j = 0; [vc isKindOfClass:UIViewController.class] && j < 12; j++, vc = vc.parentViewController)
            if ([vc isKindOfClass:player]) return vc;
    } @catch (__unused NSException *e) {}
    return nil;
}

@interface VOTController : NSObject
@property (nonatomic, weak) UIViewController *owner;
@property (nonatomic, weak) UIView *controls;
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UIButton *settingsButton;
@property (nonatomic, weak) VOTSettingsController *settingsController;
@property (nonatomic) VOTClient *client;
@property (nonatomic) AVPlayer *audio;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) NSString *videoID;
@property (nonatomic) NSString *language;
@property (nonatomic) NSString *targetLanguage;
@property (nonatomic) BOOL livelyVoice;
@property (nonatomic) BOOL subtitlesEnabled;
@property (nonatomic) float translationVolume;
@property (nonatomic) NSString *sessionCookie;
@property (nonatomic) NSURL *audioURL;
@property (nonatomic) NSURLSessionDownloadTask *exportTask;
@property (nonatomic) VOTClient *subtitleClient;
@property (nonatomic) NSArray *subtitleCues;
@property (nonatomic) UILabel *subtitleLabel;
@property (nonatomic) NSDate *nextSubtitlePoll;
@property (nonatomic) BOOL subtitleRequesting;
@property (nonatomic) NSString *statusText;
@property (nonatomic) NSDate *started;
@property (nonatomic) NSDate *nextPoll;
@property (nonatomic) NSDate *refreshAudio;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL enabled;
@property (nonatomic) BOOL requesting;
@property (nonatomic) BOOL seeking;
@property (nonatomic) BOOL ducked;
@property (nonatomic, weak) id duckedVideo;
@property (nonatomic) float savedVolume;
@property (nonatomic) float originalFraction;
@property (nonatomic) double lastVideoTime;
@property (nonatomic) CFTimeInterval lastTick;
@property (nonatomic) VOTMotionState motionState;
@property (nonatomic) VOTSyncState syncState;
@property (nonatomic) BOOL forceAudioSync;
@property (nonatomic) BOOL syncWantsPlay;
@property (nonatomic) float requestedAudioRate;
@property (nonatomic) float syncRate;
@property (nonatomic) NSUInteger syncSeekCount;
@property (nonatomic) NSUInteger nativePauseCount;
@property (nonatomic) double syncTargetTime;
@property (nonatomic) BOOL nativePlaybackPaused;
@property (nonatomic) CFTimeInterval lastDiagnosticWrite;
@property (nonatomic) NSDictionary *lastError;
- (void)attach:(UIView *)controls;
- (void)toggle;
- (void)stop;
- (void)tick;
- (void)showSettings;
- (void)updatePlaybackLabel;
- (void)nativePaused;
- (void)nativeSeeking;
- (void)nativePlaying;
- (void)writeDiagnostics:(BOOL)force;
@end

static const void *VOTButtonKey = &VOTButtonKey;
static const void *VOTControllerKey = &VOTControllerKey;
static const void *VOTSettingsButtonKey = &VOTSettingsButtonKey;
static NSHashTable<VOTController *> *VOTControllers;

@implementation VOTController
- (instancetype)init {
    if ((self = [super init])) {
        _language = [NSUserDefaults.standardUserDefaults stringForKey:@"VOTSourceLanguage"] ?: @"en";
        NSNumber *savedFraction = [NSUserDefaults.standardUserDefaults objectForKey:@"VOTOriginalVolume"];
        _originalFraction = savedFraction ? MAX(0, MIN(1, savedFraction.floatValue)) : 0.15;
        NSNumber *translatedVolume = [NSUserDefaults.standardUserDefaults objectForKey:@"VOTTranslationVolume"];
        _translationVolume = translatedVolume ? MAX(0, MIN(1, translatedVolume.floatValue)) : 1;
        _targetLanguage = [NSUserDefaults.standardUserDefaults stringForKey:@"VOTTargetLanguage"] ?: @"ru";
        _livelyVoice = [NSUserDefaults.standardUserDefaults boolForKey:@"VOTLivelyVoice"];
        _subtitlesEnabled = [NSUserDefaults.standardUserDefaults boolForKey:@"VOTSubtitles"];
        _lastVideoTime = NAN;
        __weak typeof(self) weakSelf = self;
        [VOTYandexLoginController readSessionCookie:^(NSString *cookie) { weakSelf.sessionCookie = cookie; }];
    }
    return self;
}
- (void)dealloc { [_timer invalidate]; [_client cancel]; [_subtitleClient cancel]; [_exportTask cancel]; [_audio pause]; [_subtitleLabel removeFromSuperview]; [self restoreVolume]; }
- (void)attach:(UIView *)controls {
    self.controls = controls;
    UIButton *button = objc_getAssociatedObject(controls, VOTButtonKey);
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.accessibilityIdentifier = @"VOTTranslateButton";
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.8;
        button.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.70];
        button.layer.cornerRadius = 20;
        button.layer.borderWidth = 0.5;
        button.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.25].CGColor;
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [button addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        [controls addSubview:button];
        objc_setAssociatedObject(controls, VOTButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    self.button = button;
    UIButton *settings = objc_getAssociatedObject(controls, VOTSettingsButtonKey);
    if (!settings) {
        settings = [UIButton buttonWithType:UIButtonTypeSystem];
        [settings setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];
        settings.tintColor = UIColor.whiteColor;
        settings.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.70];
        settings.layer.cornerRadius = 20;
        settings.accessibilityLabel = @"Настройки перевода";
        settings.accessibilityIdentifier = @"VOTSettingsButton";
        [controls addSubview:settings];
        objc_setAssociatedObject(controls, VOTSettingsButtonKey, settings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [settings removeTarget:nil action:@selector(showSettings) forControlEvents:UIControlEventTouchUpInside];
    [settings addTarget:self action:@selector(showSettings) forControlEvents:UIControlEventTouchUpInside];
    self.settingsButton = settings;
    UIEdgeInsets safe = controls.safeAreaInsets;
    CGFloat width = MIN(176, MAX(130, CGRectGetWidth(controls.bounds) - safe.left - safe.right - 24));
    button.frame = CGRectMake(safe.left + 12, MAX(50, safe.top + 44), width, 44);
    settings.frame = CGRectMake(CGRectGetMaxX(button.frame) + 6, CGRectGetMinY(button.frame), 44, 44);
    [button removeTarget:nil action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [button addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    BOOL visible = [controls respondsToSelector:NSSelectorFromString(@"isOverlayVisible")] ? Flag(controls, @"isOverlayVisible") : YES;
    button.hidden = !visible || CGRectGetHeight(controls.bounds) < 140 || Flag(self.owner, @"isInlinePlaybackActive");
    settings.hidden = button.hidden;
    [controls bringSubviewToFront:button];
    [controls bringSubviewToFront:settings];
    [self updateButton];
}
- (void)updateButton {
    [self.settingsController updateExportAvailable:self.audioURL != nil authenticated:self.sessionCookie.length > 0];
    [self updatePlaybackLabel];
    __weak typeof(self) weakSelf = self;
    UIAction *settings = [UIAction actionWithTitle:@"Настройки перевода" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf showSettings]; }];
    self.button.menu = [UIMenu menuWithTitle:@"Перевод видео" children:@[settings]];
}
- (void)updatePlaybackLabel {
    NSString *target = [@{@"ru":@"русский",@"en":@"английский",@"kk":@"казахский"} objectForKey:self.targetLanguage] ?: @"русский";
    VOTPlaybackState state = VOTGetPlaybackState(self.enabled,self.audio != nil,
        self.audio.currentItem.status == AVPlayerItemStatusReadyToPlay,(int)self.audio.timeControlStatus,
        self.nativePlaybackPaused,self.seeking,self.syncWantsPlay);
    NSString *title;
    switch (state) {
        case VOTPlaybackOff: title = [@"Перевести на " stringByAppendingString:target]; break;
        case VOTPlaybackRequesting: title = self.statusText ?: @"Отмена · готовится…"; break;
        case VOTPlaybackLoading: case VOTPlaybackPreparing: title = @"Подготовка озвучки…"; break;
        case VOTPlaybackBuffering: title = @"Буферизация озвучки…"; break;
        case VOTPlaybackPaused: title = @"Перевод на паузе"; break;
        case VOTPlaybackPlaying: title = self.livelyVoice ? @"Живые голоса · вкл." : @"Перевод включён"; break;
    }
    [self.button setTitle:title forState:UIControlStateNormal];
    self.button.accessibilityLabel = self.enabled ? (self.audio ? @"Выключить перевод" : @"Отменить перевод") : title;
    self.button.accessibilityValue = self.enabled ? title : nil;
    self.button.accessibilityHint = @"Нажмите для включения или выключения перевода. Удерживайте для выбора языка оригинала и громкости.";
    UIColor *color = state == VOTPlaybackPlaying ? UIColor.systemYellowColor : self.enabled ? UIColor.systemBlueColor : UIColor.whiteColor;
    [self.button setTitleColor:color forState:UIControlStateNormal];
}

- (void)showSettings {
    if (!self.owner.view.window) return;
    __weak typeof(self) weakSelf = self;
    [VOTYandexLoginController readSessionCookie:^(NSString *cookie) { weakSelf.sessionCookie = cookie; [weakSelf updateButton]; [weakSelf writeDiagnostics:YES]; }];
    NSDictionary *values = @{@"source":self.language,@"target":self.targetLanguage,@"lively":@(self.livelyVoice),
        @"subtitles":@(self.subtitlesEnabled),@"originalVolume":@(self.originalFraction),@"translationVolume":@(self.translationVolume),
        @"authenticated":@(self.sessionCookie.length > 0),@"canExport":@(self.audioURL != nil)};
    VOTSettingsController *settings = [[VOTSettingsController alloc] initWithValues:values change:^(NSString *key, id value) {
        [weakSelf applySetting:key value:value];
    } export:^(UIViewController *presenter) { [weakSelf exportAudioFrom:presenter]; }];
    self.settingsController = settings;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    nav.sheetPresentationController.prefersGrabberVisible = YES;
    UIViewController *presenter = self.owner;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:nav animated:YES completion:nil];
}
- (void)applySetting:(NSString *)key value:(id)value {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([key isEqual:@"originalVolume"]) {
        [self restoreVolume]; self.originalFraction = [value floatValue]; [defaults setFloat:self.originalFraction forKey:@"VOTOriginalVolume"]; return;
    }
    if ([key isEqual:@"translationVolume"]) {
        self.translationVolume = [value floatValue]; self.audio.volume = self.translationVolume;
        [defaults setFloat:self.translationVolume forKey:@"VOTTranslationVolume"]; return;
    }
    if ([key isEqual:@"subtitles"]) {
        self.subtitlesEnabled = [value boolValue]; [defaults setBool:self.subtitlesEnabled forKey:@"VOTSubtitles"];
        if (self.subtitlesEnabled && self.enabled) [self loadSubtitles];
        else { [self.subtitleClient cancel]; self.subtitleRequesting = NO; self.nextSubtitlePoll = nil; self.subtitleCues = nil; self.subtitleLabel.hidden = YES; }
        return;
    }
    if ([key isEqual:@"source"]) { self.language = value; [defaults setObject:value forKey:@"VOTSourceLanguage"]; }
    if ([key isEqual:@"target"]) { self.targetLanguage = value; [defaults setObject:value forKey:@"VOTTargetLanguage"]; }
    if ([key isEqual:@"lively"]) { self.livelyVoice = [value boolValue]; [defaults setBool:self.livelyVoice forKey:@"VOTLivelyVoice"]; }
    if ([key isEqual:@"authCookie"]) self.sessionCookie = value;
    if (self.enabled) { [self stop]; [self toggle]; }
    [self updateButton];
}
- (void)showNotice:(NSString *)message {
    if (!self.owner.view.window) return;
    UIViewController *presenter = self.owner;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Перевод видео" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Понятно" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}
- (void)exportAudioFrom:(UIViewController *)presenter {
    if (!self.audioURL || self.exportTask) return;
    [self.settingsController setExporting:YES];
    NSURL *source = self.audioURL;
    NSString *videoID = self.videoID ?: @"video";
    self.exportTask = [NSURLSession.sharedSession downloadTaskWithURL:source completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSURL *saved = nil;
        if (!error && [(NSHTTPURLResponse *)response statusCode] == 200 && location) {
            NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
            [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&error];
            saved = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"Перевод-%@.mp3",videoID]];
            if (![NSFileManager.defaultManager moveItemAtURL:location toURL:saved error:&error]) saved = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.exportTask = nil;
            [self.settingsController setExporting:NO];
            if (!saved || error) { [self showNotice:@"Не удалось скачать озвучку. Проверьте подключение и повторите."]; return; }
            if (!presenter.view.window) { [NSFileManager.defaultManager removeItemAtURL:saved.URLByDeletingLastPathComponent error:NULL]; return; }
            UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[saved] applicationActivities:nil];
            activity.popoverPresentationController.sourceView = presenter.view;
            activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),CGRectGetMidY(presenter.view.bounds),1,1);
            activity.completionWithItemsHandler = ^(__unused UIActivityType type, __unused BOOL completed, __unused NSArray *items, __unused NSError *shareError) {
                [NSFileManager.defaultManager removeItemAtURL:saved.URLByDeletingLastPathComponent error:NULL];
            };
            [presenter presentViewController:activity animated:YES completion:nil];
        });
    }];
    [self.exportTask resume];
}
- (void)loadSubtitles {
    if (!self.enabled || !self.subtitlesEnabled || self.subtitleRequesting) return;
    self.subtitleRequesting = YES;
    self.subtitleClient = [VOTClient new];
    NSUInteger generation = self.generation;
    [self.subtitleClient subtitlesForVideo:self.videoID language:self.language target:self.targetLanguage completion:^(NSDictionary *result, NSError *error) {
        if (!self.enabled || !self.subtitlesEnabled || generation != self.generation) return;
        self.subtitleRequesting = NO;
        if (error) { [self showNotice:[@"Субтитры пока недоступны. " stringByAppendingString:error.localizedDescription]]; return; }
        if ([result[@"waiting"] boolValue]) self.nextSubtitlePoll = [NSDate dateWithTimeIntervalSinceNow:15];
        else self.subtitleCues = result[@"cues"];
    }];
}
- (void)updateSubtitlesAtTime:(double)time allowed:(BOOL)allowed {
    NSString *text = self.subtitlesEnabled && allowed ? VOTSubtitleText(self.subtitleCues ?: @[], time) : nil;
    if (!text.length) { self.subtitleLabel.hidden = YES; return; }
    UIView *playerView = Object(self.owner,@"playerView");
    if (![playerView isKindOfClass:UIView.class]) return;
    if (!self.subtitleLabel) {
        self.subtitleLabel = [UILabel new]; self.subtitleLabel.numberOfLines = 3;
        self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
        self.subtitleLabel.textColor = UIColor.whiteColor;
        self.subtitleLabel.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.72];
        self.subtitleLabel.layer.cornerRadius = 6; self.subtitleLabel.clipsToBounds = YES;
        self.subtitleLabel.userInteractionEnabled = NO;
        self.subtitleLabel.accessibilityIdentifier = @"VOTSubtitleText";
    }
    if (self.subtitleLabel.superview != playerView) [playerView addSubview:self.subtitleLabel];
    CGFloat width = MIN(720, CGRectGetWidth(playerView.bounds)-24);
    self.subtitleLabel.font = [UIFont systemFontOfSize:MAX(13,MIN(20,width/28)) weight:UIFontWeightMedium];
    self.subtitleLabel.text = text;
    CGFloat height = MIN(90, [self.subtitleLabel sizeThatFits:CGSizeMake(width-12,90)].height+12);
    self.subtitleLabel.frame = CGRectMake((CGRectGetWidth(playerView.bounds)-width)/2,MAX(94,CGRectGetHeight(playerView.bounds)-height-48),width,height);
    self.subtitleLabel.hidden = NO; [playerView bringSubviewToFront:self.subtitleLabel];
}

- (void)showError:(NSString *)message {
    [self stop];
    NSLog(@"[YouTubeVOT] %@", message);
    if (!self.owner.view.window) return;
    UIViewController *presenter = self.owner;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) presenter = presenter.presentedViewController;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Перевод видео" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Понятно" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
    [self writeDiagnostics:YES];
}
- (void)toggle {
    if (self.enabled) { [self stop]; return; }
    for (VOTController *other in VOTControllers) if (other != self) [other stop];
    NSString *videoID = VideoID(self.owner);
    double duration = Number(self.owner, @"currentVideoTotalMediaTime");
    id native = Object(self.owner, @"contentVideo") ?: Object(self.owner, @"activeVideo");
    if (!videoID.length || !isfinite(duration) || duration <= 0 || duration > 14400 || Flag(Object(native, @"playerItem"), @"playerResponseIsLive")) {
        [self showError:@"Пока поддерживаются обычные ролики длительностью до 4 часов. Откройте ролик и дождитесь начала воспроизведения."]; return;
    }
    if (Flag(self.owner, @"isExternalPlaybackActive") || Flag(self.owner, @"isMDXActive")) {
        [self showError:@"Перевод доступен при воспроизведении на этом iPhone. Отключите трансляцию на другое устройство."]; return;
    }
    self.enabled = YES; self.videoID = videoID; self.started = NSDate.date;
    self.nativePlaybackPaused = [native respondsToSelector:NSSelectorFromString(@"attemptingToPlay")] && !Flag(native,@"attemptingToPlay");
    self.lastError = nil; self.motionState = (VOTMotionState){0};
    self.syncState = (VOTSyncState){0}; self.syncSeekCount = 0; self.nativePauseCount = 0;
    self.requestedAudioRate = 0; self.syncWantsPlay = NO; self.forceAudioSync = YES;
    self.client = [VOTClient new]; self.lastVideoTime = NAN;
    self.client.responseLanguage = self.targetLanguage; self.client.livelyVoice = self.livelyVoice;
    self.client.sessionCookie = self.sessionCookie;
    self.statusText = @"Отмена · запрос…";
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:0.15 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf tick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self updateButton];
    NSUInteger generation = self.generation;
    [VOTYandexLoginController readSessionCookie:^(NSString *cookie) {
        if (!self.enabled || generation != self.generation) return;
        self.sessionCookie = cookie; self.client.sessionCookie = cookie;
        [self updateButton]; [self writeDiagnostics:YES]; [self requestTranslation:YES];
    }];
}
- (void)requestTranslation:(BOOL)first {
    if (!self.enabled || self.requesting) return;
    self.requesting = YES;
    NSUInteger generation = self.generation;
    [self.client translateVideo:self.videoID duration:Number(self.owner, @"currentVideoTotalMediaTime") language:self.language first:first completion:^(NSDictionary *result, NSError *error) {
        if (!self.enabled || generation != self.generation) return;
        self.requesting = NO;
        if (![VideoID(self.owner) isEqual:self.videoID]) { [self stop]; return; }
        if (error) {
            NSMutableDictionary *detail = [@{@"code":@(error.code),@"message":error.localizedDescription} mutableCopy];
            for (NSString *key in @[@"VOTRequestPath",@"VOTHTTPStatus",@"VOTCookieAttached",@"VOTServiceReason"]) if (error.userInfo[key]) detail[key] = error.userInfo[key];
            self.lastError = detail;
            [self showError:[@"Не удалось получить перевод. " stringByAppendingString:error.localizedDescription]]; return;
        }
        NSInteger status = [result[@"status"] integerValue];
        if (status == 0 || status == 7) {
            [self showError:status == 7 ? @"Для этого перевода нужен вход в Яндекс. Откройте настройки перевода → Аккаунт Яндекса." : @"Сервис не смог перевести этот ролик. Попробуйте другой ролик или повторите позже."]; return;
        }
        NSTimeInterval delay = MAX(5, MIN(30, [result[@"remainingTime"] doubleValue]));
        if (status == 1 || status == 5) {
            if (self.livelyVoice && ![result[@"isLivelyVoice"] boolValue]) {
                [self showError:self.sessionCookie.length ? @"Сервис вернул обычную озвучку вместо живых голосов. Выберите обычные голоса или попробуйте другой ролик." : @"Живые голоса для этого ролика не получены. Откройте настройки → Аккаунт Яндекса и войдите, либо выберите обычные голоса."]; return;
            }
            NSURL *url = [NSURL URLWithString:result[@"url"]];
            if (!self.audio || status == 1) {
                [self.audio pause]; [self restoreVolume];
                self.audio = [AVPlayer playerWithURL:url];
                self.audioURL = url; self.audio.volume = self.translationVolume;
                self.audio.allowsExternalPlayback = NO;
                self.audio.automaticallyWaitsToMinimizeStalling = YES;
                self.audio.currentItem.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmTimeDomain;
                self.lastVideoTime = NAN;
                self.motionState = (VOTMotionState){0}; self.seeking = NO;
                self.syncState = (VOTSyncState){0}; self.forceAudioSync = YES;
                self.requestedAudioRate = 0; self.syncWantsPlay = NO;
            }
            self.statusText = status == 5 ? @"Частичный перевод" : @"Перевод включён";
            self.refreshAudio = status == 5 ? [NSDate dateWithTimeIntervalSinceNow:delay] : nil;
            self.nextPoll = nil;
            if (self.subtitlesEnabled && !self.subtitleCues.count && !self.subtitleRequesting && !self.nextSubtitlePoll) [self loadSubtitles];
        } else {
            self.statusText = @"Отмена · готовится…";
            self.nextPoll = [NSDate dateWithTimeIntervalSinceNow:delay];
        }
        [self updateButton];
    }];
}
- (void)restoreVolume {
    if (self.ducked) SetFloat(self.duckedVideo, @"setVolume:", self.savedVolume);
    self.ducked = NO; self.duckedVideo = nil;
}
- (void)duckVideo:(id)video {
    if (self.ducked && self.duckedVideo != video) [self restoreVolume];
    if (!self.ducked) {
        double volume = Number(video, @"volume");
        if (!isfinite(volume)) return;
        self.savedVolume = volume; self.duckedVideo = video; self.ducked = YES;
    }
    float desired = self.savedVolume * self.originalFraction;
    double current = Number(video,@"volume");
    if (!isfinite(current) || fabs(current-desired) > 0.005) SetFloat(video,@"setVolume:",desired);
}
- (void)stop {
    self.generation++; self.enabled = NO; self.requesting = NO; self.seeking = NO;
    [self.client cancel]; self.client = nil;
    [self.subtitleClient cancel]; self.subtitleClient = nil; self.subtitleRequesting = NO;
    self.subtitleCues = nil; self.nextSubtitlePoll = nil;
    [self.subtitleLabel removeFromSuperview]; self.subtitleLabel = nil;
    [self.timer invalidate]; self.timer = nil;
    [self.audio pause]; self.audio = nil;
    self.audioURL = nil;
    [self restoreVolume];
    self.videoID = nil; self.nextPoll = nil; self.refreshAudio = nil; self.statusText = nil;
    self.motionState = (VOTMotionState){0};
    self.syncState = (VOTSyncState){0}; self.forceAudioSync = NO;
    self.syncWantsPlay = NO; self.requestedAudioRate = 0;
    [self updateButton];
    [self writeDiagnostics:YES];
}
- (void)nativePaused {
    self.nativePlaybackPaused = YES;
    self.nativePauseCount++;
    self.motionState = (VOTMotionState){0};
    [self.audio pause]; [self restoreVolume];
    self.requestedAudioRate = 0; self.syncWantsPlay = NO;
    [self updatePlaybackLabel];
}
- (void)nativeSeeking {
    self.motionState = (VOTMotionState){0}; self.forceAudioSync = YES;
    [self.audio pause]; self.requestedAudioRate = 0; self.syncWantsPlay = NO;
}
- (void)nativePlaying {
    self.nativePlaybackPaused = NO; self.motionState = (VOTMotionState){0};
}
- (void)writeDiagnostics:(BOOL)force {
    if (!force && CACurrentMediaTime()-self.lastDiagnosticWrite < 2) return;
    self.lastDiagnosticWrite = CACurrentMediaTime();
    id native = Object(self.owner,@"contentVideo") ?: Object(self.owner,@"activeVideo");
    id (^number)(double) = ^id(double value) { return isfinite(value) ? @(value) : NSNull.null; };
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSMutableDictionary *state = [@{@"build":@"2026-11-17.5",@"timestamp":@(NSDate.date.timeIntervalSince1970),
        @"enabled":@(self.enabled),@"cookiePresent":@(self.sessionCookie.length > 0),@"lively":@(self.livelyVoice),
        @"source":self.language ?: @"",@"target":self.targetLanguage ?: @"",@"originalVolume":@(self.originalFraction),
        @"translationVolume":@(self.translationVolume),@"nativeVolume":number(Number(native,@"volume")),
        @"videoTime":number(Number(self.owner,@"contentVideoMediaTime")),@"audioTime":number(self.audio ? CMTimeGetSeconds(self.audio.currentTime) : NAN),
        @"audioRate":@(self.audio.rate),@"audioStatus":@(self.audio.currentItem.status),@"audioControl":@(self.audio.timeControlStatus),
        @"seeking":@(self.seeking),@"ducked":@(self.ducked),@"audioSessionCategory":session.category ?: @"",@"outputVolume":@(session.outputVolume),
        @"syncSeeks":@(self.syncSeekCount),@"nativePauses":@(self.nativePauseCount),@"syncTarget":number(self.syncTargetTime),
        @"syncWantsPlay":@(self.syncWantsPlay),@"requestedRate":@(self.requestedAudioRate)} mutableCopy];
    if (self.lastError) state[@"lastError"] = self.lastError;
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSData *json = [NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
    [json writeToURL:[documents URLByAppendingPathComponent:@"VOTDiagnostics.json"] atomically:YES];
}
- (void)tick {
    if (!self.enabled) return;
    if (!self.owner || ![VideoID(self.owner) isEqual:self.videoID]) { [self stop]; return; }
    [self updatePlaybackLabel];
    [self writeDiagnostics:NO];
    if (self.nextSubtitlePoll && self.nextSubtitlePoll.timeIntervalSinceNow <= 0) { self.nextSubtitlePoll = nil; [self loadSubtitles]; }
    if (self.nextPoll && self.nextPoll.timeIntervalSinceNow <= 0) {
        self.nextPoll = nil; [self requestTranslation:NO];
    }
    if (self.refreshAudio && self.refreshAudio.timeIntervalSinceNow <= 0) {
        self.refreshAudio = nil; [self requestTranslation:NO];
    }
    if (!self.audio) {
        if (-self.started.timeIntervalSinceNow > 1200) [self showError:@"Сервис слишком долго готовит перевод. Попробуйте повторить позже."];
        return;
    }
    if (self.audio.currentItem.status == AVPlayerItemStatusFailed) { [self showError:@"Не удалось воспроизвести аудио перевода. Проверьте интернет и повторите попытку."]; return; }
    id native = Object(self.owner, @"contentVideo") ?: Object(self.owner, @"activeVideo");
    double time = Number(self.owner, @"contentVideoMediaTime");
    if (!isfinite(time)) time = Number(self.owner, @"currentVideoMediaTime");
    float rate = Number(native, @"playbackRate");
    double now = CACurrentMediaTime();
    VOTMotionState motion = self.motionState;
    BOOL moving = VOTTrackMotion(&motion,time,now,rate) && !self.nativePlaybackPaused;
    self.motionState = motion;
    double masterTime = self.nativePlaybackPaused ? time : VOTProjectedTime(&motion,now,rate);
    self.syncTargetTime = masterTime;
    if (motion.discontinuity) self.forceAudioSync = YES;
    self.lastVideoTime = time; self.lastTick = CACurrentMediaTime();
    BOOL allowed = self.audio.currentItem.status == AVPlayerItemStatusReadyToPlay &&
        !Flag(self.owner, @"isPlayingAd") && !Flag(self.owner, @"isExternalPlaybackActive") && !Flag(self.owner, @"isMDXActive") &&
        !Flag(native, @"isExternalPlaybackActive");
    [self updateSubtitlesAtTime:masterTime allowed:allowed];
    VOTSyncState sync = self.syncState;
    VOTSyncDecision d = VOTDecideSmoothSync(&sync,masterTime,CMTimeGetSeconds(self.audio.currentTime),rate,moving,allowed,now,self.forceAudioSync);
    if (!self.seeking) self.syncState = sync;
    self.syncWantsPlay = d.play; self.syncRate = d.rate;
    if (!d.play) {
        if (self.requestedAudioRate != 0 || self.audio.rate != 0) [self.audio pause];
        self.requestedAudioRate = 0; [self restoreVolume];
    }
    else if (allowed) [self duckVideo:native];
    if (!allowed || self.seeking) return;
    double audioDuration = CMTimeGetSeconds(self.audio.currentItem.duration);
    if (isfinite(audioDuration) && time >= audioDuration - 0.1) { [self.audio pause]; [self restoreVolume]; return; }
    if (d.seek) {
        [self.audio pause]; self.requestedAudioRate = 0; self.seeking = YES;
        self.forceAudioSync = NO; self.syncSeekCount++;
        NSUInteger generation = self.generation;
        AVPlayer *audio = self.audio;
        __weak typeof(self) weakSelf = self;
        CMTime tolerance = CMTimeMakeWithSeconds(0.08*rate,600);
        [audio seekToTime:CMTimeMakeWithSeconds(d.time,600) toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                VOTController *self = weakSelf;
                if (!self || generation != self.generation || self.audio != audio) return;
                self.seeking = NO;
                if (finished && self.enabled && self.syncWantsPlay && !self.forceAudioSync) {
                    [audio playImmediatelyAtRate:self.syncRate]; self.requestedAudioRate = self.syncRate;
                }
            });
        }]; return;
    }
    if (d.play) {
        if (fabs(self.requestedAudioRate-d.rate) > 0.0025) { self.audio.rate = d.rate; self.requestedAudioRate = d.rate; }
        [self duckVideo:native];
    }
}
@end

static void (*OriginalLayout)(id, SEL);
static void (*OriginalNativePause)(id, SEL, int);
static void (*OriginalNativePlay)(id, SEL);
static void NativePlay(id self, SEL selector) {
    OriginalNativePlay(self,selector);
    void (^notify)(void) = ^{
        for (VOTController *controller in VOTControllers.allObjects)
            if (controller.enabled && (Object(controller.owner,@"contentVideo") == self || Object(controller.owner,@"activeVideo") == self)) [controller nativePlaying];
    };
    if (NSThread.isMainThread) notify(); else dispatch_async(dispatch_get_main_queue(),notify);
}
static void (*OriginalNativeSeek)(id, SEL, double, int);
static void (*OriginalNativeTolerantSeek)(id, SEL, double, double, double, int);
static void NotifyNativeSeek(id native) {
    void (^notify)(void) = ^{
        for (VOTController *controller in VOTControllers.allObjects)
            if (controller.enabled && (Object(controller.owner,@"contentVideo") == native || Object(controller.owner,@"activeVideo") == native)) [controller nativeSeeking];
    };
    if (NSThread.isMainThread) notify(); else dispatch_async(dispatch_get_main_queue(),notify);
}
static void NativeSeek(id self, SEL selector, double time, int source) {
    OriginalNativeSeek(self,selector,time,source); NotifyNativeSeek(self);
}
static void NativeTolerantSeek(id self, SEL selector, double time, double before, double after, int source) {
    OriginalNativeTolerantSeek(self,selector,time,before,after,source); NotifyNativeSeek(self);
}
static void NativePause(id self, SEL selector, int reason) {
    OriginalNativePause(self,selector,reason);
    void (^notify)(void) = ^{
        for (VOTController *controller in VOTControllers.allObjects)
            if (controller.enabled && (Object(controller.owner,@"contentVideo") == self || Object(controller.owner,@"activeVideo") == self)) [controller nativePaused];
    };
    if (NSThread.isMainThread) notify(); else dispatch_async(dispatch_get_main_queue(),notify);
}
static void Layout(id self, SEL selector) {
    OriginalLayout(self, selector);
    UIViewController *owner = PlayerForView(self);
    if (!owner) return;
    VOTController *controller = objc_getAssociatedObject(owner, VOTControllerKey);
    if (!controller) {
        controller = [VOTController new]; controller.owner = owner;
        objc_setAssociatedObject(owner, VOTControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [VOTControllers addObject:controller];
    }
    [controller attach:self];
}
__attribute__((constructor)) static void VOTInitialize(void) {
    VOTInstallStartupGuard();
    dispatch_async(dispatch_get_main_queue(), ^{
        VOTInstallStartupGuard();
        VOTControllers = [NSHashTable weakObjectsHashTable];
        Class cls = NSClassFromString(@"YTMainAppControlsOverlayView");
        SEL selector = @selector(layoutSubviews);
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        if (!method) { NSLog(@"[YouTubeVOT] Unsupported player overlay"); return; }
        OriginalLayout = (void (*)(id, SEL))method_getImplementation(method);
        class_replaceMethod(cls, selector, (IMP)Layout, method_getTypeEncoding(method));
        Class native = NSClassFromString(@"YTSingleVideoController");
        SEL pause = NSSelectorFromString(@"pauseWithStoppageReason:");
        Method pauseMethod = native ? class_getInstanceMethod(native,pause) : NULL;
        if (pauseMethod) {
            OriginalNativePause = (void (*)(id,SEL,int))method_getImplementation(pauseMethod);
            class_replaceMethod(native,pause,(IMP)NativePause,method_getTypeEncoding(pauseMethod));
        }
        Method playMethod = native ? class_getInstanceMethod(native,@selector(play)) : NULL;
        if (playMethod) {
            OriginalNativePlay = (void (*)(id,SEL))method_getImplementation(playMethod);
            class_replaceMethod(native,@selector(play),(IMP)NativePlay,method_getTypeEncoding(playMethod));
        }
        SEL seek = NSSelectorFromString(@"seekToTime:seekSource:");
        Method seekMethod = native ? class_getInstanceMethod(native,seek) : NULL;
        if (seekMethod) {
            OriginalNativeSeek = (void (*)(id,SEL,double,int))method_getImplementation(seekMethod);
            class_replaceMethod(native,seek,(IMP)NativeSeek,method_getTypeEncoding(seekMethod));
        }
        SEL tolerantSeek = NSSelectorFromString(@"seekToTime:toleranceBefore:toleranceAfter:seekSource:");
        Method tolerantMethod = native ? class_getInstanceMethod(native,tolerantSeek) : NULL;
        if (tolerantMethod) {
            OriginalNativeTolerantSeek = (void (*)(id,SEL,double,double,double,int))method_getImplementation(tolerantMethod);
            class_replaceMethod(native,tolerantSeek,(IMP)NativeTolerantSeek,method_getTypeEncoding(tolerantMethod));
        }
        NSLog(@"[YouTubeVOT] Loaded prototype for YouTube 20.44.2");
    });
}
