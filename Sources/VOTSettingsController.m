#import "VOTSettingsController.h"
#import <WebKit/WebKit.h>

static NSArray<NSArray<NSString *> *> *SourceLanguages(void) {
    return @[@[@"en",@"Английский"],@[@"de",@"Немецкий"],@[@"fr",@"Французский"],@[@"es",@"Испанский"],@[@"it",@"Итальянский"],@[@"ja",@"Японский"],@[@"ko",@"Корейский"],@[@"zh",@"Китайский"]];
}
static NSArray<NSArray<NSString *> *> *TargetLanguages(void) {
    return @[@[@"ru",@"Русский"],@[@"en",@"Английский"],@[@"kk",@"Казахский"]];
}
static NSString *LanguageName(NSString *code) {
    for (NSArray *pair in [SourceLanguages() arrayByAddingObjectsFromArray:TargetLanguages()]) if ([pair[0] isEqual:code]) return pair[1];
    return code;
}

@interface VOTSettingsController ()
@property (nonatomic) NSMutableDictionary *values;
@property (nonatomic, copy) VOTSettingChange change;
@property (nonatomic, copy) void (^exportAudio)(UIViewController *);
@end
@implementation VOTSettingsController
- (instancetype)initWithValues:(NSDictionary *)values change:(VOTSettingChange)change export:(void (^)(UIViewController *))export {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _values = [values mutableCopy]; _change = [change copy]; _exportAudio = [export copy];
        self.title = @"Настройки перевода"; self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Готово" style:UIBarButtonItemStyleDone target:self action:@selector(close)];
    self.tableView.accessibilityIdentifier = @"VOTSettingsTable";
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)updateExportAvailable:(BOOL)available authenticated:(BOOL)authenticated {
    if ([self.values[@"canExport"] boolValue] == available && [self.values[@"authenticated"] boolValue] == authenticated) return;
    self.values[@"canExport"] = @(available); self.values[@"authenticated"] = @(authenticated);
    if (self.isViewLoaded) [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:4] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)setExporting:(BOOL)exporting {
    self.values[@"exporting"] = @(exporting);
    if (self.isViewLoaded) [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:4] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)setValue:(id)value forSetting:(NSString *)key {
    self.values[key] = value; self.change(key, value);
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 5; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 2 ? 1 : 2; }
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Языки",@"Озвучка",@"Субтитры",@"Громкость",@"Дополнительно"][section];
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"При смене языка активный перевод будет запрошен заново.";
    if (section == 1) return @"Для живых голосов может потребоваться вход в Яндекс. Доступность зависит от ролика и сервиса.";
    if (section == 2) return @"Субтитры на языке перевода, если они доступны у сервиса.";
    if (section == 4) return @"Удержание кнопки перевода также открывает эти настройки. Озвучку можно сохранить через меню iOS после её подготовки.";
    return nil;
}
- (CGFloat)tableView:(__unused UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    return path.section == 3 ? 88 : path.section == 1 ? 76 : UITableViewAutomaticDimension;
}
- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor; cell.detailTextLabel.numberOfLines = 0;
    if (path.section == 0) {
        NSString *key = path.row == 0 ? @"source" : @"target";
        cell.textLabel.text = path.row == 0 ? @"Оригинал" : @"Перевод";
        UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
        menuButton.accessibilityIdentifier = path.row == 0 ? @"VOTSourceLanguage" : @"VOTTargetLanguage";
        [menuButton setTitle:[LanguageName(self.values[key]) stringByAppendingString:@"  ⌄"] forState:UIControlStateNormal];
        menuButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        menuButton.frame = CGRectMake(0,0,190,44);
        menuButton.showsMenuAsPrimaryAction = YES;
        NSMutableArray *actions = [NSMutableArray array];
        __weak typeof(self) weakSelf = self;
        for (NSArray *pair in path.row == 0 ? SourceLanguages() : TargetLanguages()) {
            UIAction *action = [UIAction actionWithTitle:pair[1] image:nil identifier:nil handler:^(__unused UIAction *a) {
                [weakSelf setValue:pair[0] forSetting:key]; [weakSelf.tableView reloadData];
            }];
            action.state = [self.values[key] isEqual:pair[0]] ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:action];
        }
        menuButton.menu = [UIMenu menuWithTitle:cell.textLabel.text children:actions];
        cell.accessoryView = menuButton; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 1) {
        BOOL lively = [self.values[@"lively"] boolValue];
        cell.textLabel.text = path.row == 0 ? @"Обычные голоса" : @"Живые голоса";
        cell.detailTextLabel.text = path.row == 0 ? @"Быстрая закадровая озвучка" : @"Голоса, похожие на голоса авторов видео";
        cell.accessoryType = (path.row == 1) == lively ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.accessibilityIdentifier = path.row == 0 ? @"VOTClassicVoices" : @"VOTLivelyVoices";
    } else if (path.section == 2) {
        cell.textLabel.text = @"Показывать субтитры";
        UISwitch *toggle = [UISwitch new]; toggle.on = [self.values[@"subtitles"] boolValue];
        toggle.accessibilityIdentifier = @"VOTSubtitlesSwitch";
        [toggle addTarget:self action:@selector(subtitlesChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 3) {
        BOOL original = path.row == 0;
        NSString *key = original ? @"originalVolume" : @"translationVolume";
        UILabel *label = [UILabel new]; label.tag = 700;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        label.text = [NSString stringWithFormat:@"%@: %.0f%%", original ? @"Оригинал" : @"Перевод", [self.values[key] floatValue]*100];
        UISlider *slider = [UISlider new]; slider.tag = path.row;
        slider.minimumValue = 0; slider.maximumValue = 1; slider.value = [self.values[key] floatValue];
        slider.accessibilityLabel = original ? @"Громкость оригинала" : @"Громкость перевода";
        slider.accessibilityIdentifier = original ? @"VOTOriginalVolume" : @"VOTTranslationVolume";
        [slider addTarget:self action:@selector(volumeChanged:) forControlEvents:UIControlEventValueChanged];
        label.translatesAutoresizingMaskIntoConstraints = NO; slider.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:label]; [cell.contentView addSubview:slider];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
            [label.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [slider.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
            [slider.trailingAnchor constraintEqualToAnchor:label.trailingAnchor],
            [slider.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:6],
            [slider.heightAnchor constraintEqualToConstant:32]]];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = path.row == 0 ? ([self.values[@"exporting"] boolValue] ? @"Скачивание…" : @"Скачать озвучку") : @"Аккаунт Яндекса";
        cell.detailTextLabel.text = path.row == 0 ? ([self.values[@"canExport"] boolValue] ? @"Сохранить аудиофайл или поделиться" : @"Сначала включите и дождитесь перевода") : ([self.values[@"authenticated"] boolValue] ? @"Вход выполнен" : @"Войти для живых голосов");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityIdentifier = path.row == 0 ? @"VOTExportAudio" : @"VOTYandexAccount";
        if (path.row == 0 && ![self.values[@"canExport"] boolValue]) { cell.textLabel.textColor = UIColor.tertiaryLabelColor; cell.selectionStyle = UITableViewCellSelectionStyleNone; }
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 1) {
        [self setValue:@(path.row == 1) forSetting:@"lively"]; [tableView reloadData];
    } else if (path.section == 4 && path.row == 0 && [self.values[@"canExport"] boolValue]) {
        self.exportAudio(self);
    } else if (path.section == 4 && path.row == 1) {
        __weak typeof(self) weakSelf = self;
        VOTYandexLoginController *login = [[VOTYandexLoginController alloc] initWithCompletion:^(NSString *cookie) {
            [weakSelf setValue:cookie forSetting:@"authCookie"];
            weakSelf.values[@"authenticated"] = @YES;
            [weakSelf.navigationController popViewControllerAnimated:YES];
            [weakSelf.tableView reloadData];
        }];
        [self.navigationController pushViewController:login animated:YES];
    }
}
- (void)subtitlesChanged:(UISwitch *)sender { [self setValue:@(sender.on) forSetting:@"subtitles"]; }
- (void)volumeChanged:(UISlider *)sender {
    BOOL original = sender.tag == 0;
    [self setValue:@(sender.value) forSetting:original ? @"originalVolume" : @"translationVolume"];
    UILabel *label = [sender.superview viewWithTag:700];
    label.text = [NSString stringWithFormat:@"%@: %.0f%%",original ? @"Оригинал" : @"Перевод",sender.value*100];
}
@end

@interface VOTYandexLoginController ()
@property (nonatomic) WKWebView *webView;
@property (nonatomic, copy) void (^completion)(NSString *);
@end
@implementation VOTYandexLoginController
- (instancetype)initWithCompletion:(void (^)(NSString *))completion {
    if ((self = [super init])) { _completion = [completion copy]; self.title = @"Вход в Яндекс"; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.webView];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Готово" style:UIBarButtonItemStyleDone target:self action:@selector(finish)];
    [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://passport.yandex.ru/auth?retpath=https%3A%2F%2Fyandex.ru"]]];
}
+ (void)readSessionCookie:(void (^)(NSString *))completion {
    [WKWebsiteDataStore.defaultDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        for (NSHTTPCookie *cookie in cookies) {
            if ([cookie.name isEqual:@"Session_id"] && [@[@".yandex.ru",@"yandex.ru"] containsObject:cookie.domain] && (!cookie.expiresDate || cookie.expiresDate.timeIntervalSinceNow > 0)) {
                completion([@"Session_id=" stringByAppendingString:cookie.value]); return;
            }
        }
        completion(@"");
    }];
}
- (void)finish {
    [VOTYandexLoginController readSessionCookie:^(NSString *cookie) {
        if (cookie.length) self.completion(cookie);
        else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Завершите вход" message:@"Войдите в аккаунт на странице Яндекса, затем нажмите «Готово»." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Понятно" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }];
}
@end
