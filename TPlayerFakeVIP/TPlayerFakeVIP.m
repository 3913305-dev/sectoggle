// TPlayer internal VIP test dylib — inject with TrollFools / ElleKit.
// Bundle: com.twanjia.teslaplayer

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const kBundleID = @"com.twanjia.teslaplayer";
static NSString *const kEnabledKey = @"tp_fake_vip.enabled";

static BOOL TPFakeVIPEnabled(void) {
    if ([[NSUserDefaults standardUserDefaults] objectForKey:kEnabledKey] == nil) return YES;
    return [[NSUserDefaults standardUserDefaults] boolForKey:kEnabledKey];
}

static void TPSeedLocalUnlockCaches(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:@[@"*"] forKey:@"dashboard_unlocked_dial_ids"];
    [ud setObject:@[@"*"] forKey:@"dashboard_acceleration_effect_unlocked_ids"];
    [ud synchronize];
}

static NSData *TPJSONData(id obj) {
    return [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
}

static id TPJSONParse(NSData *data) {
    if (!data.length) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
}

static BOOL TPURLHas(NSURL *url, NSString *needle) {
    return [url.absoluteString rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL TPShouldPatchURL(NSURL *url) {
    if (!TPFakeVIPEnabled() || !url) return NO;
    NSArray *paths = @[
        @"/vip/checkVipStatus", @"/vip/getPlanList", @"/vip/getOrderList",
        @"/vip/activateWithIAP", @"/effect/myUnlocks", @"/wallpaper/getMyUnlocks",
        @"/wallpaper/iapProducts", @"/coin/rechargeProducts",
    ];
    for (NSString *p in paths) {
        if (TPURLHas(url, p)) return YES;
    }
    return NO;
}

static BOOL TPMarkUnlocked(id node) {
    BOOL changed = NO;
    if ([node isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *d = node;
        if (d[@"unlocked"]) { d[@"unlocked"] = @YES; changed = YES; }
        if (d[@"is_vip"]) { d[@"is_vip"] = @1; changed = YES; }
        if (d[@"is_lifetime_vip"]) { d[@"is_lifetime_vip"] = @1; changed = YES; }
        for (NSString *k in d.allKeys) {
            changed |= TPMarkUnlocked(d[k]);
        }
    } else if ([node isKindOfClass:[NSMutableArray class]]) {
        for (id item in (NSArray *)node) changed |= TPMarkUnlocked(item);
    }
    return changed;
}

static NSData *TPFakeResponseForURL(NSURL *url, NSData *original) {
    if (TPURLHas(url, @"/vip/checkVipStatus")) {
        return TPJSONData(@{
            @"code": @0, @"msg": @"ok", @"encrypted": @NO,
            @"data": @{
                @"is_vip": @1,
                @"is_lifetime_vip": @1,
                @"vip_days_left": [NSNull null],
                @"vip_end_time": [NSNull null],
            },
        }) ?: original;
    }
    if (TPURLHas(url, @"/vip/activateWithIAP")) {
        return TPJSONData(@{
            @"code": @0, @"msg": @"ok", @"encrypted": @NO,
            @"data": @{ @"activated": @YES, @"is_vip": @1, @"is_lifetime_vip": @1 },
        }) ?: original;
    }
    if (TPURLHas(url, @"/effect/myUnlocks") || TPURLHas(url, @"/wallpaper/getMyUnlocks")) {
        return TPJSONData(@{
            @"code": @0, @"msg": @"ok", @"encrypted": @NO,
            @"data": @{ @"list": @[], @"unlocked_all": @YES },
        }) ?: original;
    }

    id parsed = TPJSONParse(original);
    if (![parsed isKindOfClass:[NSMutableDictionary class]]) return original;
    NSMutableDictionary *root = (NSMutableDictionary *)parsed;
    if (TPMarkUnlocked(root)) {
        root[@"encrypted"] = @NO;
        return TPJSONData(root) ?: original;
    }
    return original;
}

static NSData *TPPatch(NSURL *url, NSData *data) {
    if (!TPShouldPatchURL(url)) return data;
    return TPFakeResponseForURL(url, data);
}

typedef void (^TPCompletion)(NSData *, NSURLResponse *, NSError *);

static NSURLSessionDataTask *TPHookRequest(
    id self, SEL _cmd, NSURLRequest *request, TPCompletion completion,
    NSURLSessionDataTask * (*orig)(id, SEL, NSURLRequest *, TPCompletion)
) {
    if (!completion || !TPFakeVIPEnabled()) return orig(self, _cmd, request, completion);
    TPCompletion wrap = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        completion(TPPatch(request.URL, data), resp, err);
    };
    return orig(self, _cmd, request, wrap);
}

static NSURLSessionDataTask *TPHookURL(
    id self, SEL _cmd, NSURL *url, TPCompletion completion,
    NSURLSessionDataTask * (*orig)(id, SEL, NSURL *, TPCompletion)
) {
    if (!completion || !TPFakeVIPEnabled()) return orig(self, _cmd, url, completion);
    TPCompletion wrap = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        completion(TPPatch(url, data), resp, err);
    };
    return orig(self, _cmd, url, wrap);
}

static void TPInstallHooks(void) {
    Class cls = objc_getClass("NSURLSession");
    if (!cls) return;

    SEL s1 = @selector(dataTaskWithRequest:completionHandler:);
    Method m1 = class_getInstanceMethod(cls, s1);
    if (m1) {
        IMP o1 = method_getImplementation(m1);
        IMP n1 = imp_implementationWithBlock(^NSURLSessionDataTask *(id self, NSURLRequest *req, TPCompletion comp) {
            return TPHookRequest(self, s1, req, comp, (NSURLSessionDataTask * (*)(id, SEL, NSURLRequest *, TPCompletion))o1);
        });
        method_setImplementation(m1, n1);
    }

    SEL s2 = @selector(dataTaskWithURL:completionHandler:);
    Method m2 = class_getInstanceMethod(cls, s2);
    if (m2) {
        IMP o2 = method_getImplementation(m2);
        IMP n2 = imp_implementationWithBlock(^NSURLSessionDataTask *(id self, NSURL *url, TPCompletion comp) {
            return TPHookURL(self, s2, url, comp, (NSURLSessionDataTask * (*)(id, SEL, NSURL *, TPCompletion))o2);
        });
        method_setImplementation(m2, n2);
    }
}

__attribute__((constructor)) static void TPFakeVIPInit(void) {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:kBundleID]) return;
    TPSeedLocalUnlockCaches();
    TPInstallHooks();
    NSLog(@"[TPlayerFakeVIP] loaded (enabled=%d)", TPFakeVIPEnabled());
}
