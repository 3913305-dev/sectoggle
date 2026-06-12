/**
 * SecToggle.dylib — 悬浮开关「远程自动到达」
 * 注入目标：XiangPostDriver (com.copote.yygk.app.driver)
 * 授权安全测试用途
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <objc/message.h>

void SecUpdateStatusLabel(void);
static void SecInstallDealTaskHooks(void);
static void SecInstallStayedHooks(void);
static void SecInstallTapOpeInHooks(void);
static void SecShowSimResult(NSString *msg);
static void SecPanelLog(NSString *format, ...);
static void SecSimulateAutoArriveImpl(void);
static NSString *SecStationTitle(NSDictionary *t);
static NSString *SecShortURL(NSString *url);
static SEL SecDealTaskSel(void);

@interface SecToggleHandler : NSObject
+ (instancetype)shared;
- (void)onToggle:(UISwitch *)sender;
- (void)onNext:(id)sender;
- (void)onSimAutoArrive:(id)sender;
- (void)onPan:(UIPanGestureRecognizer *)g;
@end

#pragma mark - 状态

static BOOL g_enabled = NO;
static NSMutableArray *g_stations = nil;
static NSInteger g_stationIndex = 0;
static UIView *g_panel = nil;
static UILabel *g_statusLabel = nil;
static UILabel *g_logLabel = nil;
static NSMutableArray<NSString *> *g_logLines = nil;
static const NSUInteger kSecMaxLogLines = 10;
static NSString *g_lastDealType = nil;
static NSString *g_lastDealClass = nil;
static id g_dealTaskTarget = nil;
static id g_cachedAutoDealType = nil;
static NSString *g_taskBcdh = nil;
static NSString *g_taskBcmxdh = nil;
static BOOL g_simulatingAuto = NO;
static BOOL g_inAutoStayedChain = NO;
static BOOL g_forceAutoCzlx = NO;
static NSTimeInterval g_lastSimTime = 0;

static BOOL SecIsManualDealType(id dealType) {
    if (!dealType || dealType == (id)kCFNull) return NO;
    NSString *dt = [dealType description];
    static NSSet *manualTypes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manualTypes = [NSSet setWithObjects:@"0", @"1", @"8100", @"8101", nil];
    });
    return [manualTypes containsObject:dt];
}

static id SecAutoDealType(void) {
    if (g_cachedAutoDealType && !SecIsManualDealType(g_cachedAutoDealType)) {
        return g_cachedAutoDealType;
    }
    return @8102;
}

static void SecClearSimFlags(void) {
    g_simulatingAuto = NO;
    g_inAutoStayedChain = NO;
    g_forceAutoCzlx = NO;
}

static void SecScheduleClearSimFlags(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        SecClearSimFlags();
    });
}
static NSHashTable *g_stayedTargets = nil;
static NSHashTable *g_siteTargets = nil;

#pragma mark - 工具

static double ParseDouble(id v) {
    if (!v || v == (id)kCFNull) return NAN;
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    return [[v description] doubleValue];
}

static void ExtractStationsFromObject(id obj, NSInteger depth) {
    if (!obj || depth > 14) return;
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) ExtractStationsFromObject(item, depth + 1);
        return;
    }
    if (![obj isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *dict = (NSDictionary *)obj;

    id bcdhRaw = dict[@"n_bcdh"] ?: dict[@"bcdh"];
    id bcmxdhRaw = dict[@"n_bcmxdh"] ?: dict[@"bcmxdh"];
    if (bcdhRaw && bcdhRaw != (id)kCFNull) {
        NSString *v = [bcdhRaw description];
        if (v.length && ![v isEqualToString:@"(null)"]) g_taskBcdh = v;
    }
    if (bcmxdhRaw && bcmxdhRaw != (id)kCFNull) {
        NSString *v = [bcmxdhRaw description];
        if (v.length && ![v isEqualToString:@"(null)"]) g_taskBcmxdh = v;
    }

    id jd = dict[@"n_zdjd"] ?: dict[@"n_jd"];
    id wd = dict[@"n_zdwd"] ?: dict[@"n_wd"];
    double lon = ParseDouble(jd);
    double lat = ParseDouble(wd);
    NSString *zddm = [dict[@"c_zddm"] ?: dict[@"zddm"] ?: @"" description];
    if ([zddm isEqualToString:@"(null)"] || [zddm isEqualToString:@"<null>"]) zddm = @"";
    id nameRaw = dict[@"c_zdmc"] ?: dict[@"c_zdjmc"] ?: dict[@"c_zdwz"] ?: dict[@"name"];
    NSString *name = [nameRaw description];
    if ([name isEqualToString:@"(null)"] || [name isEqualToString:@"<null>"]) name = @"";

    if (zddm.length && !isnan(lon) && !isnan(lat) && (lon != 0 || lat != 0)) {
        NSInteger queue = (NSInteger)ParseDouble(dict[@"n_queue"]);
        NSString *key = [NSString stringWithFormat:@"%@@%f,%f", zddm, lon, lat];
        BOOL exists = NO;
        for (NSMutableDictionary *s in g_stations) {
            if ([s[@"key"] isEqualToString:key] || [s[@"zddm"] isEqualToString:zddm]) {
                exists = YES;
                if (name.length) s[@"name"] = name;
                if (queue > 0) s[@"queue"] = @(queue);
                s[@"jd"] = @(lon);
                s[@"wd"] = @(lat);
                break;
            }
        }
        if (!exists) {
            NSMutableDictionary *entry = [@{@"key":key, @"zddm":zddm, @"name":name,
                                            @"jd":@(lon), @"wd":@(lat), @"queue":@(queue)} mutableCopy];
            [g_stations addObject:entry];
            if (g_stations.count <= 12) {
                SecPanelLog(@"解析站点 %@", SecStationTitle(entry));
            }
            [g_stations sortUsingComparator:^NSComparisonResult(id a, id b) {
                NSInteger qa = [a[@"queue"] integerValue];
                NSInteger qb = [b[@"queue"] integerValue];
                if (qa > 0 && qb > 0) {
                    if (qa < qb) return NSOrderedAscending;
                    if (qa > qb) return NSOrderedDescending;
                }
                return NSOrderedSame;
            }];
            dispatch_async(dispatch_get_main_queue(), ^{
                SecUpdateStatusLabel();
            });
        }
    }
    for (id k in dict) ExtractStationsFromObject(dict[k], depth + 1);
}

static NSDictionary *DisplayStation(void) {
    if (g_stations.count == 0) return nil;
    return g_stations[g_stationIndex % g_stations.count];
}

static NSString *SecStationTitle(NSDictionary *t) {
    if (!t) return @"未知站点";
    NSString *name = [t[@"name"] description];
    NSString *zddm = [t[@"zddm"] description];
    BOOL hasName = name.length && ![name isEqualToString:@"(null)"];
    BOOL hasZddm = zddm.length && ![zddm isEqualToString:@"(null)"];
    if (hasName && hasZddm) return [NSString stringWithFormat:@"%@ · %@", name, zddm];
    if (hasName) return name;
    if (hasZddm) return zddm;
    return @"未命名站点";
}

static NSDictionary *SpoofTarget(void) {
    if (g_stations.count == 0) return nil;
    if (g_enabled || g_simulatingAuto) {
        return g_stations[g_stationIndex % g_stations.count];
    }
    return nil;
}

static NSDictionary *CurrentTarget(void) {
    return SpoofTarget();
}

static NSString *SecPatchCoordField(NSString *raw, NSString *key, double value) {
    NSString *pat = [NSString stringWithFormat:@"\"%@\"\\s*:\\s*\"?[0-9.eE+-]+\"?", key];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    NSString *rep = [NSString stringWithFormat:@"\"%@\":%f", key, value];
    return [re stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:rep];
}

static NSString *SecPatchStringField(NSString *raw, NSString *key, NSString *value) {
    if (!value.length) return raw;
    NSString *pat = [NSString stringWithFormat:@"\"%@\"\\s*:\\s*\"[^\"]*\"", key];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    NSString *rep = [NSString stringWithFormat:@"\"%@\":\"%@\"", key, value];
    return [re stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:rep];
}

static NSString *PatchJsonForRequest(NSString *raw, NSString *url) {
    NSDictionary *t = CurrentTarget();
    if (!t) return raw;

    double jd = [t[@"jd"] doubleValue];
    double wd = [t[@"wd"] doubleValue];
    NSString *zddm = [t[@"zddm"] description];
    NSString *out = raw;

    BOOL isArrive = [url containsString:@"rwcz"] &&
        ([url containsString:@"zddd"] || [url containsString:@"zdqd"] ||
         [url containsString:@"zdlk"] || [url containsString:@"/qd"]);

    if (isArrive) {
        NSArray *allKeys = @[@"n_jd", @"n_wd", @"n_zdjd", @"n_zdwd",
                             @"gpslongitude", @"gpslatitude", @"longitude", @"latitude", @"lng", @"lat"];
        for (NSString *key in allKeys) {
            BOOL isLat = [key isEqualToString:@"n_wd"] || [key isEqualToString:@"n_zdwd"] ||
                         [key isEqualToString:@"lat"] || [key isEqualToString:@"latitude"] ||
                         [key isEqualToString:@"gpslatitude"];
            out = SecPatchCoordField(out, key, isLat ? wd : jd);
        }
        out = SecPatchStringField(out, @"c_zddm", zddm);
        out = SecPatchStringField(out, @"zddm", zddm);
        SecPanelLog(@"到达改包 %@", SecStationTitle(t));
    } else {
        NSArray *gpsKeys = @[@"n_jd", @"n_wd", @"gpslongitude", @"gpslatitude",
                             @"longitude", @"latitude", @"lng", @"lat"];
        for (NSString *key in gpsKeys) {
            BOOL isLat = [key isEqualToString:@"n_wd"] || [key isEqualToString:@"lat"] ||
                         [key isEqualToString:@"latitude"] || [key isEqualToString:@"gpslatitude"];
            out = SecPatchCoordField(out, key, isLat ? wd : jd);
        }
    }

    if (g_simulatingAuto || g_forceAutoCzlx) {
        NSString *autoCzlx = [SecAutoDealType() description];
        for (NSString *key in @[@"n_czlx", @"c_czlx", @"czlx"]) {
            NSString *pat = [NSString stringWithFormat:@"\"%@\"\\s*:\\s*\"?[0-9]+\"?", key];
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
            NSString *rep = [NSString stringWithFormat:@"\"%@\":%@", key, autoCzlx];
            out = [re stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:rep];
        }
    }
    return out;
}

static NSString *PatchJson(NSString *raw) {
    return PatchJsonForRequest(raw, @"");
}

static void RefreshTarget(void) {
    SecUpdateStatusLabel();
}

static void SecPanelLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[SecToggle] %@", msg);

    if (!g_logLines) g_logLines = [NSMutableArray array];
    static NSDateFormatter *df;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
    });
    NSString *line = [NSString stringWithFormat:@"%@ %@", [df stringFromDate:[NSDate date]], msg];
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_logLines addObject:line];
        while (g_logLines.count > kSecMaxLogLines) {
            [g_logLines removeObjectAtIndex:0];
        }
        if (g_logLabel) {
            g_logLabel.text = [g_logLines componentsJoinedByString:@"\n"];
        }
    });
}

static NSString *SecShortURL(NSString *url) {
    if (!url.length) return @"";
    NSRange r = [url rangeOfString:@"/app/sjb/v1"];
    if (r.location != NSNotFound) return [url substringFromIndex:r.location];
    if (url.length > 42) return [[url substringToIndex:39] stringByAppendingString:@"..."];
    return url;
}

static void NextStation(void) {
    if (g_stations.count == 0) return;
    g_stationIndex = (g_stationIndex + 1) % g_stations.count;
    RefreshTarget();
    NSDictionary *t = DisplayStation();
    if (t) SecPanelLog(@"切换 → %@", SecStationTitle(t));
}

#pragma mark - 方案 B：模拟自动到达

static BOOL SecIsXPDObject(id obj) {
    if (!obj) return NO;
    return [NSStringFromClass([obj class]) hasPrefix:@"XPD"];
}

static BOOL SecClassMatches(id obj) {
    if (!obj) return NO;
    if (SecIsXPDObject(obj)) return YES;
    NSString *cn = NSStringFromClass([obj class]);
    return [cn hasPrefix:@"AMap"] || [cn containsString:@"GeoFence"];
}

static SEL SecDealTaskSel(void) {
    return @selector(dealTaskWithBCDH:bcmxdh:zddm:lat:lon:fjsj:dealType:completion:);
}

static id SecSingletonFromClass(Class cls) {
    if (!cls) return nil;
    NSArray *classSels = @[@"shareInstance", @"sharedInstance", @"defaultService", @"sharedService"];
    for (NSString *name in classSels) {
        SEL sel = NSSelectorFromString(name);
        if ([cls respondsToSelector:sel]) {
            id inst = ((id (*)(id, SEL))objc_msgSend)(cls, sel);
            if (inst) {
                SecPanelLog(@"%s ← +%@", class_getName(cls), name);
                return inst;
            }
        }
    }
    return nil;
}

static NSUInteger SecArgCountForSelector(SEL sel) {
    if (!sel) return 0;
    return strchr(sel_getName(sel), ':') != NULL;
}

static id SecKVCTry(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}

static NSString *SecStringFromKV(id obj, NSArray *keys) {
    for (NSString *k in keys) {
        id v = SecKVCTry(obj, k);
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
        if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    }
    return nil;
}

static void SecForEachWindow(void (^block)(UIWindow *win)) {
    if (!block) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                if (win && !win.hidden) block(win);
            }
        }
    }
    for (UIWindow *win in app.windows) {
        if (win && !win.hidden) block(win);
    }
}

static NSInteger SecInvokeSelectorWithArg(id obj, SEL sel, id arg) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return 0;
    @try {
        NSUInteger argc = SecArgCountForSelector(sel);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if (argc == 0) {
            ((void (*)(id, SEL))objc_msgSend)(obj, sel);
        } else {
            ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, arg ?: nil);
        }
#pragma clang diagnostic pop
        SecPanelLog(@"已触发 %@", NSStringFromSelector(sel));
        if (g_siteTargets && SecClassMatches(obj)) {
            [g_siteTargets addObject:obj];
        }
        return 1;
    } @catch (NSException *e) {
        SecPanelLog(@"触发 %@ 失败: %@", NSStringFromSelector(sel), e);
        return 0;
    }
}

static NSInteger SecInvokeSelector(id obj, SEL sel) {
    return SecInvokeSelectorWithArg(obj, sel, nil);
}

static NSInteger SecTapOpeInOnObject(id obj) {
    if (!obj) return 0;
    if ([obj respondsToSelector:@selector(tapOpeIn:)] && g_siteTargets) {
        [g_siteTargets addObject:obj];
    }

    NSArray *imgKeys = @[@"opeInImg", @"_opeInImg", @"siteOpenImg", @"_siteOpenImg", @"openImg", @"_openImg"];
    for (NSString *key in imgKeys) {
        id v = SecKVCTry(obj, key);
        if ([v isKindOfClass:[UIControl class]]) {
            [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
            SecPanelLog(@"点击 %@ ← %@", key, [obj class]);
            return 1;
        }
    }
    if ([obj respondsToSelector:@selector(tapOpeIn:)]) {
        return SecInvokeSelectorWithArg(obj, @selector(tapOpeIn:),
                                      SecKVCTry(obj, @"opeInImg") ?: SecKVCTry(obj, @"_opeInImg"));
    }
    return 0;
}

static void SecWalkCollect(id node, void (^visit)(id), NSMutableSet *seen) {
    if (!node || !visit) return;
    NSValue *key = [NSValue valueWithNonretainedObject:node];
    if ([seen containsObject:key]) return;
    [seen addObject:key];

    visit(node);
    if ([node isKindOfClass:[UIView class]]) {
        for (UIView *sub in [(UIView *)node subviews]) {
            SecWalkCollect(sub, visit, seen);
        }
    }
}

static void SecWalkViewControllerTree(id node, void (^visit)(id), NSMutableSet *seen) {
    if (!node) return;

    if ([node isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)node;
        SecWalkCollect(vc, visit, seen);
        SecWalkCollect(vc.view, visit, seen);

        if ([vc isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                SecWalkViewControllerTree(c, visit, seen);
            }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            for (UIViewController *c in [(UITabBarController *)vc viewControllers]) {
                SecWalkViewControllerTree(c, visit, seen);
            }
        }
        for (UIViewController *c in vc.childViewControllers) {
            SecWalkViewControllerTree(c, visit, seen);
        }
        SecWalkViewControllerTree(vc.presentedViewController, visit, seen);
        return;
    }

    SecWalkCollect(node, visit, seen);
}

static void SecWalkWindows(void (^visit)(id)) {
    if (!visit) return;
    NSMutableSet *seen = [NSMutableSet set];
    SecForEachWindow(^(UIWindow *win) {
        SecWalkCollect(win, visit, seen);
        SecWalkViewControllerTree(win.rootViewController, visit, seen);
    });
}

static id SecResolveDealTaskTarget(void) {
    if (g_dealTaskTarget) return g_dealTaskTarget;

    SEL dealSel = SecDealTaskSel();
    Class svcCls = NSClassFromString(@"XPDService");
    id singleton = SecSingletonFromClass(svcCls);
    if (singleton && [singleton respondsToSelector:dealSel]) {
        g_dealTaskTarget = singleton;
        SecPanelLog(@"dealTask ← XPDService 单例");
        return singleton;
    }

    __block id found = nil;
    SecWalkWindows(^(id node) {
        if (found) return;
        if ([node respondsToSelector:dealSel]) {
            found = node;
            return;
        }
        for (NSString *key in @[@"service", @"_service", @"xpdService", @"_xpdService"]) {
            id svc = SecKVCTry(node, key);
            if (svc && [svc respondsToSelector:dealSel]) {
                found = svc;
                return;
            }
        }
    });
    if (found) {
        g_dealTaskTarget = found;
        SecPanelLog(@"dealTask ← %@", [found class]);
    }
    return found;
}

static void SecCollectTaskIdsFromUI(void) {
    SecWalkWindows(^(id node) {
        if (!g_taskBcdh.length) {
            g_taskBcdh = SecStringFromKV(node, @[@"n_bcdh", @"bcdh", @"_n_bcdh", @"_bcdh", @"c_bcdh"]);
        }
        if (!g_taskBcmxdh.length) {
            g_taskBcmxdh = SecStringFromKV(node, @[@"n_bcmxdh", @"bcmxdh", @"_n_bcmxdh", @"c_bcmxdh"]);
        }
        if (SecIsXPDObject(node)) {
            for (NSString *key in @[@"service", @"_service"]) {
                id svc = SecKVCTry(node, key);
                if (svc && !g_dealTaskTarget) g_dealTaskTarget = svc;
            }
        }
    });
}

static BOOL SecZddmMatches(id obj, NSString *wantZddm) {
    if (!wantZddm.length) return YES;
    NSString *z = SecStringFromKV(obj, @[@"c_zddm", @"zddm", @"_c_zddm", @"n_zddm"]);
    if (!z.length) return YES;
    return [z isEqualToString:wantZddm];
}

static id SecFindAutoStayedTarget(void) {
    NSString *wantZddm = [[DisplayStation()[@"zddm"] description] copy];
    SEL stayedSel = @selector(handleWhenStayedTimerFired:);

    for (id obj in g_stayedTargets) {
        if ([obj respondsToSelector:stayedSel] && SecZddmMatches(obj, wantZddm)) {
            return obj;
        }
    }

    __block id matched = nil;
    __block id any = nil;
    SecWalkWindows(^(id node) {
        if (![node respondsToSelector:stayedSel]) return;
        if (!any) any = node;
        if (!matched && SecZddmMatches(node, wantZddm)) matched = node;
    });
    if (matched) return matched;
    if (any) return any;

    Class mgrCls = NSClassFromString(@"AMapGeoFenceManager");
    SEL sharedSel = @selector(sharedGeoFence);
    if (mgrCls && [mgrCls respondsToSelector:sharedSel]) {
        id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, sharedSel);
        id delegate = nil;
        if (mgr && [mgr respondsToSelector:@selector(delegate)]) {
            delegate = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(delegate));
        }
        if (delegate && [delegate respondsToSelector:stayedSel]) {
            return delegate;
        }
    }
    return nil;
}

static NSInteger SecTriggerAutoStayedOnce(void) {
    id target = SecFindAutoStayedTarget();
    if (!target) return 0;

    g_inAutoStayedChain = YES;
    NSInteger n = SecInvokeSelectorWithArg(target, @selector(handleWhenStayedTimerFired:), nil);
    g_inAutoStayedChain = NO;

    if (n > 0) {
        if (g_stayedTargets) [g_stayedTargets addObject:target];
        SecPanelLog(@"自动到达(Stayed×1) ← %@", [target class]);
    }
    return n > 0 ? 1 : 0;
}

static void (*orig_stayedFired)(id, SEL, id);
static void (*orig_tapOpeIn)(id, SEL, id);

static void hook_stayedFired(id self, SEL _cmd, id timer) {
    if (g_stayedTargets) [g_stayedTargets addObject:self];
    if (g_siteTargets && SecClassMatches(self)) [g_siteTargets addObject:self];
    orig_stayedFired(self, _cmd, timer);
}

static void hook_tapOpeIn(id self, SEL _cmd, id sender) {
    if (g_siteTargets && SecClassMatches(self)) [g_siteTargets addObject:self];
    orig_tapOpeIn(self, _cmd, sender);
}

static void SecInstallTapOpeInHooks(void) {
    static BOOL installed = NO;
    if (installed) return;

    SEL sel = @selector(tapOpeIn:);
    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return;
    Class *classes = (Class *)malloc((size_t)num * sizeof(Class));
    if (!classes) return;
    objc_getClassList(classes, num);

    for (int i = 0; i < num; i++) {
        Method m = class_getInstanceMethod(classes[i], sel);
        if (!m) continue;
        orig_tapOpeIn = (void (*)(id, SEL, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_tapOpeIn);
        SecPanelLog(@"Hook tapOpeIn ← %@", NSStringFromClass(classes[i]));
        installed = YES;
        break;
    }
    free(classes);
}

static void SecInstallStayedHooks(void) {
    static BOOL installed = NO;
    if (installed) return;

    SEL sel = @selector(handleWhenStayedTimerFired:);
    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return;
    Class *classes = (Class *)malloc((size_t)num * sizeof(Class));
    if (!classes) return;
    objc_getClassList(classes, num);

    for (int i = 0; i < num; i++) {
        Method m = class_getInstanceMethod(classes[i], sel);
        if (!m) continue;
        orig_stayedFired = (void (*)(id, SEL, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_stayedFired);
        SecPanelLog(@"Hook handleWhenStayedTimerFired ← %@", NSStringFromClass(classes[i]));
        installed = YES;
        break;
    }
    free(classes);
}

static NSInteger SecTriggerAMapGeoFenceStayed(void) {
    id target = SecFindAutoStayedTarget();
    if (!target) return 0;
    g_inAutoStayedChain = YES;
    NSInteger n = SecInvokeSelectorWithArg(target, @selector(handleWhenStayedTimerFired:), nil);
    g_inAutoStayedChain = NO;
    if (n > 0) SecPanelLog(@"Stayed ← %@", [target class]);
    return n > 0 ? 1 : 0;
}

static NSInteger SecDirectDealTask(void) {
    id target = SecResolveDealTaskTarget();
    if (!target) return 0;

    NSDictionary *t = DisplayStation();
    if (!t) return 0;

    SecCollectTaskIdsFromUI();

    NSString *bcdh = g_taskBcdh;
    NSString *bcmxdh = g_taskBcmxdh;
    NSString *zddm = [t[@"zddm"] description];
    NSNumber *lat = @([t[@"wd"] doubleValue]);
    NSNumber *lon = @([t[@"jd"] doubleValue]);
    NSNumber *fjsj = @((NSInteger)([[NSDate date] timeIntervalSince1970] * 1000));
    id dealType = SecAutoDealType();

    void (^completion)(id, NSError *) = ^(id resp, NSError *err) {
        if (err) {
            SecPanelLog(@"dealTask 失败 %@", err.localizedDescription);
        } else {
            SecPanelLog(@"dealTask 已请求");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *tip = err ? [NSString stringWithFormat:@"dealTask 失败: %@", err.localizedDescription] :
                @"dealTask 已请求";
            SecShowSimResult(tip);
        });
    };

    SEL fullSel = SecDealTaskSel();
    SEL shortSel = @selector(bcmxdh:zddm:lat:lon:fjsj:dealType:completion:);

    if (!bcdh.length || !bcmxdh.length) {
        SecPanelLog(@"警告: bcdh=%@ bcmxdh=%@ (任务单号缺失可能导致 dealTask 无效)",
              bcdh, bcmxdh);
    }

    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([target respondsToSelector:fullSel]) {
            ((void (*)(id, SEL, id, id, id, id, id, id, id, id))objc_msgSend)(
                target, fullSel,
                bcdh ?: @"", bcmxdh ?: @"", zddm ?: @"", lat, lon, fjsj, dealType, completion);
            SecPanelLog(@"直接 dealTask bcdh=%@ bcmxdh=%@ zddm=%@ dealType=%@",
                  bcdh, bcmxdh, zddm, dealType);
            return 1;
        }
        if ([target respondsToSelector:shortSel]) {
            ((void (*)(id, SEL, id, id, id, id, id, id, id))objc_msgSend)(
                target, shortSel,
                bcmxdh ?: @"", zddm ?: @"", lat, lon, fjsj, dealType, completion);
            SecPanelLog(@"直接 bcmxdh dealTask bcmxdh=%@ zddm=%@ dealType=%@",
                  bcmxdh, zddm, dealType);
            return 1;
        }
#pragma clang diagnostic pop
    } @catch (NSException *e) {
        SecPanelLog(@"直接 dealTask 异常: %@", e);
    }
    return 0;
}

static void SecShowSimResult(NSString *msg) {
    if (msg.length) SecPanelLog(@"%@", msg);
    if (!g_statusLabel) return;
    NSDictionary *t = DisplayStation();
    NSString *title = SecStationTitle(t);
    g_statusLabel.text = [NSString stringWithFormat:@"[%@] %ld/%lu\n%@\n%@",
                          g_enabled ? @"ON" : @"OFF",
                          (long)(g_stationIndex + 1), (unsigned long)g_stations.count,
                          title, msg];
}

static void SecSimulateAutoArriveImpl(void) {
    SecInstallDealTaskHooks();
    SecInstallStayedHooks();
    SecCollectTaskIdsFromUI();

    id dealTarget = SecResolveDealTaskTarget();
    g_simulatingAuto = YES;
    g_forceAutoCzlx = YES;

    NSInteger n = SecDirectDealTask();
    if (n == 0) {
        n = SecTriggerAutoStayedOnce();
    }
    if (n == 0) {
        n = SecTriggerAMapGeoFenceStayed();
    }

    if (n == 0) {
        SecClearSimFlags();
        NSString *why = @"自动链路未触发";
        if (!dealTarget) why = @"未找到 dealTask 对象";
        else if (!g_taskBcmxdh.length) why = @"缺少 bcmxdh，请刷新任务页";
        SecShowSimResult([NSString stringWithFormat:@"%@，可开关ON等围栏", why]);
    } else {
        SecScheduleClearSimFlags();
        if (g_lastDealType.length) {
            SecShowSimResult([NSString stringWithFormat:@"已触发自动 czlx=%@", g_lastDealType]);
        } else {
            SecShowSimResult([NSString stringWithFormat:@"已触发自动 czlx=%@", SecAutoDealType()]);
        }
    }
}

static void SecSimulateAutoArrive(void) {
    if (!g_stations.count) {
        SecShowSimResult(@"请先打开任务详情");
        return;
    }
    if (!g_enabled) {
        SecShowSimResult(@"请先打开开关");
        return;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - g_lastSimTime < 2.0) {
        SecShowSimResult(@"请勿连续点击(2秒内)");
        return;
    }
    g_lastSimTime = now;

    NSDictionary *t = DisplayStation();
    SecPanelLog(@"模拟 → %@", SecStationTitle(t));
    SecShowSimResult(@"模拟中…");

    dispatch_async(dispatch_get_main_queue(), ^{
        SecSimulateAutoArriveImpl();
    });
}

#pragma mark - dealTask 日志

static void (*orig_dealTask)(id, SEL, id, id, id, id, id, id, id, id);

static void hook_dealTask(id self, SEL _cmd, id bcdh, id bcmxdh, id zddm,
                          id lat, id lon, id fjsj, id dealType, id completion) {
    g_dealTaskTarget = self;

    id useZddm = zddm;
    id useLat = lat;
    id useLon = lon;
    if (g_enabled || g_simulatingAuto || g_forceAutoCzlx) {
        NSDictionary *t = CurrentTarget();
        if (t) {
            useZddm = t[@"zddm"] ?: zddm;
            useLat = t[@"wd"] ?: lat;
            useLon = t[@"jd"] ?: lon;
            SecPanelLog(@"统一站点 → %@ zddm=%@ wd=%@ jd=%@",
                  SecStationTitle(t), useZddm, useLat, useLon);
        }
    }

    id useType = dealType;
    if (g_simulatingAuto || g_inAutoStayedChain || g_forceAutoCzlx) {
        if (SecIsManualDealType(dealType)) {
            useType = SecAutoDealType();
            SecPanelLog(@"强制自动 dealType %@ → %@", dealType, useType);
        }
    }

    g_lastDealType = [useType description];
    g_lastDealClass = NSStringFromClass([self class]);
    if (!SecIsManualDealType(useType)) {
        g_cachedAutoDealType = useType;
    }

    SecPanelLog(@"dealTask %@ zddm=%@ type=%@", g_lastDealClass, useZddm, useType);
    orig_dealTask(self, _cmd, bcdh, bcmxdh, useZddm, useLat, useLon, fjsj, useType, completion);
}

static void SecInstallDealTaskHooks(void) {
    static BOOL installed = NO;
    if (installed) return;

    SEL sel = SecDealTaskSel();
    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return;

    Class *classes = (Class *)malloc((size_t)num * sizeof(Class));
    if (!classes) return;
    objc_getClassList(classes, num);

    Class hookCls = NSClassFromString(@"XPDService");
    if (!hookCls || !class_getInstanceMethod(hookCls, sel)) {
        hookCls = Nil;
        for (int i = 0; i < num; i++) {
            if (!class_getInstanceMethod(classes[i], sel)) continue;
            if (strstr(class_getName(classes[i]), "XPD")) {
                hookCls = classes[i];
                break;
            }
        }
        if (!hookCls) {
            for (int i = 0; i < num; i++) {
                if (class_getInstanceMethod(classes[i], sel)) {
                    hookCls = classes[i];
                    break;
                }
            }
        }
    }

    if (hookCls) {
        Method m = class_getInstanceMethod(hookCls, sel);
        orig_dealTask = (void (*)(id, SEL, id, id, id, id, id, id, id, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_dealTask);
        SecPanelLog(@"Hook dealTask ← %@", NSStringFromClass(hookCls));
        installed = YES;
    }
    free(classes);
}

#pragma mark - UI

void SecUpdateStatusLabel(void) {
    if (!g_statusLabel) return;
    NSDictionary *t = DisplayStation();
    if (!t) {
        g_statusLabel.text = @"站点: 请先打开任务详情";
        return;
    }
    NSString *title = SecStationTitle(t);
    g_statusLabel.text = [NSString stringWithFormat:@"[%@] %ld/%lu\n%@",
                          g_enabled ? @"ON" : @"OFF",
                          (long)(g_stationIndex + 1), (unsigned long)g_stations.count,
                          title];
}

static void SecCreatePanel(void) {
    if (g_panel) return;
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.hidden && w.alpha > 0) { win = w; break; }
    }
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SecCreatePanel();
        });
        return;
    }

    CGFloat pw = 280, ph = 232;
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(20, 120, pw, ph)];
    g_panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    g_panel.layer.cornerRadius = 10;
    g_panel.userInteractionEnabled = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, 200, 20)];
    title.text = @"SEC 远程自动到达";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:13];
    [g_panel addSubview:title];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 60, 2, 51, 31)];
    [sw addTarget:[SecToggleHandler shared] action:@selector(onToggle:) forControlEvents:UIControlEventValueChanged];
    [g_panel addSubview:sw];

    g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 28, pw - 16, 34)];
    g_statusLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    g_statusLabel.font = [UIFont systemFontOfSize:11];
    g_statusLabel.numberOfLines = 2;
    g_statusLabel.text = @"站点: 请先打开任务详情";
    [g_panel addSubview:g_statusLabel];

    UIButton *btnNext = [UIButton buttonWithType:UIButtonTypeSystem];
    btnNext.frame = CGRectMake(8, 62, 120, 32);
    [btnNext setTitle:@"下一站" forState:UIControlStateNormal];
    [btnNext setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btnNext.backgroundColor = [UIColor colorWithRed:0.2 green:0.45 blue:0.85 alpha:1];
    btnNext.layer.cornerRadius = 6;
    [btnNext addTarget:[SecToggleHandler shared] action:@selector(onNext:) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:btnNext];

    UIButton *btnAuto = [UIButton buttonWithType:UIButtonTypeSystem];
    btnAuto.frame = CGRectMake(136, 62, 136, 32);
    [btnAuto setTitle:@"模拟自动到达" forState:UIControlStateNormal];
    [btnAuto setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btnAuto.backgroundColor = [UIColor colorWithRed:0.72 green:0.38 blue:0.05 alpha:1];
    btnAuto.layer.cornerRadius = 6;
    [btnAuto addTarget:[SecToggleHandler shared] action:@selector(onSimAutoArrive:) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:btnAuto];

    UIView *logBg = [[UIView alloc] initWithFrame:CGRectMake(6, 98, pw - 12, ph - 104)];
    logBg.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
    logBg.layer.cornerRadius = 6;
    [g_panel addSubview:logBg];

    UILabel *logTitle = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, pw - 28, 14)];
    logTitle.text = @"日志";
    logTitle.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    logTitle.font = [UIFont systemFontOfSize:9];
    [logBg addSubview:logTitle];

    g_logLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 18, pw - 24, ph - 122)];
    g_logLabel.textColor = [UIColor colorWithRed:0.55 green:0.85 blue:1.0 alpha:1];
    g_logLabel.font = [UIFont systemFontOfSize:9];
    g_logLabel.numberOfLines = kSecMaxLogLines;
    g_logLabel.text = @"—";
    [logBg addSubview:g_logLabel];

    if (!g_logLines) g_logLines = [NSMutableArray array];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[SecToggleHandler shared] action:@selector(onPan:)];
    [g_panel addGestureRecognizer:pan];

    [win addSubview:g_panel];
    [win bringSubviewToFront:g_panel];
    SecPanelLog(@"悬浮窗已显示（含模拟自动到达）");
}

@implementation SecToggleHandler {
    CGPoint _panStart;
}

+ (instancetype)shared {
    static SecToggleHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [SecToggleHandler new]; });
    return h;
}

- (void)onToggle:(UISwitch *)sender {
    g_enabled = sender.isOn;
    SecPanelLog(@"开关 %@", g_enabled ? @"ON" : @"OFF");
    SecUpdateStatusLabel();
    if (g_enabled && g_stations.count) {
        NSDictionary *t = DisplayStation();
        if (t) {
            SecPanelLog(@"GPS→%@", SecStationTitle(t));
        }
    }
}

- (void)onNext:(id)sender {
    NextStation();
}

- (void)onSimAutoArrive:(id)sender {
    SecSimulateAutoArrive();
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        _panStart = g_panel.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:g_panel.superview];
        g_panel.center = CGPointMake(_panStart.x + t.x, _panStart.y + t.y);
    }
}

@end

#pragma mark - Hooks

static CLLocationCoordinate2D (*orig_coord)(id, SEL);
static double (*orig_latitude)(id, SEL);
static double (*orig_longitude)(id, SEL);

static CLLocationCoordinate2D hook_coord(id self, SEL _cmd) {
    NSDictionary *t = SpoofTarget();
    if (t) {
        CLLocationCoordinate2D c;
        c.latitude = [t[@"wd"] doubleValue];
        c.longitude = [t[@"jd"] doubleValue];
        return c;
    }
    return orig_coord(self, _cmd);
}

static double hook_latitude(id self, SEL _cmd) {
    NSDictionary *t = SpoofTarget();
    if (t) return [t[@"wd"] doubleValue];
    return orig_latitude(self, _cmd);
}

static double hook_longitude(id self, SEL _cmd) {
    NSDictionary *t = SpoofTarget();
    if (t) return [t[@"jd"] doubleValue];
    return orig_longitude(self, _cmd);
}

static void (*orig_setBody)(id, SEL, NSData *);

static void hook_setBody(id self, SEL _cmd, NSData *body) {
    if (body.length > 0 && body.length < 65536 && (g_enabled || g_simulatingAuto || g_forceAutoCzlx)) {
        NSString *raw = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (raw) {
            NSMutableURLRequest *req = (NSMutableURLRequest *)self;
            NSString *url = req.URL.absoluteString;
            if ([url containsString:@"/app/sjb/v1"] &&
                ([url containsString:@"rwcz"] || [url containsString:@"car/"])) {
                NSString *patched = PatchJsonForRequest(raw, url);
                if (![patched isEqualToString:raw]) {
                    body = [patched dataUsingEncoding:NSUTF8StringEncoding];
                    SecPanelLog(@"改包 %@", SecShortURL(url));
                }
            }
        }
    }
    orig_setBody(self, _cmd, body);
}

static id (*orig_jsonData)(id, SEL, NSData *, NSJSONReadingOptions, NSError **);

static id hook_jsonData(id self, SEL _cmd, NSData *data, NSJSONReadingOptions opt, NSError **err) {
    id obj = orig_jsonData(self, _cmd, data, opt, err);
    if (obj) {
        @try { ExtractStationsFromObject(obj, 0); } @catch (NSException *e) {}
    }
    return obj;
}

static void SecInstallHooks(void) {
    if (!g_stations) g_stations = [NSMutableArray array];
    if (!g_stayedTargets) g_stayedTargets = [NSHashTable weakObjectsHashTable];
    if (!g_siteTargets) g_siteTargets = [NSHashTable weakObjectsHashTable];

    Method m1 = class_getInstanceMethod([CLLocation class], @selector(coordinate));
    if (m1) {
        orig_coord = (CLLocationCoordinate2D (*)(id, SEL))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)(void *)hook_coord);
    }

    Method mLat = class_getInstanceMethod([CLLocation class], @selector(latitude));
    if (mLat) {
        orig_latitude = (double (*)(id, SEL))method_getImplementation(mLat);
        method_setImplementation(mLat, (IMP)hook_latitude);
    }

    Method mLon = class_getInstanceMethod([CLLocation class], @selector(longitude));
    if (mLon) {
        orig_longitude = (double (*)(id, SEL))method_getImplementation(mLon);
        method_setImplementation(mLon, (IMP)hook_longitude);
    }

    Method m2 = class_getInstanceMethod([NSMutableURLRequest class], @selector(setHTTPBody:));
    if (m2) {
        orig_setBody = (void (*)(id, SEL, NSData *))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)hook_setBody);
    }

    Method m3 = class_getClassMethod([NSJSONSerialization class], @selector(JSONObjectWithData:options:error:));
    if (m3) {
        orig_jsonData = (id (*)(id, SEL, NSData *, NSJSONReadingOptions, NSError **))method_getImplementation(m3);
        method_setImplementation(m3, (IMP)hook_jsonData);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        SecInstallDealTaskHooks();
        SecInstallStayedHooks();
        SecInstallTapOpeInHooks();
    });

    SecPanelLog(@"Hooks 安装完成");
}

#pragma mark - 入口

__attribute__((constructor))
static void SecToggleEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SecInstallHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SecCreatePanel();
        });
    });
}
