// TPlayerFakeVIP v4 — login-aware merge patch + real dial ID cache re-seed.
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

#pragma mark - Known unlock IDs

static NSArray<NSString *> *TPKnownDialIDs(void) {
    static NSArray<NSString *> *ids;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ids = @[
            @"amap", @"apple_map", @"amap_navigation", @"apple_maps_navigation",
            @"amap_dial", @"apple_map_dial", @"classic", @"emitter", @"navigation",
            @"tita", @"tita_pro", @"tita_ultra", @"pie", @"hud", @"dashboard",
            @"model3", @"modely", @"cybertruck", @"retro", @"minimal", @"neon",
        ];
    });
    return ids;
}

static NSArray<NSString *> *TPKnownEffectIDs(void) {
    static NSArray<NSString *> *ids;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ids = @[ @"effect_1", @"effect_2", @"effect_3", @"effect_4", @"acceleration" ];
    });
    return ids;
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

static BOOL TPURLHasAny(NSURL *url, NSArray<NSString *> *needles) {
    for (NSString *n in needles) {
        if (TPURLHas(url, n)) return YES;
    }
    return NO;
}

static BOOL TPIsAuthURL(NSURL *url) {
    return TPURLHasAny(url, @[
        @"/auth/phone/login",
        @"/auth/phone/password_login",
        @"/auth/wechat/app_login",
        @"/auth/apple/login",
        @"/auth/email/login",
        @"/auth/email/register",
        @"/user/accountMergeCommit",
    ]);
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
            @"/auth/phone/login",
            @"/auth/phone/password_login",
            @"/auth/wechat/app_login",
            @"/auth/apple/login",
            @"/auth/email/login",
            @"/auth/email/register",
            @"/user/accountMergeCommit",
        ];
    });

    for (NSString *p in paths) {
        if (TPURLHas(url, p)) return YES;
    }
    return NO;
}

#pragma mark - Entitlement merge

static void TPMergeVIPFields(NSMutableDictionary *d) {
    if (!d) return;
    d[@"is_vip"] = @1;
    d[@"_is_vip"] = @1;
    d[@"is_lifetime_vip"] = @1;
    d[@"is_lifetime"] = @1;
    d[@"_is_lifetime"] = @1;
    d[@"is_ad_free"] = @1;
    d[@"_is_ad_free"] = @1;
    d[@"vip_days_left"] = [NSNull null];
    d[@"_days_left"] = [NSNull null];
    d[@"vip_end_time"] = [NSNull null];
    d[@"_vip_end_time"] = [NSNull null];
    d[@"_subscription_provider"] = @"internal_test";
}

static void TPMergeUnlockLists(NSMutableDictionary *d) {
    if (!d) return;
    NSArray *dials = TPKnownDialIDs();
    NSArray *effects = TPKnownEffectIDs();
    d[@"dial_unlocks"] = dials;
    d[@"_dial_unlocks"] = dials;
    d[@"effect_unlocks"] = effects;
    d[@"_effect_unlocks"] = effects;
    d[@"wallpaper_unlocks"] = @[];
    d[@"_wallpaper_unlocks"] = @[];
    d[@"mini_player_unlocks"] = @[];
    d[@"_mini_player_unlocks"] = @[];
    d[@"unlocked_all"] = @YES;
}

static void TPMergeEntitlementsIntoDict(NSMutableDictionary *d) {
    if (!d) return;
    TPMergeVIPFields(d);
    TPMergeUnlockLists(d);
}

static NSMutableDictionary *TPMutablePayloadContainer(NSMutableDictionary *root) {
    id data = root[@"data"];
    if ([data isKindOfClass:[NSMutableDictionary class]]) {
        return (NSMutableDictionary *)data;
    }
    if ([data isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *m = [data mutableCopy];
        root[@"data"] = m;
        return m;
    }
    NSMutableDictionary *created = [NSMutableDictionary dictionary];
    root[@"data"] = created;
    return created;
}

static BOOL TPMarkUnlocked(id node) {
    BOOL changed = NO;
    @try {
        if ([node isKindOfClass:[NSMutableDictionary class]]) {
            NSMutableDictionary *d = node;
            if (d[@"unlocked"] != nil) { d[@"unlocked"] = @YES; changed = YES; }
            if (d[@"is_vip"] != nil) { d[@"is_vip"] = @1; changed = YES; }
            if (d[@"_is_vip"] != nil) { d[@"_is_vip"] = @1; changed = YES; }
            if (d[@"is_lifetime_vip"] != nil) { d[@"is_lifetime_vip"] = @1; changed = YES; }
            if (d[@"is_lifetime"] != nil) { d[@"is_lifetime"] = @1; changed = YES; }
            if (d[@"_is_lifetime"] != nil) { d[@"_is_lifetime"] = @1; changed = YES; }
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

static NSDictionary *TPEntitlementDataDict(void) {
    static NSDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        TPMergeEntitlementsIntoDict(m);
        m[@"nickname"] = @"VIP";
        m[@"avatar_url"] = @"";
        d = [m copy];
    });
    return d;
}

static NSData *TPFakePayloadForURL(NSURL *url) {
    if (TPURLHas(url, @"/vip/checkVipStatus")) {
        return TPJSONData(@{
            @"code": @0, @"msg": @"ok", @"encrypted": @NO,
            @"data": TPEntitlementDataDict(),
        });
    }
    if (TPURLHas(url, @"/user/getUserInfo")) {
        return TPJSONData(@{
            @"code": @0, @"msg": @"ok", @"encrypted": @NO,
            @"data": TPEntitlementDataDict(),
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

#pragma mark - UserDefaults seed

static void TPSeedLocalUnlockCaches(void) {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:TPKnownDialIDs() forKey:@"dashboard_unlocked_dial_ids"];
        [ud setObject:TPKnownEffectIDs() forKey:@"dashboard_acceleration_effect_unlocked_ids"];
    } @catch (__unused NSException *e) {}
}

static void TPScheduleReseedBurst(void) {
    TPSeedLocalUnlockCaches();
    for (int i = 1; i <= 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (TPFakeVIPEnabled()) TPSeedLocalUnlockCaches();
        });
    }
}

static void TPStartPeriodicReseed(void) {
    TPScheduleReseedBurst();
    for (int round = 1; round <= 12; round++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(round * 10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (TPFakeVIPEnabled()) TPSeedLocalUnlockCaches();
        });
    }
}

#pragma mark - Response patch

static NSData *TPPatchResponseData(NSURL *url, NSData *data) {
    if (!TPShouldPatchURL(url)) return data;

    @try {
        if (TPIsAuthURL(url)) {
            TPScheduleReseedBurst();
        }

        id parsed = TPJSONParse(data);

        if (![parsed isKindOfClass:[NSDictionary class]]) {
            if (TPIsAuthURL(url)) {
                NSLog(@"%@ auth-nonjson pass-through url=%@", kLogTag, url.absoluteString);
                return data;
            }
            NSData *fake = TPFakePayloadForURL(url);
            if (fake) {
                NSLog(@"%@ replace-nonjson url=%@", kLogTag, url.absoluteString);
                TPScheduleReseedBurst();
                return fake;
            }
            return data;
        }

        NSMutableDictionary *root = [parsed mutableCopy];
        BOOL encrypted = [root[@"encrypted"] boolValue];

        if (TPIsAuthURL(url)) {
            if (encrypted) {
                NSLog(@"%@ auth-encrypted pass-through + reseed url=%@", kLogTag, url.absoluteString);
                return data;
            }
            TPMergeEntitlementsIntoDict(root);
            TPMergeEntitlementsIntoDict(TPMutablePayloadContainer(root));
            root[@"encrypted"] = @NO;
            NSData *out = TPJSONData(root);
            if (out) {
                NSLog(@"%@ auth-merge url=%@", kLogTag, url.absoluteString);
                TPScheduleReseedBurst();
                return out;
            }
            return data;
        }

        if (encrypted) {
            NSData *fake = TPFakePayloadForURL(url);
            if (fake) {
                NSLog(@"%@ decrypt-bypass url=%@", kLogTag, url.absoluteString);
                TPScheduleReseedBurst();
                return fake;
            }
            return data;
        }

        BOOL changed = NO;
        if (TPURLHas(url, @"/user/getUserInfo") || TPURLHas(url, @"/vip/checkVipStatus")) {
            TPMergeEntitlementsIntoDict(TPMutablePayloadContainer(root));
            changed = YES;
        }

        changed |= TPMarkUnlocked(root);

        if (changed) {
            root[@"encrypted"] = @NO;
            NSData *out = TPJSONData(root);
            if (out) {
                NSLog(@"%@ patch-json url=%@", kLogTag, url.absoluteString);
                TPScheduleReseedBurst();
                return out;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"%@ patch exception url=%@ err=%@", kLogTag, url.absoluteString, e);
    }

    return data;
}

#pragma mark - NSURLSession hook

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
        TPStartPeriodicReseed();
        TPInstallNSURLSessionHooks();

        NSLog(@"%@ v4 loaded enabled=%d (login merge + dial ids)", kLogTag, TPFakeVIPEnabled());
    } @catch (NSException *e) {
        NSLog(@"%@ init failed: %@", kLogTag, e);
    }
}
