// TPlayerFakeVIP v3 — crash-safe: network-only hooks, no UserDefaults/JSONDecoder swizzle.
// Inject via TrollFools into com.twanjia.teslaplayer

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const kBundleID = @"com.twanjia.teslaplayer";
static NSString *const kEnabledKey = @"tp_fake_vip.enabled";
static NSString *const kLogTag = @"[TPlayerFakeVIP]";

static BOOL TPFakeVIPEnabled(void) {
    if ([[NSUserDefaults standardUserDefaults] objectForKey:kEnabledKey] == nil) return YES;
    return [[NSUserDefaults standardUserDefaults] boolForKey:kEnabledKey];
}

#pragma mark - JSON helpers

static NSData *TPJSONData(id obj) {
    if (!obj) return nil;
    @try {
        return [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static id TPJSONParse(NSData *data) {
    if (!data.length) return nil;
    @try {
        return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static BOOL TPURLHas(NSURL *url, NSString *needle) {
    if (!url || !needle.length) return NO;
    NSString *abs = url.absoluteString;
    if (!abs.length) return NO;
    return [abs rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL TPShouldPatchURL(NSURL *url) {
    if (!TPFakeVIPEnabled() || !url) return NO;
    if (!TPURLHas(url, @"teslaapi.twanjia.com")) return NO;

    static NSArray<NSString *> *paths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = @[
            @"/vip/checkVipStatus",
            @"/vip/activateWithIAP",
            @"/vip/getPlanList",
            @"/user/getUserInfo",
            @"/effect/myUnlocks",
            @"/wallpaper/getMyUnlocks",
            @"/wallpaper/iapProducts",
        ];
    });

    for (NSString *p in paths) {
        if (TPURLHas(url, p)) return YES;
    }
    return NO;
}

static BOOL TPMarkUnlocked(id node) {
    BOOL changed = NO;
    @try {
        if ([node isKindOfClass:[NSMutableDictionary class]]) {
            NSMutableDictionary *d = node;
            if (d[@"unlocked"] != nil) { d[@"unlocked"] = @YES; changed = YES; }
            if (d[@"is_vip"] != nil) { d[@"is_vip"] = @1; changed = YES; }
            if (d[@"is_lifetime_vip"] != nil) { d[@"is_lifetime_vip"] = @1; changed = YES; }
            if (d[@"is_lifetime"] != nil) { d[@"is_lifetime"] = @1; changed = YES; }
            if (d[@"unlocked_all"] != nil) { d[@"unlocked_all"] = @YES; changed = YES; }
            for (NSString *k in [d.allKeys copy]) {
                changed |= TPMarkUnlocked(d[k]);
            }
        } else if ([node isKindOfClass:[NSMutableArray class]]) {
            for (id item in [NSArray arrayWithArray:(NSArray *)node]) {
                changed |= TPMarkUnlocked(item);
            }
        }
    } @catch (__unused NSException *e) {}
    return changed;
}

static NSData *TPFakePayloadForURL(NSURL *url) {
    if (TPURLHas(url, @"/vip/checkVipStatus") || TPURLHas(url, @"/user/getUserInfo")) {
        return TPJSONData(@{
            @"code": @0, @"msg": @"ok", @"encrypted": @NO,
            @"data": @{
                @"is_vip": @1,
                @"is_lifetime_vip": @1,
                @"is_lifetime": @1,
                @"vip_days_left": [NSNull null],
                @"vip_end_time": [NSNull null],
            },
        });
    }
    if (TPURLHas(url, @"/vip/activateWithIAP")) {
        return TPJSONData(@{
            @"code": @0, @"msg": @"ok", @"encrypted": @NO,
            @"data": @{ @"activated": @YES, @"is_vip": @1, @"is_lifetime_vip": @1 },
        });
    }
    if (TPURLHas(url, @"/effect/myUnlocks") || TPURLHas(url, @"/wallpaper/getMyUnlocks")) {
        return TPJSONData(@{
            @"code": @0, @"msg": @"ok", @"encrypted": @NO,
            @"data": @{ @"list": @[], @"unlocked_all": @YES },
        });
    }
    if (TPURLHas(url, @"/wallpaper/iapProducts") || TPURLHas(url, @"/vip/getPlanList")) {
        return TPJSONData(@{ @"code": @0, @"msg": @"ok", @"encrypted": @NO, @"data": @[] });
    }
    return nil;
}

static NSData *TPPatchResponseData(NSURL *url, NSData *data) {
    if (!TPShouldPatchURL(url)) return data;

    @try {
        id parsed = TPJSONParse(data);

        if (![parsed isKindOfClass:[NSDictionary class]]) {
            NSData *fake = TPFakePayloadForURL(url);
            if (fake) {
                NSLog(@"%@ replace-nonjson url=%@", kLogTag, url.absoluteString);
                return fake;
            }
            return data;
        }

        NSMutableDictionary *root = [parsed mutableCopy];

        if ([root[@"encrypted"] boolValue]) {
            NSData *fake = TPFakePayloadForURL(url);
            if (fake) {
                NSLog(@"%@ decrypt-bypass url=%@", kLogTag, url.absoluteString);
                return fake;
            }
        }

        if (TPMarkUnlocked(root)) {
            root[@"encrypted"] = @NO;
            NSData *out = TPJSONData(root);
            if (out) {
                NSLog(@"%@ patch-json url=%@", kLogTag, url.absoluteString);
                return out;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"%@ patch exception url=%@ err=%@", kLogTag, url.absoluteString, e);
    }

    return data;
}

#pragma mark - UserDefaults seed (no swizzle)

static void TPSeedLocalUnlockCaches(void) {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:@[@"*"] forKey:@"dashboard_unlocked_dial_ids"];
        [ud setObject:@[@"*"] forKey:@"dashboard_acceleration_effect_unlocked_ids"];
    } @catch (__unused NSException *e) {}
}

#pragma mark - NSURLSession hook (NSURLSession only, once)

typedef void (^TPCompletion)(NSData *, NSURLResponse *, NSError *);

static IMP TPOrig_dataTaskRequest = NULL;
static IMP TPOrig_dataTaskURL = NULL;

static void TPInvokeCompletion(TPCompletion completion, NSURL *url, NSData *data, NSURLResponse *resp, NSError *err) {
    if (!completion) return;
    @try {
        NSData *patched = TPPatchResponseData(url, data);
        completion(patched, resp, err);
    } @catch (__unused NSException *e) {
        completion(data, resp, err);
    }
}

static NSURLSessionDataTask *TPHook_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request, TPCompletion completion) {
    NSURLSessionDataTask * (*orig)(id, SEL, NSURLRequest *, TPCompletion) =
        (NSURLSessionDataTask * (*)(id, SEL, NSURLRequest *, TPCompletion))TPOrig_dataTaskRequest;

    if (!completion || !TPFakeVIPEnabled()) {
        return orig(self, _cmd, request, completion);
    }

    NSURL *url = request.URL;
    TPCompletion wrap = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        TPInvokeCompletion(completion, url, data, resp, err);
    };
    return orig(self, _cmd, request, wrap);
}

static NSURLSessionDataTask *TPHook_dataTaskWithURL(id self, SEL _cmd, NSURL *url, TPCompletion completion) {
    NSURLSessionDataTask * (*orig)(id, SEL, NSURL *, TPCompletion) =
        (NSURLSessionDataTask * (*)(id, SEL, NSURL *, TPCompletion))TPOrig_dataTaskURL;

    if (!completion || !TPFakeVIPEnabled()) {
        return orig(self, _cmd, url, completion);
    }

    TPCompletion wrap = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        TPInvokeCompletion(completion, url, data, resp, err);
    };
    return orig(self, _cmd, url, wrap);
}

static void TPInstallNSURLSessionHooks(void) {
    Class cls = [NSURLSession class];
    if (!cls) return;

    SEL s1 = @selector(dataTaskWithRequest:completionHandler:);
    Method m1 = class_getInstanceMethod(cls, s1);
    if (m1 && !TPOrig_dataTaskRequest) {
        TPOrig_dataTaskRequest = method_getImplementation(m1);
        method_setImplementation(m1, (IMP)TPHook_dataTaskWithRequest);
    }

    SEL s2 = @selector(dataTaskWithURL:completionHandler:);
    Method m2 = class_getInstanceMethod(cls, s2);
    if (m2 && !TPOrig_dataTaskURL) {
        TPOrig_dataTaskURL = method_getImplementation(m2);
        method_setImplementation(m2, (IMP)TPHook_dataTaskWithURL);
    }
}

#pragma mark - Init

__attribute__((constructor)) static void TPFakeVIPInit(void) {
    @try {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:kBundleID]) return;

        TPSeedLocalUnlockCaches();
        TPInstallNSURLSessionHooks();

        NSLog(@"%@ v3 loaded enabled=%d (safe mode)", kLogTag, TPFakeVIPEnabled());
    } @catch (NSException *e) {
        NSLog(@"%@ init failed: %@", kLogTag, e);
    }
}
