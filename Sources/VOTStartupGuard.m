#import "VOTStartupGuard.h"
#import <objc/runtime.h>

static id (*ReadWebProducts)(id,SEL,NSData *);
static id (*ReadProducts)(id,SEL,NSData *);

static id SafeReadWebProducts(id cls, SEL selector, NSData *data) {
    return data ? ReadWebProducts(cls,selector,data) : nil;
}
static id SafeReadProducts(id cls, SEL selector, NSData *data) {
    return data ? ReadProducts(cls,selector,data) : nil;
}
static BOOL Install(Class cls, NSString *name, IMP replacement, IMP *original) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getClassMethod(cls,selector);
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    if (method_getImplementation(method) == replacement) return YES;
    char result[8], argument[8];
    method_getReturnType(method,result,sizeof(result)); method_getArgumentType(method,2,argument,sizeof(argument));
    if (result[0] != '@' || argument[0] != '@') return NO;
    *original = method_getImplementation(method);
    class_replaceMethod(object_getClass(cls),selector,replacement,method_getTypeEncoding(method));
    return YES;
}
BOOL VOTInstallStartupGuard(void) {
    // YouTube 20.44.2's ASW fallback parsers pass missing bundled JSON to Foundation.
    Class cls = NSClassFromString(@"ASWAppsListPersistenceUtils");
    if (!cls) return NO;
    BOOL web = Install(cls,@"readWebProductsArrayFromProductsJSON:",(IMP)SafeReadWebProducts,(IMP *)&ReadWebProducts);
    BOOL products = Install(cls,@"readProductsArrayFromProductsJSON:",(IMP)SafeReadProducts,(IMP *)&ReadProducts);
    return web && products;
}
