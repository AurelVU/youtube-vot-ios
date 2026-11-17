#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^VOTSettingChange)(NSString *key, id value);
@interface VOTSettingsController : UITableViewController
- (instancetype)initWithValues:(NSDictionary *)values change:(VOTSettingChange)change export:(void (^)(UIViewController *presenter))export;
- (void)updateExportAvailable:(BOOL)available authenticated:(BOOL)authenticated;
- (void)setExporting:(BOOL)exporting;
@end

@interface VOTYandexLoginController : UIViewController
- (instancetype)initWithCompletion:(void (^)(NSString *cookie))completion;
+ (void)readSessionCookie:(void (^)(NSString *cookie))completion;
@end
NS_ASSUME_NONNULL_END
