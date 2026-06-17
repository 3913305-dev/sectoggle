#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

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
            if (TPMarkUnlocked(d[k])) changed = YES;
        }
    } else if ([node isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [node mutableCopy];
        BOOL c = TPMarkUnlocked(d);
        if (c) [(NSMutableDictionary *)node setDictionary:d]; // no-op for immutable
        changed = c;
    } else if ([node isKindOfClass:[NSMutableArray class]]) {
        for (id item in (NSArray *)node) changed |= TPMarkUnlocked(item);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) changed |= TPMarkUnlocked(item);
    }
    return changed;
}

static NSData *TPFakeResponseForURL(NSURL *url, NSData *original) {
    if (TPURLHas(url, @"/vip/checkVipStatus")) {
        return TPJSONData(@{
            @"code": @0, @"msg": @"ok", @"encrypted": @NO,
            @"data": @{ @"is_vip": @1, @"is_lifetime_vip": @1,
                        @"vip_days_left": [NSNull null], @"vip_end_time": [NSNull null] },
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

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!completionHandler || !TPFakeVIPEnabled()) {
        return %orig;
    }
    void (^wrap)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        completionHandler(TPPatch(request.URL, data), resp, err);
    };
    return %orig(request, wrap);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!completionHandler || !TPFakeVIPEnabled()) {
        return %orig;
    }
    void (^wrap)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        completionHandler(TPPatch(url, data), resp, err);
    };
    return %orig(url, wrap);
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:kBundleID]) return;
    TPSeedLocalUnlockCaches();
    NSLog(@"[TPlayerFakeVIP] injected into %@", kBundleID);
}
