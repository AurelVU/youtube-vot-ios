#import <Foundation/Foundation.h>
#import <dlfcn.h>
@interface ASWAppsListPersistenceUtils : NSObject
+ (id)readWebProductsArrayFromProductsJSON:(NSData *)data;
+ (id)readProductsArrayFromProductsJSON:(NSData *)data;
@end
@implementation ASWAppsListPersistenceUtils
+ (id)readWebProductsArrayFromProductsJSON:(NSData *)data { return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]; }
+ (id)readProductsArrayFromProductsJSON:(NSData *)data { return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]; }
@end
static unsigned failures;
#define CHECK(c,m) do { if (!(c)) { NSLog(@"FAIL: %s",m); failures++; } } while(0)
int main(void) { @autoreleasepool {
    BOOL (*install)(void) = dlsym(RTLD_DEFAULT,"VOTInstallStartupGuard");
    if (install) { CHECK(install(),"known startup parsers found"); CHECK(install(),"guard installation is idempotent"); }
    for (NSString *method in @[@"readWebProductsArrayFromProductsJSON:",@"readProductsArrayFromProductsJSON:"]) {
        @try {
            id result = [ASWAppsListPersistenceUtils performSelector:NSSelectorFromString(method) withObject:nil];
            CHECK(result == nil,"missing bundled JSON returns no product list");
        } @catch (__unused NSException *exception) { CHECK(NO,"missing bundled JSON must not terminate startup"); }
        NSData *valid = [@"[\"product\"]" dataUsingEncoding:NSUTF8StringEncoding];
        id result = [ASWAppsListPersistenceUtils performSelector:NSSelectorFromString(method) withObject:valid];
        CHECK([result isEqual:@[@"product"]],"valid product data keeps its original behavior");
        id invalid = [ASWAppsListPersistenceUtils performSelector:NSSelectorFromString(method) withObject:[@"broken JSON" dataUsingEncoding:NSUTF8StringEncoding]];
        CHECK(invalid == nil,"invalid nonnil JSON keeps Foundation parse failure behavior");
    }
    BOOL threw = NO;
    @try { [NSJSONSerialization JSONObjectWithData:nil options:0 error:NULL]; } @catch (__unused NSException *exception) { threw = YES; }
    CHECK(threw,"unrelated Foundation JSON behavior is unchanged");
    NSLog(@"Startup guard tests: %u failures",failures); return failures ? 1 : 0;
} }
