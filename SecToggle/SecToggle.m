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
static NSString *g_lastDealType = nil;
static NSString *g_lastDealClass = nil;
static id g_dealTaskTarget = nil;
static id g_cachedAutoDealType = nil;
static NSString *g_taskBcdh = nil;
static NSString *g_taskBcmxdh = nil;
static BOOL g_simulatingAuto = NO;
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
    id nameRaw = dict[@"c_zdmc"] ?: dict[@"c_zdjmc"] ?: dict[@"c_zdwz"] ?: dict[@"name"];
    NSString *name = [nameRaw description];
    if ([name isEqualToString:@"(null)"] || [name isEqualToString:@"<null>"]) name = @"";

    if (!isnan(lon) && !isnan(lat) && (lon != 0 || lat != 0)) {
        NSString *key = [NSString stringWithFormat:@"%@@%f,%f", zddm, lon, lat];
        BOOL exists = NO;
        for (NSMutableDictionary *s in g_stations) {
            if ([s[@"key"] isEqualToString:key]) {
                exists = YES;
                if (name.length && ![s[@"name"] length]) {
                    s[@"name"] = name;
                }
                break;
            }
        }
        if (!exists) {
            [g_stations addObject:[@{@"key":key, @"zddm":zddm, @"name":name,
                                     @"jd":@(lon), @"wd":@(lat)} mutableCopy]];
            NSLog(@"[SecToggle] 站点 %@ %@ wd=%f jd=%f", zddm, name, lat, lon);
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
    if (name.length && ![name isEqualToString:@"(null)"]) return name;
    NSString *zddm = [t[@"zddm"] description];
    if (zddm.length && ![zddm isEqualToString:@"(null)"]) return zddm;
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

static void RefreshTarget(void) {
    SecUpdateStatusLabel();
}

static void NextStation(void) {
    if (g_stations.count == 0) return;
    g_stationIndex = (g_stationIndex + 1) % g_stations.count;
    RefreshTarget();
}

static NSString *PatchJson(NSString *raw) {
    NSDictionary *t = CurrentTarget();
    if (!t) return raw;
    double jd = [t[@"jd"] doubleValue];
    double wd = [t[@"wd"] doubleValue];
    NSArray *keys = @[@"n_jd",@"n_wd",@"n_zdjd",@"n_zdwd",
                      @"gpslongitude",@"gpslatitude",@"longitude",@"latitude",@"lng",@"lat"];
    NSString *out = raw;
    for (NSString *key in keys) {
        NSString *pat = [NSString stringWithFormat:@"\"%@\"\\s*:\\s*\"?[0-9.eE+-]+\"?", key];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
        NSString *rep;
        if ([key isEqualToString:@"n_wd"] || [key isEqualToString:@"n_zdwd"] ||
            [key isEqualToString:@"lat"] || [key isEqualToString:@"latitude"] || [key isEqualToString:@"gpslatitude"]) {
            rep = [NSString stringWithFormat:@"\"%@\":%f", key, wd];
        } else {
            rep = [NSString stringWithFormat:@"\"%@\":%f", key, jd];
        }
        out = [re stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:rep];
    }
    return out;
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

static id SecResolveDealTaskTarget(void) {
    if (g_dealTaskTarget) return g_dealTaskTarget;

    Class cls = NSClassFromString(@"XPDService");
    if (!cls) return nil;

    NSArray *classSels = @[@"sharedInstance", @"shareInstance", @"defaultService", @"sharedService"];
    for (NSString *name in classSels) {
        SEL sel = NSSelectorFromString(name);
        if ([cls respondsToSelector:sel]) {
            id inst = ((id (*)(id, SEL))objc_msgSend)(cls, sel);
            if (inst) {
                NSLog(@"[SecToggle] XPDService ← +%@", name);
                return inst;
            }
        }
    }
    return nil;
}

static NSUInteger SecArgCountForSelector(SEL sel) {
    if (!sel) return 0;
    return (NSUInteger)strchr(sel_getName(sel), ':') != NULL;
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
        NSLog(@"[SecToggle] 已触发 %@ ← %@", NSStringFromSelector(sel), [obj class]);
        if (g_siteTargets && SecClassMatches(obj)) {
            [g_siteTargets addObject:obj];
        }
        return 1;
    } @catch (NSException *e) {
        NSLog(@"[SecToggle] 触发 %@ 失败: %@", NSStringFromSelector(sel), e);
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
            NSLog(@"[SecToggle] 点击 %@ ← %@", key, [obj class]);
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
    SecWalkCollect([node nextResponder], visit, seen);
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

static void SecCollectTaskIdsFromUI(void) {
    SecWalkWindows(^(id node) {
        if (!SecIsXPDObject(node)) return;
        if (!g_taskBcdh.length) {
            g_taskBcdh = SecStringFromKV(node, @[@"n_bcdh", @"bcdh", @"_n_bcdh", @"_bcdh"]);
        }
        if (!g_taskBcmxdh.length) {
            g_taskBcmxdh = SecStringFromKV(node, @[@"n_bcmxdh", @"bcmxdh", @"_n_bcmxdh"]);
        }
    });
}

static NSInteger SecTriggerAllSiteActions(NSInteger *foundTapOpeIn, NSInteger *foundRwczZddd) {
    __block NSInteger count = 0;
    __block NSInteger tapFound = 0;
    __block NSInteger zdddFound = 0;

    SecWalkWindows(^(id node) {
        if ([node respondsToSelector:@selector(rwczZddd)]) {
            zdddFound++;
            count += SecInvokeSelector(node, @selector(rwczZddd));
            if (g_siteTargets) [g_siteTargets addObject:node];
        }
        if ([node respondsToSelector:@selector(tapOpeIn:)]) {
            tapFound++;
            count += SecTapOpeInOnObject(node);
        }
        if ([node respondsToSelector:@selector(handleWhenStayedTimerFired:)]) {
            count += SecInvokeSelectorWithArg(node, @selector(handleWhenStayedTimerFired:), nil);
            if (g_stayedTargets) [g_stayedTargets addObject:node];
        }
        if ([node respondsToSelector:@selector(startStayedTimer)]) {
            count += SecInvokeSelector(node, @selector(startStayedTimer));
        }
        if ([node respondsToSelector:@selector(amapGeoFenceRegionStatusDidChangedToStayed:)]) {
            count += SecInvokeSelectorWithArg(node, @selector(amapGeoFenceRegionStatusDidChangedToStayed:), nil);
        }
    });

    if (foundTapOpeIn) *foundTapOpeIn = tapFound;
    if (foundRwczZddd) *foundRwczZddd = zdddFound;
    return count;
}

static NSInteger SecTriggerCachedTargets(void) {
    NSInteger count = 0;
    for (id obj in g_stayedTargets) {
        count += SecInvokeSelector(obj, @selector(startStayedTimer));
        count += SecInvokeSelectorWithArg(obj, @selector(handleWhenStayedTimerFired:), nil);
        count += SecInvokeSelectorWithArg(obj, @selector(amapGeoFenceRegionStatusDidChangedToStayed:), nil);
    }
    for (id obj in g_siteTargets) {
        count += SecTapOpeInOnObject(obj);
        count += SecInvokeSelectorWithArg(obj, @selector(handleWhenStayedTimerFired:), nil);
    }
    return count;
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
        NSLog(@"[SecToggle] Hook tapOpeIn ← %@", NSStringFromClass(classes[i]));
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
        NSLog(@"[SecToggle] Hook handleWhenStayedTimerFired ← %@", NSStringFromClass(classes[i]));
        installed = YES;
        break;
    }
    free(classes);
}

static void SecTriggerAMapGeoFenceStayed(void) {
    Class mgrCls = NSClassFromString(@"AMapGeoFenceManager");
    if (!mgrCls) return;

    SEL sharedSel = @selector(sharedGeoFence);
    if (![mgrCls respondsToSelector:sharedSel]) return;

    id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, sharedSel);
    if (!mgr) return;

    SecInvokeSelectorWithArg(mgr, @selector(amapGeoFenceRegionStatusDidChangedToStayed:), nil);

    id delegate = nil;
    if ([mgr respondsToSelector:@selector(delegate)]) {
        delegate = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(delegate));
    }
    if (delegate) {
        if (g_stayedTargets) [g_stayedTargets addObject:delegate];
        SecInvokeSelector(delegate, @selector(startStayedTimer));
        SecInvokeSelectorWithArg(delegate, @selector(amapGeoFenceRegionStatusDidChangedToStayed:), nil);
        SecInvokeSelectorWithArg(delegate, @selector(handleWhenStayedTimerFired:), nil);
        SecTapOpeInOnObject(delegate);
    }
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
    id dealType = g_cachedAutoDealType ?: @1;

    void (^completion)(id, NSError *) = ^(id resp, NSError *err) {
        NSLog(@"[SecToggle] dealTask 回调 err=%@ resp=%@", err, resp);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *tip = err ? [NSString stringWithFormat:@"dealTask 失败: %@", err.localizedDescription] :
                @"dealTask 已请求";
            SecShowSimResult(tip);
        });
    };

    SEL fullSel = @selector(dealTaskWithBCDH:bcmxdh:zddm:lat:lon:fjsj:dealType:completion:);
    SEL shortSel = @selector(bcmxdh:zddm:lat:lon:fjsj:dealType:completion:);

    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([target respondsToSelector:fullSel]) {
            ((void (*)(id, SEL, id, id, id, id, id, id, id, id))objc_msgSend)(
                target, fullSel,
                bcdh ?: @"", bcmxdh ?: @"", zddm ?: @"", lat, lon, fjsj, dealType, completion);
            NSLog(@"[SecToggle] 直接 dealTask bcdh=%@ bcmxdh=%@ zddm=%@ dealType=%@",
                  bcdh, bcmxdh, zddm, dealType);
            return 1;
        }
        if ([target respondsToSelector:shortSel]) {
            ((void (*)(id, SEL, id, id, id, id, id, id, id))objc_msgSend)(
                target, shortSel,
                bcmxdh ?: @"", zddm ?: @"", lat, lon, fjsj, dealType, completion);
            NSLog(@"[SecToggle] 直接 bcmxdh dealTask bcmxdh=%@ zddm=%@ dealType=%@",
                  bcmxdh, zddm, dealType);
            return 1;
        }
#pragma clang diagnostic pop
    } @catch (NSException *e) {
        NSLog(@"[SecToggle] 直接 dealTask 异常: %@", e);
    }
    return 0;
}

static void SecShowSimResult(NSString *msg) {
    if (!g_statusLabel) return;
    NSDictionary *t = DisplayStation();
    NSString *title = SecStationTitle(t);
    g_statusLabel.text = [NSString stringWithFormat:@"[%@] %ld/%lu\n%@\n%@",
                          g_enabled ? @"ON" : @"OFF",
                          (long)(g_stationIndex + 1), (unsigned long)g_stations.count,
                          title, msg];
}

static void SecSimulateAutoArrive(void) {
    if (!g_stations.count) {
        SecShowSimResult(@"请先打开任务详情");
        NSLog(@"[SecToggle] 模拟自动到达失败：无站点");
        return;
    }
    if (!g_enabled) {
        SecShowSimResult(@"请先打开开关");
        return;
    }

    NSDictionary *t = DisplayStation();
    NSLog(@"[SecToggle] 模拟自动到达 → %@ wd=%f jd=%f",
          SecStationTitle(t), [t[@"wd"] doubleValue], [t[@"jd"] doubleValue]);

    SecInstallDealTaskHooks();
    SecInstallStayedHooks();
    SecInstallTapOpeInHooks();

    g_simulatingAuto = YES;
    SecCollectTaskIdsFromUI();

    NSInteger tapFound = 0, zdddFound = 0;
    NSInteger n = 0;
    n += SecTriggerCachedTargets();
    n += SecTriggerAllSiteActions(&tapFound, &zdddFound);
    SecTriggerAMapGeoFenceStayed();
    n += SecDirectDealTask();

    g_simulatingAuto = NO;

    if (n == 0) {
        NSString *msg;
        if (tapFound == 0 && zdddFound == 0) {
            msg = @"页内无站点卡片，请下滑到站点行；或开关ON后手动点到达";
        } else {
            msg = [NSString stringWithFormat:@"发现控件但未生效(tap=%ld zddd=%ld)，请手动点到达",
                   (long)tapFound, (long)zdddFound];
        }
        SecShowSimResult(msg);
        NSLog(@"[SecToggle] 模拟失败 tap=%ld zddd=%ld bcdh=%@ bcmxdh=%@",
              (long)tapFound, (long)zdddFound, g_taskBcdh, g_taskBcmxdh);
    } else if (!g_lastDealType.length) {
        SecShowSimResult([NSString stringWithFormat:@"已触发 %ld 次", (long)n]);
        NSLog(@"[SecToggle] 模拟完成，触发 %ld 次", (long)n);
    }
}

#pragma mark - dealTask 日志

static void (*orig_dealTask)(id, SEL, id, id, id, id, id, id, id, id);

static void hook_dealTask(id self, SEL _cmd, id bcdh, id bcmxdh, id zddm,
                          id lat, id lon, id fjsj, id dealType, id completion) {
    g_dealTaskTarget = self;
    g_lastDealType = [dealType description];
    g_lastDealClass = NSStringFromClass([self class]);
    if (g_lastDealType.length && ![g_lastDealType isEqualToString:@"0"]) {
        g_cachedAutoDealType = dealType;
    }
    NSLog(@"[SecToggle] dealTask class=%@ zddm=%@ dealType=%@ lat=%@ lon=%@",
          g_lastDealClass, zddm, dealType, lat, lon);
    orig_dealTask(self, _cmd, bcdh, bcmxdh, zddm, lat, lon, fjsj, dealType, completion);
    if (g_simulatingAuto) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SecShowSimResult([NSString stringWithFormat:@"dealType=%@", g_lastDealType]);
        });
    }
}

static void SecInstallDealTaskHooks(void) {
    static BOOL installed = NO;
    if (installed) return;

    SEL sel = @selector(dealTaskWithBCDH:bcmxdh:zddm:lat:lon:fjsj:dealType:completion:);
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
        NSLog(@"[SecToggle] Hook dealTask ← %@", NSStringFromClass(hookCls));
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

    CGFloat pw = 280, ph = 148;
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

    g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 28, pw - 16, 52)];
    g_statusLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    g_statusLabel.font = [UIFont systemFontOfSize:11];
    g_statusLabel.numberOfLines = 3;
    g_statusLabel.text = @"站点: 请先打开任务详情";
    [g_panel addSubview:g_statusLabel];

    UIButton *btnNext = [UIButton buttonWithType:UIButtonTypeSystem];
    btnNext.frame = CGRectMake(8, 88, 120, 34);
    [btnNext setTitle:@"下一站" forState:UIControlStateNormal];
    [btnNext setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btnNext.backgroundColor = [UIColor colorWithRed:0.2 green:0.45 blue:0.85 alpha:1];
    btnNext.layer.cornerRadius = 6;
    [btnNext addTarget:[SecToggleHandler shared] action:@selector(onNext:) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:btnNext];

    UIButton *btnAuto = [UIButton buttonWithType:UIButtonTypeSystem];
    btnAuto.frame = CGRectMake(136, 88, 136, 34);
    [btnAuto setTitle:@"模拟自动到达" forState:UIControlStateNormal];
    [btnAuto setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btnAuto.backgroundColor = [UIColor colorWithRed:0.72 green:0.38 blue:0.05 alpha:1];
    btnAuto.layer.cornerRadius = 6;
    [btnAuto addTarget:[SecToggleHandler shared] action:@selector(onSimAutoArrive:) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:btnAuto];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[SecToggleHandler shared] action:@selector(onPan:)];
    [g_panel addGestureRecognizer:pan];

    [win addSubview:g_panel];
    [win bringSubviewToFront:g_panel];
    NSLog(@"[SecToggle] 悬浮窗已显示（含模拟自动到达）");
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
    NSLog(@"[SecToggle] 开关 %@", g_enabled ? @"ON" : @"OFF");
    SecUpdateStatusLabel();
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

static void (*orig_setBody)(id, SEL, NSData *);

static void hook_setBody(id self, SEL _cmd, NSData *body) {
    if (g_enabled && body.length > 0 && body.length < 65536) {
        NSString *raw = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (raw) {
            NSMutableURLRequest *req = (NSMutableURLRequest *)self;
            NSString *url = req.URL.absoluteString;
            if ([url containsString:@"/app/sjb/v1"] &&
                ([url containsString:@"rwcz"] || [url containsString:@"car/"])) {
                NSString *patched = PatchJson(raw);
                if (![patched isEqualToString:raw]) {
                    body = [patched dataUsingEncoding:NSUTF8StringEncoding];
                    NSLog(@"[SecToggle] 改包 %@", url);
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

    NSLog(@"[SecToggle] Hooks 安装完成");
}

#pragma mark - 入口

__attribute__((constructor))
static void SecToggleEntry(void) {
    SecInstallHooks();
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SecCreatePanel();
        });
    });
}
