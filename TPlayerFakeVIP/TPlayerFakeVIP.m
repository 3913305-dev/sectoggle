// TPlayerFakeVIP v2 — broader hooks for encrypted API + Swift JSONDecoder paths.
// Inject via TrollFools into com.twanjia.teslaplayer

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static NSString *const kBundleID = @"com.twanjia.teslaplayer";
static NSString *const kEnabledKey = @"tp_fake_vip.enabled";
static NSString *const kLogTag = @"[TPlayerFakeVIP]";

static BOOL TPFakeVIPEnabled(void) {
    if ([[NSUserDefaults standardUserDefaults] objectForKey:kEnabledKey] == nil) return YES;
    return [[NSUserDefaults standardUserDefaults] boolForKey:kEnabledKey];
}

#pragma mark - JSON patch core

static BOOL TPMarkUnlocked(id node) {
    BOOL changed = NO;
    if ([node isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *d = node;
        if (d[@"unlocked"] != nil) { d[@"unlocked"] = @YES; changed = YES; }
        if (d[@"is_vip"] != nil) { d[@"is_vip"] = @1; changed = YES; }
        if (d[@"is_lifetime_vip"] != nil) { d[@"is_lifetime_vip"] = @1; changed = YES; }
        if (d[@"is_lifetime"] != nil) { d[@"is_lifetime"] = @1; changed = YES; }
        if (d[@"is_ad_free"] != nil) { d[@"is_ad_free"] = @1; changed = YES; }
        if (d[@"member_free_used"] != nil) { d[@"member_free_used"] = @0; changed = YES; }
        if (d[@"activated"] != nil) { d[@"activated"] = @YES; changed = YES; }
        if (d[@"unlocked_all"] != nil) { d[@"unlocked_all"] = @YES; changed = YES; }
        for (NSString *k in d.allKeys) changed |= TPMarkUnlocked(d[k]);
    } else if ([node isKindOfClass:[NSMutableArray class]]) {
        for (id item in (NSArray *)node) changed |= TPMarkUnlocked(item);
    }
    return changed;
}

static id TPPatchJSONObject(id obj) {
    if (!TPFakeVIPEnabled() || !obj) return obj;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *root = [obj mutableCopy];
        BOOL changed = TPMarkUnlocked(root);
        if (changed) {
            root[@"encrypted"] = @NO;
            return root;
        }
    }
    return obj;
}

static NSData *TPJSONData(id obj) {
    if (!obj) return nil;
    return [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
}

static id TPJSONParse(NSData *data) {
    if (!data.length) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
}

static BOOL TPIsTeslaAPIURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *abs = url.absoluteString.lowercaseString ?: @"";
    return [host containsString:@"teslaapi.twanjia.com"] || [abs containsString:@"teslaapi.twanjia.com"];
}

static BOOL TPURLHas(NSURL *url, NSString *needle) {
    return [url.absoluteString rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSData *TPFakeVIPPayloadForURL(NSURL *url) {
    if (TPURLHas(url, @"/vip/checkVipStatus") || TPURLHas(url, @"/user/getUserInfo")) {
        return TPJSONData(@{
            @"code": @0, @"msg": @"ok", @"encrypted": @NO,
            @"data": @{
                @"is_vip": @1, @"is_lifetime_vip": @1,
                @"is_lifetime": @1, @"is_ad_free": @1,
                @"vip_days_left": [NSNull null], @"vip_end_time": [NSNull null],
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
            @"data": @{ @"list": @[], @"unlocked_all": @YES, @"unlocked": @YES },
        });
    }
    if (TPURLHas(url, @"/wallpaper/getList") || TPURLHas(url, @"/wallpaper/iapProducts")) {
        return TPJSONData(@{ @"code": @0, @"msg": @"ok", @"encrypted": @NO, @"data": @[] });
    }
    return TPJSONData(@{
        @"code": @0, @"msg": @"ok", @"encrypted": @NO,
        @"data": @{ @"is_vip": @1, @"unlocked": @YES, @"unlocked_all": @YES },
    });
}

static NSData *TPPatchResponseData(NSURL *url, NSData *data) {
    if (!TPFakeVIPEnabled() || !TPIsTeslaAPIURL(url)) return data;

    id parsed = TPJSONParse(data);
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        NSData *fake = TPFakeVIPPayloadForURL(url);
        if (fake) {
            NSLog(@"%@ net-fake url=%@", kLogTag, url.absoluteString);
            return fake;
        }
        return data;
    }

    NSMutableDictionary *root = [parsed mutableCopy];

    // Encrypted payloads never reach JSONDecoder with is_vip — replace entirely.
    if ([root[@"encrypted"] boolValue]) {
        NSData *fake = TPFakeVIPPayloadForURL(url);
        if (fake) {
            NSLog(@"%@ decrypt-bypass encrypted url=%@", kLogTag, url.absoluteString);
            return fake;
        }
    }

    if (TPMarkUnlocked(root)) {
        root[@"encrypted"] = @NO;
        NSLog(@"%@ patch-json url=%@", kLogTag, url.absoluteString);
        return TPJSONData(root) ?: data;
    }

    return data;
}

#pragma mark - UserDefaults seed / hook

static NSArray<NSString *> *TPUnlockKeys(void) {
    return @[
        @"dashboard_unlocked_dial_ids",
        @"dashboard_acceleration_effect_unlocked_ids",
        @"dashboard_wallpaper_unlocked_ids",
        @"dashboard_unlocked_wallpaper_ids",
    ];
}

static void TPSeedLocalUnlockCaches(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (NSString *key in TPUnlockKeys()) {
        [ud setObject:@[@"*"] forKey:key];
    }
    [ud setBool:YES forKey:@"tp_fake_vip.seeded"];
    [ud synchronize];
    NSLog(@"%@ seeded local unlock caches", kLogTag);
}

static BOOL TPKeyLooksVIP(NSString *key) {
    NSString *low = key.lowercaseString;
    return [low containsString:@"vip"] || [low containsString:@"is_vip"] || [low containsString:@"lifetime"];
}

static id (*TPOrig_UD_ObjectForKey)(id, SEL, NSString *);
static BOOL (*TPOrig_UD_BoolForKey)(id, SEL, NSString *);

static id TPHook_UD_ObjectForKey(id self, SEL _cmd, NSString *key) {
    if (TPFakeVIPEnabled() && key.length) {
        if ([TPUnlockKeys() containsObject:key]) return @[@"*"];
        if (TPKeyLooksVIP(key)) return @YES;
    }
    return TPOrig_UD_ObjectForKey(self, _cmd, key);
}

static BOOL TPHook_UD_BoolForKey(id self, SEL _cmd, NSString *key) {
    if (TPFakeVIPEnabled() && key.length && TPKeyLooksVIP(key)) return YES;
    return TPOrig_UD_BoolForKey(self, _cmd, key);
}

#pragma mark - NSJSONSerialization hook (ObjC decode path)

static id (*TPOrig_JSONObjectWithData)(Class, SEL, NSData *, NSJSONReadingOptions, NSError **);

static id TPHook_JSONObjectWithData(Class self, SEL _cmd, NSData *data, NSJSONReadingOptions opt, NSError **err) {
    id obj = TPOrig_JSONObjectWithData(self, _cmd, data, opt, err);
    id patched = TPPatchJSONObject(obj);
    if (patched != obj) NSLog(@"%@ JSONSerialization patched", kLogTag);
    return patched;
}

#pragma mark - NSURLSession hooks

typedef void (^TPCompletion)(NSData *, NSURLResponse *, NSError *);

static NSURLSessionDataTask *TPHookDataTaskWithRequest(
    id self, SEL _cmd, NSURLRequest *request, TPCompletion completion,
    NSURLSessionDataTask * (*orig)(id, SEL, NSURLRequest *, TPCompletion)
) {
    if (!completion || !TPFakeVIPEnabled()) return orig(self, _cmd, request, completion);
    TPCompletion wrap = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        completion(TPPatchResponseData(request.URL, data), resp, err);
    };
    return orig(self, _cmd, request, wrap);
}

static NSURLSessionDataTask *TPHookDataTaskWithURL(
    id self, SEL _cmd, NSURL *url, TPCompletion completion,
    NSURLSessionDataTask * (*orig)(id, SEL, NSURL *, TPCompletion)
) {
    if (!completion || !TPFakeVIPEnabled()) return orig(self, _cmd, url, completion);
    TPCompletion wrap = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        completion(TPPatchResponseData(url, data), resp, err);
    };
    return orig(self, _cmd, url, wrap);
}

static void TPInstallSessionHooksOnClass(Class cls) {
    if (!cls) return;

    SEL s1 = @selector(dataTaskWithRequest:completionHandler:);
    Method m1 = class_getInstanceMethod(cls, s1);
    if (m1) {
        IMP o1 = method_getImplementation(m1);
        IMP n1 = imp_implementationWithBlock(^NSURLSessionDataTask *(id self, NSURLRequest *req, TPCompletion comp) {
            return TPHookDataTaskWithRequest(self, s1, req, comp, (NSURLSessionDataTask * (*)(id, SEL, NSURLRequest *, TPCompletion))o1);
        });
        method_setImplementation(m1, n1);
    }

    SEL s2 = @selector(dataTaskWithURL:completionHandler:);
    Method m2 = class_getInstanceMethod(cls, s2);
    if (m2) {
        IMP o2 = method_getImplementation(m2);
        IMP n2 = imp_implementationWithBlock(^NSURLSessionDataTask *(id self, NSURL *url, TPCompletion comp) {
            return TPHookDataTaskWithURL(self, s2, url, comp, (NSURLSessionDataTask * (*)(id, SEL, NSURL *, TPCompletion))o2);
        });
        method_setImplementation(m2, n2);
    }
}

static void TPInstallNSURLSessionHooks(void) {
    TPInstallSessionHooksOnClass(objc_getClass("NSURLSession"));
    TPInstallSessionHooksOnClass(NSClassFromString(@"__NSURLSessionLocal"));
    TPInstallSessionHooksOnClass(NSClassFromString(@"__NSURLSessionProxy"));
}

static void TPInstallUserDefaultsHooks(void) {
    Class cls = [NSUserDefaults class];
    Method om = class_getInstanceMethod(cls, @selector(objectForKey:));
    Method bm = class_getInstanceMethod(cls, @selector(boolForKey:));
    if (om) {
        TPOrig_UD_ObjectForKey = (id (*)(id, SEL, NSString *))method_getImplementation(om);
        method_setImplementation(om, (IMP)TPHook_UD_ObjectForKey);
    }
    if (bm) {
        TPOrig_UD_BoolForKey = (BOOL (*)(id, SEL, NSString *))method_getImplementation(bm);
        method_setImplementation(bm, (IMP)TPHook_UD_BoolForKey);
    }
}

static void TPInstallJSONHooks(void) {
    Method m = class_getClassMethod(objc_getClass("NSJSONSerialization"), @selector(JSONObjectWithData:options:error:));
    if (!m) return;
    TPOrig_JSONObjectWithData = (id (*)(Class, SEL, NSData *, NSJSONReadingOptions, NSError **))method_getImplementation(m);
    method_setImplementation(m, (IMP)TPHook_JSONObjectWithData);
}

#pragma mark - JSONDecoder.decode(_:from:) Swift hook

static id (*TPOrig_JSONDecoder_decode)(id, SEL, Class, NSData *);

static id TPHook_JSONDecoder_decode(id self, SEL _cmd, Class type, NSData *data) {
    @try {
        id result = TPOrig_JSONDecoder_decode(self, _cmd, type, data);
        if (result && TPFakeVIPEnabled()) {
            if ([result isKindOfClass:[NSDictionary class]]) {
                id patched = TPPatchJSONObject(result);
                if (patched != result) {
                    NSLog(@"%@ JSONDecoder patched dict", kLogTag);
                    return patched;
                }
            } else if ([result respondsToSelector:@selector(setValue:forKey:)]) {
                @try { [result setValue:@YES forKey:@"isVip"]; } @catch (__unused NSException *e) {}
                @try { [result setValue:@YES forKey:@"is_vip"]; } @catch (__unused NSException *e) {}
                @try { [result setValue:@YES forKey:@"isLifetimeVip"]; } @catch (__unused NSException *e) {}
                @try { [result setValue:@YES forKey:@"is_lifetime_vip"]; } @catch (__unused NSException *e) {}
                @try { [result setValue:@YES forKey:@"unlocked"]; } @catch (__unused NSException *e) {}
            }
        }
        return result;
    } @catch (id exception) {
        return TPOrig_JSONDecoder_decode(self, _cmd, type, data);
    }
}

static void TPInstallJSONDecoderHook(void) {
    const char *candidates[] = {
        "_TtC10Foundation11JSONDecoder",
        "Foundation.JSONDecoder",
        NULL,
    };
    Class jsonDecoder = Nil;
    for (int i = 0; candidates[i]; i++) {
        jsonDecoder = objc_getClass(candidates[i]);
        if (jsonDecoder) break;
    }
    if (!jsonDecoder) {
        NSLog(@"%@ JSONDecoder class not found", kLogTag);
        return;
    }

    SEL sel = NSSelectorFromString(@"decode:from:");
    Method m = class_getInstanceMethod(jsonDecoder, sel);
    if (!m) {
        NSLog(@"%@ JSONDecoder decode:from: not found", kLogTag);
        return;
    }
    TPOrig_JSONDecoder_decode = (id (*)(id, SEL, Class, NSData *))method_getImplementation(m);
    method_setImplementation(m, (IMP)TPHook_JSONDecoder_decode);
    NSLog(@"%@ JSONDecoder hook installed on %s", kLogTag, class_getName(jsonDecoder));
}

#pragma mark - Lifecycle

static void TPOnAppActive(void) {
    if (!TPFakeVIPEnabled()) return;
    TPSeedLocalUnlockCaches();
}

static void TPInstallLifecycleHooks(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:nil
                                                      usingBlock:^(__unused NSNotification *n) {
            TPOnAppActive();
        }];
    });
}

__attribute__((constructor)) static void TPFakeVIPInit(void) {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:kBundleID]) return;

    TPSeedLocalUnlockCaches();
    TPInstallUserDefaultsHooks();
    TPInstallJSONHooks();
    TPInstallNSURLSessionHooks();
    TPInstallJSONDecoderHook();
    TPInstallLifecycleHooks();

    NSLog(@"%@ v2 loaded enabled=%d", kLogTag, TPFakeVIPEnabled());
}
