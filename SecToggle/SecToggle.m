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
#import <math.h>
#import "SecDeviceID.h"
#import "SecLicenseCore.h"

void SecUpdateStatusLabel(void);
static void SecUpdateStationPicker(void);
static void SecSortStations(void);
static void SecInstallDealTaskHooks(void);
static void SecInstallStayedHooks(void);
static void SecInstallPlateHooks(void);
static void SecPanelLog(NSString *format, ...);
static void SecDebugLog(NSString *format, ...);
static NSString *SecStationTitle(NSDictionary *t);
static NSString *SecStationListTitle(NSDictionary *t);
static UIViewController *SecPresenterVC(void);
static NSString *SecShortURL(NSString *url);
static void SecSelectStationAtIndex(NSInteger idx);
static void SecRefreshFakeLocation(void);
static void SecStartGpsPulse(void);
static void SecStopGpsPulse(void);
static void SecApplyDriveMode(BOOL syncPickerToRoute);
static void SecBuildAutoRoute(void);
static void SecBuildPendingRouteTo(NSInteger targetIdx);
static NSDictionary *RouteDestStation(void);
static NSInteger SecIndexForZddm(NSString *zddm);
static BOOL SecDictIndicatesArrived(NSDictionary *dict);
static BOOL SecStationIsArrived(NSDictionary *s);
static void SecMarkStationArrived(NSDictionary *s);
static NSInteger SecEarliestPendingStationIndex(void);
static BOOL SecActiveGpsCoords(double *outLat, double *outLon);
static BOOL SecResolveSpoofCoords(double *outLat, double *outLon);
static BOOL SecShouldPatchRequestURL(NSString *url);
static BOOL SecBodyLooksLikeGps(NSString *raw);
static void SecEnsureUI(void);
static void SecSetPanelVisible(BOOL visible);
static void SecUpdateLicenseUI(void);
static void SecInstallHooks(void);
static BOOL SecTryActivate(NSString *code);
static void SecSetIconVisible(BOOL visible);
static SEL SecDealTaskSel(void);

@interface SecToggleHandler : NSObject
+ (instancetype)shared;
- (void)onToggle:(UISwitch *)sender;
- (void)onModeChange:(UISegmentedControl *)sender;
- (void)onPickStation:(id)sender;
- (void)onIconTap:(id)sender;
- (void)onIconPan:(UIPanGestureRecognizer *)g;
- (void)onThreeFingerTap:(UITapGestureRecognizer *)g;
- (void)onCopyUUID:(id)sender;
- (void)onActivate:(id)sender;
- (void)onPan:(UIPanGestureRecognizer *)g;
@end

#pragma mark - 状态

static BOOL g_enabled = NO;
static BOOL g_licensed = NO;
static BOOL g_hooksInstalled = NO;
static NSString *g_deviceUUID = nil;
static NSMutableArray *g_stations = nil;
static NSInteger g_stationIndex = 0;
static NSInteger g_routeDestIndex = -1;
static NSString *g_selectedZddm = nil;
static BOOL g_userPickedStation = NO;
static UIView *g_panel = nil;
static UIButton *g_floatingIcon = nil;
static UIWindow *g_hostWindow = nil;
static BOOL g_panelVisible = YES;
static BOOL g_iconVisible = YES;
static BOOL g_threeFingerInstalled = NO;
static UILabel *g_statusLabel = nil;
static UIButton *g_stationPicker = nil;
static UILabel *g_logLabel = nil;
static UIView *g_licenseBox = nil;
static UIView *g_mainBox = nil;
static UILabel *g_licenseUuidLabel = nil;
static UILabel *g_licenseShortLabel = nil;
static UISwitch *g_toggleSwitch = nil;
static UISegmentedControl *g_modeControl = nil;
static BOOL g_autoMode = NO;
static NSMutableSet<NSString *> *g_arrivedZddms = nil;
static NSMutableArray<NSString *> *g_logLines = nil;
static const NSUInteger kSecMaxLogLines = 10;
static NSString *g_lastDealType = nil;
static NSString *g_lastDealClass = nil;
static id g_dealTaskTarget = nil;
static id g_cachedAutoDealType = nil;
static NSString *g_taskBcdh = nil;
static NSString *g_taskBcmxdh = nil;
static CLLocation *g_fakeLocation = nil;
static NSTimer *g_gpsPulseTimer = nil;
static NSInteger g_gpsPulseIndex = 0;

static NSMutableArray<NSArray *> *g_routePoints = nil;
static NSMutableArray<NSNumber *> *g_routeLegEnds = nil;
static NSMutableArray<NSNumber *> *g_routeLegStationIdx = nil;
static NSUInteger g_routeIndex = 0;
static BOOL g_routeActive = NO;
static BOOL g_routeFinished = NO;
static const double kSecRouteStepM = 25.0;
static const double kSecDriveSpeedMinMS = 60.0 / 3.6;
static const double kSecDriveSpeedMaxMS = 80.0 / 3.6;
static const double kSecRouteTickSec = 3.0;

static double SecRandomDriveSpeedMS(void) {
    double t = (double)arc4random_uniform(10001) / 10000.0;
    return kSecDriveSpeedMinMS + t * (kSecDriveSpeedMaxMS - kSecDriveSpeedMinMS);
}

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
        double zdbj = ParseDouble(dict[@"n_zdbj"]);
        double sortTime = NAN;
        NSArray *timeKeys = @[@"n_jhsj", @"jhsj", @"d_jhsj", @"c_jhsj",
                              @"n_fjsj", @"fjsj", @"d_fjsj", @"c_fjsj",
                              @"n_ddsj", @"ddsj", @"n_zdsj", @"zdsj", @"n_sj", @"sj"];
        for (NSString *tk in timeKeys) {
            double tv = ParseDouble(dict[tk]);
            if (!isnan(tv) && tv > 0) {
                sortTime = tv;
                break;
            }
        }
        if (isnan(sortTime) && queue > 0) sortTime = (double)queue;

        NSString *key = [NSString stringWithFormat:@"%@@%f,%f", zddm, lon, lat];
        BOOL arrived = SecDictIndicatesArrived(dict);
        BOOL exists = NO;
        BOOL changed = NO;
        for (NSMutableDictionary *s in g_stations) {
            if ([s[@"key"] isEqualToString:key] || [s[@"zddm"] isEqualToString:zddm]) {
                exists = YES;
                if (name.length) s[@"name"] = name;
                if (queue > 0) s[@"queue"] = @(queue);
                if (zdbj > 0) s[@"zdbj"] = @(zdbj);
                if (!isnan(sortTime)) s[@"sortTime"] = @(sortTime);
                s[@"jd"] = @(lon);
                s[@"wd"] = @(lat);
                if (arrived) {
                    s[@"arrived"] = @YES;
                    if (zddm.length) {
                        if (!g_arrivedZddms) g_arrivedZddms = [NSMutableSet set];
                        [g_arrivedZddms addObject:zddm];
                    }
                }
                changed = YES;
                break;
            }
        }
        if (!exists) {
            NSMutableDictionary *entry = [@{@"key":key, @"zddm":zddm, @"name":name,
                                            @"jd":@(lon), @"wd":@(lat), @"queue":@(queue),
                                            @"zdbj":@(zdbj > 0 ? zdbj : 35),
                                            @"arrived":@(arrived)} mutableCopy];
            if (!isnan(sortTime)) entry[@"sortTime"] = @(sortTime);
            if (arrived && zddm.length) {
                if (!g_arrivedZddms) g_arrivedZddms = [NSMutableSet set];
                [g_arrivedZddms addObject:zddm];
            }
            [g_stations addObject:entry];
            if (g_stations.count <= 12) {
                SecDebugLog(@"解析站点 %@", SecStationTitle(entry));
            }
            changed = YES;
        }
        if (changed) {
            SecSortStations();
            if (!g_selectedZddm.length && g_stations.count) {
                g_stationIndex = 0;
                g_selectedZddm = [g_stations[0][@"zddm"] description];
            } else {
                for (NSUInteger i = 0; i < g_stations.count; i++) {
                    if ([g_stations[i][@"zddm"] isEqualToString:g_selectedZddm]) {
                        g_stationIndex = (NSInteger)i;
                        break;
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                SecUpdateStatusLabel();
                SecUpdateStationPicker();
                if (g_enabled && g_stations.count) SecApplyDriveMode(NO);
            });
        }
    }
    for (id k in dict) ExtractStationsFromObject(dict[k], depth + 1);
}

static NSInteger SecIndexForZddm(NSString *zddm) {
    if (!zddm.length) return -1;
    for (NSUInteger i = 0; i < g_stations.count; i++) {
        if ([g_stations[i][@"zddm"] isEqualToString:zddm]) return (NSInteger)i;
    }
    return -1;
}

static NSDictionary *DisplayStation(void) {
    if (g_stations.count == 0) return nil;
    NSInteger idx = SecIndexForZddm(g_selectedZddm);
    if (idx < 0) idx = g_stationIndex;
    if (idx < 0 || idx >= (NSInteger)g_stations.count) idx = 0;
    g_stationIndex = idx;
    return g_stations[idx];
}

static NSDictionary *RouteDestStation(void) {
    if (g_routeDestIndex >= 0 && g_routeDestIndex < (NSInteger)g_stations.count) {
        return g_stations[g_routeDestIndex];
    }
    return DisplayStation();
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

static NSString *SecFormatSortTime(double sortTime) {
    if (sortTime <= 0 || isnan(sortTime)) return @"";
    if (sortTime > 1e11) {
        static NSDateFormatter *df;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"MM-dd HH:mm";
        });
        return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:sortTime / 1000.0]];
    }
    return [NSString stringWithFormat:@"#%.0f", sortTime];
}

static NSString *SecStationListTitle(NSDictionary *t) {
    if (!t) return @"未知站点";
    NSString *timeStr = SecFormatSortTime([t[@"sortTime"] doubleValue]);
    NSString *title = SecStationTitle(t);
    if (timeStr.length) return [NSString stringWithFormat:@"%@  %@", timeStr, title];
    return title;
}

static BOOL SecDictIndicatesArrived(NSDictionary *dict) {
    NSArray *stKeys = @[@"n_zdzt", @"c_zdzt", @"n_ddzt", @"c_ddzt", @"n_zdwc", @"n_wczt", @"n_zdztms"];
    for (NSString *k in stKeys) {
        id v = dict[k];
        if (!v || v == (id)kCFNull) continue;
        NSString *s = [[v description] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!s.length || [s isEqualToString:@"(null)"]) continue;
        if ([s isEqualToString:@"2"] || [s isEqualToString:@"3"] || [s isEqualToString:@"9"] ||
            [s isEqualToString:@"Y"] || [s isEqualToString:@"y"]) return YES;
        if ([s containsString:@"已到"] || [s containsString:@"到达"] || [s containsString:@"完成"]) return YES;
        NSInteger n = [s integerValue];
        if (n >= 2 && n <= 5) return YES;
    }
    return NO;
}

static BOOL SecStationIsArrived(NSDictionary *s) {
    if (!s) return NO;
    if ([s[@"arrived"] boolValue]) return YES;
    NSString *zddm = [s[@"zddm"] description];
    return zddm.length && g_arrivedZddms && [g_arrivedZddms containsObject:zddm];
}

static void SecMarkStationArrived(NSDictionary *s) {
    if (!s) return;
    NSString *zddm = [s[@"zddm"] description];
    if (!zddm.length) return;
    if (!g_arrivedZddms) g_arrivedZddms = [NSMutableSet set];
    [g_arrivedZddms addObject:zddm];
    for (NSMutableDictionary *st in g_stations) {
        if ([st[@"zddm"] isEqualToString:zddm]) st[@"arrived"] = @YES;
    }
}

static NSInteger SecEarliestPendingStationIndex(void) {
    for (NSUInteger i = 0; i < g_stations.count; i++) {
        if (!SecStationIsArrived(g_stations[i])) return (NSInteger)i;
    }
    return -1;
}

static void SecSortStations(void) {
    [g_stations sortUsingComparator:^NSComparisonResult(id a, id b) {
        double ta = [a[@"sortTime"] doubleValue];
        double tb = [b[@"sortTime"] doubleValue];
        if (ta > 0 && tb > 0) {
            if (ta < tb) return NSOrderedAscending;
            if (ta > tb) return NSOrderedDescending;
        } else if (ta > 0) {
            return NSOrderedAscending;
        } else if (tb > 0) {
            return NSOrderedDescending;
        }
        NSInteger qa = [a[@"queue"] integerValue];
        NSInteger qb = [b[@"queue"] integerValue];
        if (qa > 0 && qb > 0) {
            if (qa < qb) return NSOrderedAscending;
            if (qa > qb) return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
}

static NSDictionary *SpoofTarget(void) {
    if (g_stations.count == 0 || !g_enabled) return nil;
    if (g_autoMode && g_routeActive && g_routeDestIndex >= 0) return RouteDestStation();
    return DisplayStation();
}

static NSDictionary *CurrentTarget(void) {
    return SpoofTarget();
}

static BOOL SecShouldJitterGps(void) {
    return g_enabled;
}

static void SecSpoofedCoords(NSDictionary *t, double *outLat, double *outLon, BOOL jitter) {
    double baseLat = [t[@"wd"] doubleValue];
    double baseLon = [t[@"jd"] doubleValue];
    if (!jitter) {
        *outLat = baseLat;
        *outLon = baseLon;
        return;
    }

    double radiusM = [t[@"zdbj"] doubleValue];
    if (radiusM <= 0 || radiusM > 800) radiusM = 35.0;
    double maxM = radiusM * 0.4;
    if (maxM < 10) maxM = 10;
    if (maxM > 50) maxM = 50;

    NSInteger i = g_gpsPulseIndex;
    double angle = fmod(i * 0.9, 2.0 * M_PI);
    double dist = maxM * (0.2 + 0.8 * ((i % 6) / 6.0));
    double cosLat = cos(baseLat * M_PI / 180.0);
    if (fabs(cosLat) < 0.01) cosLat = 0.01;

    *outLat = baseLat + (dist * cos(angle)) / 111320.0;
    *outLon = baseLon + (dist * sin(angle)) / (111320.0 * cosLat);
}

static double SecHaversineM(double lat1, double lon1, double lat2, double lon2) {
    double r = 6371000.0;
    double p1 = lat1 * M_PI / 180.0;
    double p2 = lat2 * M_PI / 180.0;
    double dp = (lat2 - lat1) * M_PI / 180.0;
    double dl = (lon2 - lon1) * M_PI / 180.0;
    double a = sin(dp / 2) * sin(dp / 2) +
               cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

static void SecRouteAppendPoint(double lat, double lon) {
    if (!g_routePoints) g_routePoints = [NSMutableArray array];
    if (g_routePoints.count) {
        NSArray *last = g_routePoints.lastObject;
        double dLat = fabs([last[0] doubleValue] - lat);
        double dLon = fabs([last[1] doubleValue] - lon);
        if (dLat < 1e-8 && dLon < 1e-8) return;
    }
    [g_routePoints addObject:@[@(lat), @(lon)]];
}

static void SecRouteAppendLeg(double lat1, double lon1, double lat2, double lon2) {
    double dist = SecHaversineM(lat1, lon1, lat2, lon2);
    if (dist < 1.0) {
        SecRouteAppendPoint(lat2, lon2);
        return;
    }
    NSInteger steps = (NSInteger)ceil(dist / kSecRouteStepM);
    if (steps < 1) steps = 1;
    for (NSInteger s = 1; s <= steps; s++) {
        double f = (double)s / (double)steps;
        SecRouteAppendPoint(lat1 + (lat2 - lat1) * f, lon1 + (lon2 - lon1) * f);
    }
}

static void SecBuildPendingRouteTo(NSInteger targetIdx) {
    if (!g_routePoints) g_routePoints = [NSMutableArray array];
    if (!g_routeLegEnds) g_routeLegEnds = [NSMutableArray array];
    if (!g_routeLegStationIdx) g_routeLegStationIdx = [NSMutableArray array];
    [g_routePoints removeAllObjects];
    [g_routeLegEnds removeAllObjects];
    [g_routeLegStationIdx removeAllObjects];
    g_routeFinished = NO;
    g_routeIndex = 0;

    if (g_stations.count == 0) {
        g_routeActive = NO;
        return;
    }
    if (targetIdx < 0) targetIdx = 0;
    if (targetIdx >= (NSInteger)g_stations.count) targetIdx = (NSInteger)g_stations.count - 1;
    if (SecStationIsArrived(g_stations[targetIdx])) {
        g_routeActive = NO;
        SecPanelLog(@"该站已到达，跳过规划");
        return;
    }

    NSInteger start = SecEarliestPendingStationIndex();
    if (start < 0) start = 0;
    if (targetIdx < start) start = targetIdx;

    NSMutableArray<NSNumber *> *chain = [NSMutableArray array];
    for (NSInteger i = start; i <= targetIdx; i++) {
        if (!SecStationIsArrived(g_stations[i])) [chain addObject:@(i)];
    }
    if (!chain.count) {
        g_routeActive = NO;
        g_routeDestIndex = -1;
        return;
    }

    g_routeDestIndex = chain.lastObject.integerValue;

    if (chain.count == 1) {
        NSDictionary *s = g_stations[chain[0].integerValue];
        SecRouteAppendPoint([s[@"wd"] doubleValue], [s[@"jd"] doubleValue]);
        g_routeActive = g_enabled;
        return;
    }

    for (NSUInteger c = 0; c < chain.count - 1; c++) {
        NSDictionary *a = g_stations[chain[c].integerValue];
        NSDictionary *b = g_stations[chain[c + 1].integerValue];
        double lat1 = [a[@"wd"] doubleValue];
        double lon1 = [a[@"jd"] doubleValue];
        double lat2 = [b[@"wd"] doubleValue];
        double lon2 = [b[@"jd"] doubleValue];
        if (c == 0) SecRouteAppendPoint(lat1, lon1);
        SecRouteAppendLeg(lat1, lon1, lat2, lon2);
        [g_routeLegEnds addObject:@(g_routePoints.count - 1)];
        [g_routeLegStationIdx addObject:chain[c + 1]];
    }

    g_routeActive = g_enabled && g_routePoints.count > 1;
    if (g_routeActive) {
        double km = 0;
        for (NSUInteger i = 1; i < g_routePoints.count; i++) {
            km += SecHaversineM([g_routePoints[i-1][0] doubleValue], [g_routePoints[i-1][1] doubleValue],
                                [g_routePoints[i][0] doubleValue], [g_routePoints[i][1] doubleValue]);
        }
        NSDictionary *fromS = g_stations[chain[0].integerValue];
        NSDictionary *toS = g_stations[chain.lastObject.integerValue];
        SecPanelLog(@"全自动 %.1fkm %@ → %@", km / 1000.0, SecStationTitle(fromS), SecStationTitle(toS));
    }
}

static void SecBuildAutoRoute(void) {
    NSInteger lastPending = -1;
    for (NSInteger i = (NSInteger)g_stations.count - 1; i >= 0; i--) {
        if (!SecStationIsArrived(g_stations[i])) {
            lastPending = i;
            break;
        }
    }
    if (lastPending < 0) {
        g_routeActive = NO;
        g_routeDestIndex = -1;
        SecPanelLog(@"全自动：无待到达站点");
        return;
    }

    NSInteger target = lastPending;
    if (g_userPickedStation) {
        NSInteger picked = SecIndexForZddm(g_selectedZddm);
        if (picked >= 0 && !SecStationIsArrived(g_stations[picked])) {
            target = picked;
        }
    }
    SecBuildPendingRouteTo(target);
}

static void SecSyncPickerToRouteDest(void) {
    if (g_routeDestIndex < 0 || g_routeDestIndex >= (NSInteger)g_stations.count) return;
    g_stationIndex = g_routeDestIndex;
    g_selectedZddm = [g_stations[g_routeDestIndex][@"zddm"] description];
}

static void SecApplyDriveMode(BOOL syncPickerToRoute) {
    g_routeFinished = NO;
    if (!g_enabled || !g_stations.count) {
        g_routeActive = NO;
        return;
    }
    if (g_autoMode) {
        SecBuildAutoRoute();
        if (syncPickerToRoute) {
            SecSyncPickerToRouteDest();
            g_userPickedStation = NO;
        }
    } else {
        g_routeDestIndex = -1;
        g_routeActive = NO;
        [g_routePoints removeAllObjects];
        [g_routeLegEnds removeAllObjects];
        if (g_routeLegStationIdx) [g_routeLegStationIdx removeAllObjects];
        g_routeIndex = 0;
        NSDictionary *t = DisplayStation();
        if (t) SecPanelLog(@"手动定位：%@", SecStationTitle(t));
    }
    SecRefreshFakeLocation();
}

static void SecApplyMicroJitter(double baseLat, double baseLon, double *outLat, double *outLon) {
    double cosLat = cos(baseLat * M_PI / 180.0);
    if (fabs(cosLat) < 0.01) cosLat = 0.01;
    double angle = fmod(g_gpsPulseIndex * 0.7, 2.0 * M_PI);
    double dist = 2.0 + (g_gpsPulseIndex % 4);
    *outLat = baseLat + (dist * cos(angle)) / 111320.0;
    *outLon = baseLon + (dist * sin(angle)) / (111320.0 * cosLat);
}

static BOOL SecActiveGpsCoords(double *outLat, double *outLon) {
    if (!g_enabled) return NO;

    if (g_routeActive && g_routePoints.count) {
        NSUInteger idx = g_routeIndex;
        if (idx >= g_routePoints.count) idx = g_routePoints.count - 1;
        NSArray *p = g_routePoints[idx];
        double lat = [p[0] doubleValue];
        double lon = [p[1] doubleValue];

        if (g_routeFinished) {
            NSDictionary *t = RouteDestStation();
            if (t) {
                SecSpoofedCoords(t, outLat, outLon, YES);
                return YES;
            }
        }

        SecApplyMicroJitter(lat, lon, outLat, outLon);
        return YES;
    }

    NSDictionary *t = SpoofTarget();
    if (!t) return NO;
    SecSpoofedCoords(t, outLat, outLon, SecShouldJitterGps());
    return YES;
}

static BOOL SecResolveSpoofCoords(double *outLat, double *outLon) {
    if (SecActiveGpsCoords(outLat, outLon)) return YES;
    if (!g_enabled) return NO;
    NSDictionary *t = CurrentTarget();
    if (!t) return NO;
    SecSpoofedCoords(t, outLat, outLon, YES);
    return YES;
}

static BOOL SecBodyLooksLikeGps(NSString *raw) {
    if (!raw.length) return NO;
    static NSArray *needles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        needles = @[
            @"\"n_jd\"", @"\"n_wd\"", @"\"n_zdjd\"", @"\"n_zdwd\"",
            @"\"latitude\"", @"\"longitude\"", @"\"gpslatitude\"", @"\"gpslongitude\"",
            @"\"lat\"", @"\"lng\""
        ];
    });
    for (NSString *n in needles) {
        if ([raw containsString:n]) return YES;
    }
    return NO;
}

static BOOL SecShouldPatchRequestURL(NSString *url) {
    if (!url.length || ![url containsString:@"/app/sjb/v1"]) return NO;
    static NSArray *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"car/", @"rwcz", @"location", @"withGPS", @"withgps",
            @"gps", @"track", @"position", @"trajectory", @"driver"
        ];
    });
    for (NSString *k in keys) {
        if ([url rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
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

static void SecApplyGpsPatchToJson(NSString **inOutRaw, double wd, double jd, NSString *url, NSDictionary *t) {
    NSString *raw = *inOutRaw;
    NSString *zddm = [t[@"zddm"] description];
    NSString *out = raw;

    BOOL isArrive = [url containsString:@"rwcz"] &&
        ([url containsString:@"zddd"] || [url containsString:@"zdqd"] ||
         [url containsString:@"zdlk"] || [url containsString:@"/qd"]);

    NSArray *allKeys = @[@"n_jd", @"n_wd", @"n_zdjd", @"n_zdwd",
                         @"gpslongitude", @"gpslatitude", @"longitude", @"latitude", @"lng", @"lat"];
    for (NSString *key in allKeys) {
        BOOL isLat = [key isEqualToString:@"n_wd"] || [key isEqualToString:@"n_zdwd"] ||
                     [key isEqualToString:@"lat"] || [key isEqualToString:@"latitude"] ||
                     [key isEqualToString:@"gpslatitude"];
        out = SecPatchCoordField(out, key, isLat ? wd : jd);
    }

    if (isArrive && zddm.length) {
        out = SecPatchStringField(out, @"c_zddm", zddm);
        out = SecPatchStringField(out, @"zddm", zddm);
        SecDebugLog(@"到达改包 %@", SecStationTitle(t));
    }

    *inOutRaw = out;
}

static NSString *PatchJsonForRequest(NSString *raw, NSString *url) {
    if (!g_enabled || !raw.length) return raw;

    double wd = 0, jd = 0;
    if (!SecResolveSpoofCoords(&wd, &jd)) return raw;

    NSDictionary *t = CurrentTarget();
    if (!t) return raw;

    NSString *out = raw;
    SecApplyGpsPatchToJson(&out, wd, jd, url, t);
    return out;
}

static NSString *PatchJson(NSString *raw) {
    return PatchJsonForRequest(raw, @"");
}

static void SecDebugLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[SecToggle] %@", msg);
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

static void SecRefreshFakeLocation(void) {
    g_gpsPulseIndex++;
}

static void SecSelectStationAtIndex(NSInteger idx) {
    if (g_stations.count == 0) return;
    if (idx < 0 || idx >= (NSInteger)g_stations.count) idx = 0;
    g_userPickedStation = YES;
    g_stationIndex = idx;
    g_selectedZddm = [g_stations[idx][@"zddm"] description];
    if (g_enabled) {
        if (g_autoMode) {
            SecBuildPendingRouteTo(idx);
            SecRefreshFakeLocation();
        } else {
            g_routeDestIndex = -1;
            g_routeActive = NO;
            g_routeFinished = NO;
            SecPanelLog(@"手动定位：%@", SecStationTitle(g_stations[idx]));
            SecRefreshFakeLocation();
        }
    }
    SecUpdateStatusLabel();
    SecUpdateStationPicker();
}

static CLLocation *SecFakeLocation(void) {
    double lat, lon;
    if (SecActiveGpsCoords(&lat, &lon)) {
        return [[CLLocation alloc] initWithLatitude:lat longitude:lon];
    }
    return nil;
}

static void SecGpsPulseTick(NSTimer *timer) {
    (void)timer;
    if (!g_enabled) return;
    SecRefreshFakeLocation();

    if (g_routeActive && g_routePoints.count > 1 && !g_routeFinished) {
        double speed = SecRandomDriveSpeedMS();
        NSUInteger advance = (NSUInteger)MAX(1, (speed * kSecRouteTickSec) / kSecRouteStepM);
        NSUInteger prev = g_routeIndex;
        g_routeIndex = MIN(g_routeIndex + advance, g_routePoints.count - 1);

        for (NSUInteger leg = 0; leg < g_routeLegEnds.count; leg++) {
            NSUInteger endIdx = [g_routeLegEnds[leg] unsignedIntegerValue];
            if (prev < endIdx && g_routeIndex >= endIdx && leg < g_routeLegStationIdx.count) {
                NSInteger passIdx = [g_routeLegStationIdx[leg] integerValue];
                if (passIdx >= 0 && passIdx < (NSInteger)g_stations.count) {
                    if (passIdx != g_routeDestIndex) {
                        SecPanelLog(@"途经 %@", SecStationTitle(g_stations[passIdx]));
                    }
                    if (g_autoMode) SecMarkStationArrived(g_stations[passIdx]);
                }
            }
        }

        if (g_routeIndex >= g_routePoints.count - 1) {
            g_routeFinished = YES;
            NSDictionary *arrived = RouteDestStation();
            SecPanelLog(@"到达 %@", SecStationTitle(arrived));
            if (g_autoMode && arrived) {
                SecMarkStationArrived(arrived);
                SecBuildAutoRoute();
                SecSyncPickerToRouteDest();
                SecUpdateStationPicker();
                if (!g_routeActive) SecPanelLog(@"全自动：全部完成");
            }
        }
        return;
    }
}

static void SecStartGpsPulse(void) {
    SecStopGpsPulse();
    g_gpsPulseTimer = [NSTimer scheduledTimerWithTimeInterval:kSecRouteTickSec
                                                      repeats:YES
                                                        block:^(NSTimer *t) {
        SecGpsPulseTick(t);
    }];
    SecGpsPulseTick(nil);
}

static void SecStopGpsPulse(void) {
    [g_gpsPulseTimer invalidate];
    g_gpsPulseTimer = nil;
}

#pragma mark - 任务页缓存

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

static UIViewController *SecTopViewController(UIViewController *vc) {
    if (!vc) return nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return SecTopViewController([(UINavigationController *)vc visibleViewController]);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        return SecTopViewController([(UITabBarController *)vc selectedViewController]);
    }
    if (vc.presentedViewController) {
        return SecTopViewController(vc.presentedViewController);
    }
    return vc;
}

static void SecCollectTaskIdsFromObject(id obj) {
    if (!obj) return;
    if (!g_taskBcdh.length) {
        g_taskBcdh = SecStringFromKV(obj, @[@"n_bcdh", @"bcdh", @"_n_bcdh", @"_bcdh", @"c_bcdh"]);
    }
    if (!g_taskBcmxdh.length) {
        g_taskBcmxdh = SecStringFromKV(obj, @[@"n_bcmxdh", @"bcmxdh", @"_n_bcmxdh", @"c_bcmxdh"]);
    }
}

static void SecCollectTaskIdsFromUI(void) {
    if (g_dealTaskTarget) {
        SecCollectTaskIdsFromObject(g_dealTaskTarget);
    }
    SecForEachWindow(^(UIWindow *win) {
        if (g_taskBcdh.length && g_taskBcmxdh.length && g_dealTaskTarget) return;
        UIViewController *top = SecTopViewController(win.rootViewController);
        for (UIViewController *vc = top; vc; vc = vc.parentViewController) {
            SecCollectTaskIdsFromObject(vc);
            if (!g_dealTaskTarget && SecIsXPDObject(vc)) {
                id svc = SecKVCTry(vc, @"service") ?: SecKVCTry(vc, @"_service");
                if (svc) g_dealTaskTarget = svc;
            }
            if (g_taskBcdh.length && g_taskBcmxdh.length && g_dealTaskTarget) break;
        }
    });
}

static void (*orig_stayedFired)(id, SEL, id);

static void hook_stayedFired(id self, SEL _cmd, id timer) {
    if (g_stayedTargets) [g_stayedTargets addObject:self];
    if (g_siteTargets && SecClassMatches(self)) [g_siteTargets addObject:self];
    orig_stayedFired(self, _cmd, timer);
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
        SecDebugLog(@"Hook handleWhenStayedTimerFired ← %@", NSStringFromClass(classes[i]));
        installed = YES;
        break;
    }
    free(classes);
}

#pragma mark - dealTask 日志

static void (*orig_dealTask)(id, SEL, id, id, id, id, id, id, id, id);

static void hook_dealTask(id self, SEL _cmd, id bcdh, id bcmxdh, id zddm,
                          id lat, id lon, id fjsj, id dealType, id completion) {
    g_dealTaskTarget = self;

    id useZddm = zddm;
    id useLat = lat;
    id useLon = lon;
    if (g_enabled) {
        NSDictionary *t = CurrentTarget();
        double slat, slon;
        if (SecResolveSpoofCoords(&slat, &slon)) {
            useLat = @(slat);
            useLon = @(slon);
            if (t) useZddm = t[@"zddm"] ?: zddm;
        } else if (t) {
            useZddm = t[@"zddm"] ?: zddm;
            useLat = t[@"wd"] ?: lat;
            useLon = t[@"jd"] ?: lon;
        }
    }

    id useType = dealType;
    g_lastDealType = [useType description];
    g_lastDealClass = NSStringFromClass([self class]);
    if (!SecIsManualDealType(useType)) {
        g_cachedAutoDealType = useType;
    }

    SecDebugLog(@"dealTask %@ zddm=%@ type=%@", g_lastDealClass, useZddm, useType);
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
        SecDebugLog(@"Hook dealTask ← %@", NSStringFromClass(hookCls));
        installed = YES;
    }
    free(classes);
}

#pragma mark - 扫牌自动填车牌

static NSMapTable *g_plateFilledObjects = nil;

static NSSet *SecPlateKnownVCNames(void) {
    static NSSet *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithObjects:
                 @"XPDDispatchVehCheckVC",
                 @"XPDCarTakePhoneVC",
                 @"XPDCarInfoVC",
                 @"XPDPassOnTaskConfirmVC",
                 @"XPDPassOnConfrimTabVC",
                 @"XPDReturnVehVC",
                 @"XPDChangeVehVC",
                 @"XPDArrangeVehListVC",
                 @"XPDCrenelVController",
                 @"XPDCrenelBindingController",
                 @"XPDCrenelSearchController",
                 @"XPDCityLineArrangeVC",
                 @"XPDCityLineArrangeDealVC",
                 @"XPDYardSiteVC",
                 @"XPDStationDealVC",
                 @"XPDStationDeal1VC",
                 @"XPDReceiveTaskVC",
                 @"XPDReceivePassTaskVC",
                 @"XPDDepartVC",
                 @"XPDTaskDetailVC",
                 @"XPDTaskHistoryDetailVC",
                 @"XPDWorkContentViewController",
                 @"XPDWorkbenchViewController",
                 @"XPDVehLocVC",
                 @"XPDVehMaintainVC",
                 @"XPDVehPartExpReportVC",
                 @"XPDArriveStationVC",
                 @"XPDWaybilPassonVC",
                 @"XPDTaskPassonVC",
                 @"WTPlateIDCameraViewController",
                 nil];
    });
    return names;
}

static BOOL SecObjectHasScanUI(id obj) {
    if (!obj) return NO;
    for (NSString *k in @[
        @"scanCarBtn", @"scanCrenelBtn", @"licensePlateNumLab", @"licensePlateImg",
        @"btnScan", @"scanerbtn", @"cphLabel", @"lbCph", @"carNoLab", @"carNolab",
        @"scanImg", @"replaceScanBut", @"mySetScanImg", @"plateIDRecog", @"socreLabel"
    ]) {
        if (SecKVCTry(obj, k)) return YES;
    }
    return NO;
}

static BOOL SecObjectHasScanCallbacks(id obj) {
    if (!obj) return NO;
    return [obj respondsToSelector:@selector(scanSucessWithRegName:color:confidence:)] ||
           [obj respondsToSelector:@selector(scanResultRegname:color:)] ||
           [obj respondsToSelector:@selector(scanResultRegname:CPYS:)] ||
           [obj respondsToSelector:@selector(getCarScan:cpys:)] ||
           [obj respondsToSelector:@selector(scanAndCheckFramesValidWithImageSource:)] ||
           [obj respondsToSelector:@selector(btnScanRegnameAction:)] ||
           [obj respondsToSelector:@selector(tapScanLisenceNo:)] ||
           [obj respondsToSelector:@selector(scanBtnAction:)] ||
           [obj respondsToSelector:@selector(btnScanAction:)] ||
           [obj respondsToSelector:@selector(setCPH:cldm:)];
}

static BOOL SecObjectSupportsPlateScan(id obj) {
    if (!obj) return NO;
    NSString *cn = NSStringFromClass([obj class]);
    if ([cn isEqualToString:@"WTPlateIDCameraViewController"]) return YES;
    if ([SecPlateKnownVCNames() containsObject:cn]) return YES;
    if ([cn hasPrefix:@"XPD"] || [cn hasPrefix:@"WTPlate"]) {
        if (SecObjectHasScanCallbacks(obj) || SecObjectHasScanUI(obj)) return YES;
        static NSArray *nameHints;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            nameHints = @[
                @"VehCheck", @"CarTake", @"CarInfo", @"PassOn", @"Passon", @"ReturnVeh",
                @"ChangeVeh", @"ArrangeVeh", @"Crenel", @"CityLine", @"YardSite",
                @"StationDeal", @"ReceiveTask", @"Depart", @"TaskDetail", @"TaskConfirm",
                @"SiteV", @"WorkContent", @"TaskStatus", @"TaskProcess", @"VehPart",
                @"VehLoc", @"VehMaintain", @"Scan", @"Plate", @"Workbench", @"Waybil"
            ];
        });
        for (NSString *hint in nameHints) {
            if ([cn containsString:hint]) return YES;
        }
    }
    return NO;
}

static UIViewController *SecViewControllerForResponder(id obj) {
    if ([obj isKindOfClass:[UIViewController class]]) return (UIViewController *)obj;
    UIResponder *r = [obj isKindOfClass:[UIResponder class]] ? (UIResponder *)obj : nil;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

static NSString *SecNormalizePlateText(NSString *raw) {
    if (!raw.length) return nil;
    NSString *t = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                   stringByReplacingOccurrencesOfString:@" " withString:@""];
    if ([t containsString:@"车牌"] || [t containsString:@"扫"] ||
        [t containsString:@"点击"] || [t containsString:@"请输入"] ||
        [t isEqualToString:@"—"] || [t isEqualToString:@"--"] ||
        [t isEqualToString:@"(null)"] || [t isEqualToString:@"<null>"]) {
        return nil;
    }
    return t;
}

static BOOL SecLooksLikePlate(NSString *s) {
    NSString *t = SecNormalizePlateText(s);
    if (!t || t.length < 7 || t.length > 9) return NO;
    unichar c0 = [t characterAtIndex:0];
    if (c0 < 0x4e00 || c0 > 0x9fff) return NO;
    unichar c1 = [t characterAtIndex:1];
    if (c1 < 'A' || c1 > 'Z') return NO;
    return YES;
}

static NSString *SecReadPlateFromViewHierarchy(UIView *view, NSInteger depth) {
    if (!view || depth > 12) return nil;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *v = SecNormalizePlateText([(UILabel *)view text]);
        if (SecLooksLikePlate(v)) return v;
    }
    if ([view isKindOfClass:[UITextField class]]) {
        NSString *v = SecNormalizePlateText([(UITextField *)view text]);
        if (SecLooksLikePlate(v)) return v;
    }
    for (UIView *sub in view.subviews) {
        NSString *v = SecReadPlateFromViewHierarchy(sub, depth + 1);
        if (v.length) return v;
    }
    return nil;
}

static NSString *SecReadPlateFromObject(id obj, NSInteger depth) {
    if (!obj || depth > 8) return nil;

    NSArray *keys = @[
        @"c_cph", @"cph", @"th_cph", @"ccph", @"c_wy_cph", @"c_qr_sgcph",
        @"c_sgcph", @"c_xcph", @"sqghcph", @"qrcph", @"vehicleCode",
        @"plateNumber", @"plate_number", @"plateIDNumber", @"c_xcph"
    ];
    for (NSString *k in keys) {
        NSString *v = SecNormalizePlateText(SecStringFromKV(obj, @[k]));
        if (SecLooksLikePlate(v)) return v;
    }

    NSArray *labelKeys = @[
        @"licensePlateNumLab", @"carNoLab", @"cphLabel", @"lbCph", @"carNolab",
        @"cardLicencePlate1Lab", @"cardLicencePlate2Lab",
        @"cardLicensePlate1Lab", @"cardLicensePlate2Lab"
    ];
    for (NSString *k in labelKeys) {
        id lab = SecKVCTry(obj, k);
        if ([lab respondsToSelector:@selector(text)]) {
            NSString *v = SecNormalizePlateText([lab text]);
            if (SecLooksLikePlate(v)) return v;
        }
    }

    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in keys) {
            id raw = ((NSDictionary *)obj)[k];
            NSString *v = SecNormalizePlateText([raw description]);
            if (SecLooksLikePlate(v)) return v;
        }
        return nil;
    }

    if ([obj isKindOfClass:[UIViewController class]]) {
        NSString *v = SecReadPlateFromViewHierarchy(((UIViewController *)obj).view, 0);
        if (v.length) return v;
    } else if ([obj isKindOfClass:[UIView class]]) {
        NSString *v = SecReadPlateFromViewHierarchy((UIView *)obj, 0);
        if (v.length) return v;
    }

    NSArray *modelKeys = @[
        @"model", @"checkModel", @"checkData", @"vehDic", @"task", @"taskModel",
        @"vehicleInfo", @"vehInfo", @"curVehicleInfo", @"carInfo", @"vehModel",
        @"dataModel", @"passModel", @"confirmModel", @"crenelModel", @"arrangeModel",
        @"vehListModel", @"detailModel", @"historyModel", @"selectModel", @"selectVehDic"
    ];
    for (NSString *k in modelKeys) {
        id m = SecKVCTry(obj, k);
        NSString *v = SecReadPlateFromObject(m, depth + 1);
        if (v.length) return v;
    }
    return nil;
}

static NSString *SecResolvePlateForObject(id obj) {
    NSString *plate = SecReadPlateFromObject(obj, 0);
    if (plate.length) return plate;

    UIViewController *vc = SecViewControllerForResponder(obj);
    if (vc && vc != obj) {
        plate = SecReadPlateFromObject(vc, 0);
        if (plate.length) return plate;
    }

    if ([obj isKindOfClass:[UIViewController class]]) {
        UIViewController *host = (UIViewController *)obj;
        for (UIViewController *p in @[
            host.parentViewController, host.presentingViewController,
            host.navigationController ? host.navigationController.viewControllers.firstObject : nil
        ]) {
            plate = SecReadPlateFromObject(p, 0);
            if (plate.length) return plate;
        }
        if (host.navigationController && host.navigationController.viewControllers.count > 1) {
            for (UIViewController *p in host.navigationController.viewControllers) {
                if (p == host) continue;
                plate = SecReadPlateFromObject(p, 0);
                if (plate.length) return plate;
            }
        }
    }
    return nil;
}

static id SecReadPlateColorFromObject(id obj) {
    if (!obj) return nil;
    id cpys = SecKVCTry(obj, @"cpys");
    if (cpys && cpys != (id)kCFNull) return cpys;
    id color = SecKVCTry(obj, @"carColor") ?: SecKVCTry(obj, @"plateColor") ?: SecKVCTry(obj, @"cpysdm");
    if (color && color != (id)kCFNull) return color;
    for (NSString *k in @[@"model", @"checkModel", @"vehDic", @"task", @"taskModel", @"selectVehDic"]) {
        id m = SecKVCTry(obj, k);
        id c = SecReadPlateColorFromObject(m);
        if (c) return c;
    }
    return nil;
}

static void SecInvokePlateScanSuccess(id obj, NSString *plate, id color) {
    if (!obj || !plate.length) return;

    if ([obj respondsToSelector:@selector(scanSucessWithRegName:color:confidence:)]) {
        ((void (*)(id, SEL, id, id, float))objc_msgSend)(
            obj, @selector(scanSucessWithRegName:color:confidence:), plate, color ?: @"", 0.99f);
        return;
    }
    if ([obj respondsToSelector:@selector(scanResultRegname:CPYS:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            obj, @selector(scanResultRegname:CPYS:), plate, color ?: @"");
        return;
    }
    if ([obj respondsToSelector:@selector(scanResultRegname:color:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            obj, @selector(scanResultRegname:color:), plate, color ?: @"");
        return;
    }
    if ([obj respondsToSelector:@selector(getCarScan:cpys:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            obj, @selector(getCarScan:cpys:), plate, color ?: @"1");
        return;
    }
    if ([obj respondsToSelector:@selector(setCPH:cldm:)]) {
        NSString *cldm = SecStringFromKV(obj, @[@"cldm", @"c_cldm", @"c_xcldm"]);
        if (cldm.length) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(
                obj, @selector(setCPH:cldm:), plate, cldm);
        }
    }
}

static UIViewController *SecPlateCameraHostVC(UIViewController *cameraVC) {
    if (!cameraVC) return nil;
    UIViewController *host = cameraVC.presentingViewController;
    if ([host isKindOfClass:[UINavigationController class]]) {
        host = [(UINavigationController *)host visibleViewController];
    }
    if ([host isKindOfClass:[UITabBarController class]]) {
        host = [(UITabBarController *)host selectedViewController];
    }
    return host;
}

static BOOL SecTryAutoFillPlateOnObject(id obj) {
    if (!g_licensed || !obj) return NO;

    NSString *cn = NSStringFromClass([obj class]);
    id target = obj;
    if ([cn isEqualToString:@"WTPlateIDCameraViewController"]) {
        UIViewController *host = SecPlateCameraHostVC((UIViewController *)obj);
        if (!host) return NO;
        target = host;
    } else if (!SecObjectSupportsPlateScan(obj)) {
        UIViewController *vc = SecViewControllerForResponder(obj);
        if (!vc || !SecObjectSupportsPlateScan(vc)) return NO;
        target = vc;
    }

    if (!g_plateFilledObjects) {
        g_plateFilledObjects = [NSMapTable weakToStrongObjectsMapTable];
    }
    if ([g_plateFilledObjects objectForKey:target]) return YES;

    NSString *plate = SecResolvePlateForObject(target);
    if (!plate.length) {
        SecDebugLog(@"扫牌页未读到车牌 %@", NSStringFromClass([target class]));
        return NO;
    }

    id color = SecReadPlateColorFromObject(target) ?: @"1";
    SecInvokePlateScanSuccess(target, plate, color);
    [g_plateFilledObjects setObject:plate forKey:target];

    if ([cn isEqualToString:@"WTPlateIDCameraViewController"] && [obj isKindOfClass:[UIViewController class]]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [(UIViewController *)obj dismissViewControllerAnimated:YES completion:nil];
        });
    }

    SecPanelLog(@"已自动填牌 %@", plate);
    SecDebugLog(@"自动填牌 %@ color=%@ target=%@", plate, color, NSStringFromClass([target class]));
    return YES;
}

static void SecSchedulePlateAutoFill(id obj) {
    if (!g_licensed || !obj) return;
    __weak id weakObj = obj;
    for (int attempt = 0; attempt < 4; attempt++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.25 + attempt * 0.45) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SecTryAutoFillPlateOnObject(weakObj);
        });
    }
}

static void (*orig_viewDidAppear)(id, SEL, BOOL);
static void (*orig_viewWillAppear)(id, SEL, BOOL);

static void hook_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    if (!g_licensed) return;
    if (!SecObjectSupportsPlateScan(self)) return;
    SecSchedulePlateAutoFill(self);
}

static void hook_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewWillAppear(self, _cmd, animated);
    if (!g_licensed) return;
    if (!SecObjectSupportsPlateScan(self)) return;
    SecSchedulePlateAutoFill(self);
}

typedef void (*SecScanBtnIMP)(id, SEL, id);

static NSMutableDictionary *g_scanBtnOrigIMPs = nil;

static NSString *SecScanHookKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@-%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
}

static void SecHookScanSelector(Class cls, SEL sel, IMP hookImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    if (orig == hookImp) return;
    if (!g_scanBtnOrigIMPs) g_scanBtnOrigIMPs = [NSMutableDictionary dictionary];
    g_scanBtnOrigIMPs[SecScanHookKey(cls, sel)] = [NSValue valueWithPointer:orig];
    method_setImplementation(m, hookImp);
    SecDebugLog(@"Hook %@ ← %@", NSStringFromSelector(sel), NSStringFromClass(cls));
}

static void SecCallOrigScanAction(id self, SEL sel, id sender) {
    if (!g_scanBtnOrigIMPs) return;
    NSValue *v = g_scanBtnOrigIMPs[SecScanHookKey(object_getClass(self), sel)];
    SecScanBtnIMP orig = v ? (SecScanBtnIMP)[v pointerValue] : NULL;
    if (orig) orig(self, sel, sender);
}

static void SecHookGenericScanAction(id self, SEL _cmd, id sender) {
    if (SecTryAutoFillPlateOnObject(self)) return;
    SecCallOrigScanAction(self, _cmd, sender);
}

static NSMutableDictionary *g_scanFrameOrigIMPs = nil;

static BOOL SecHookScanFrameValid(id self, SEL _cmd, id imageSource) {
    if (g_licensed && SecTryAutoFillPlateOnObject(self)) return YES;
    if (!g_scanFrameOrigIMPs) return YES;
    NSValue *v = g_scanFrameOrigIMPs[SecScanHookKey(object_getClass(self), _cmd)];
    BOOL (*orig)(id, SEL, id) = v ? (BOOL (*)(id, SEL, id))[v pointerValue] : NULL;
    return orig ? orig(self, _cmd, imageSource) : YES;
}

static void SecInstallPlateHooks(void) {
    static BOOL installed = NO;
    if (installed) return;

    Method appear = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (appear) {
        orig_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(appear);
        method_setImplementation(appear, (IMP)hook_viewDidAppear);
        SecDebugLog(@"Hook UIViewController viewDidAppear:");
    }

    Method willAppear = class_getInstanceMethod([UIViewController class], @selector(viewWillAppear:));
    if (willAppear) {
        orig_viewWillAppear = (void (*)(id, SEL, BOOL))method_getImplementation(willAppear);
        method_setImplementation(willAppear, (IMP)hook_viewWillAppear);
        SecDebugLog(@"Hook UIViewController viewWillAppear:");
    }

    NSArray *scanSels = @[
        @"scanBtnAction:",
        @"btnScanAction:",
        @"tapScanLisenceNo:",
        @"btnScanRegnameAction:",
    ];

    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return;
    Class *classes = (Class *)malloc((size_t)num * sizeof(Class));
    if (!classes) return;
    objc_getClassList(classes, num);

    for (int i = 0; i < num; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (strncmp(name, "XPD", 3) != 0 && strncmp(name, "WTPlate", 7) != 0) continue;

        for (NSString *selName in scanSels) {
            SecHookScanSelector(cls, NSSelectorFromString(selName), (IMP)SecHookGenericScanAction);
        }

        Method frameM = class_getInstanceMethod(cls, @selector(scanAndCheckFramesValidWithImageSource:));
        if (frameM) {
            IMP orig = method_getImplementation(frameM);
            if (orig != (IMP)SecHookScanFrameValid) {
                if (!g_scanFrameOrigIMPs) g_scanFrameOrigIMPs = [NSMutableDictionary dictionary];
                g_scanFrameOrigIMPs[SecScanHookKey(cls, @selector(scanAndCheckFramesValidWithImageSource:))] =
                    [NSValue valueWithPointer:orig];
                method_setImplementation(frameM, (IMP)SecHookScanFrameValid);
                SecDebugLog(@"Hook scanAndCheckFramesValid ← %@", NSStringFromClass(cls));
            }
        }
    }
    free(classes);
    installed = YES;
    SecDebugLog(@"扫牌自动填牌 Hook 就绪（全界面）");
}

#pragma mark - UI

void SecUpdateStatusLabel(void) {
    if (!g_statusLabel) return;
    NSString *expSuffix = @"";
    if ([SecDeviceID isLicensed]) {
        expSuffix = [NSString stringWithFormat:@" | 到期 %@", [SecDeviceID licenseExpiryDisplay]];
    }
    if (g_stations.count == 0) {
        if ([SecDeviceID isLicensed]) {
            g_statusLabel.text = [NSString stringWithFormat:@"已授权%@", expSuffix];
        } else {
            g_statusLabel.text = @"[OFF] 请先打开任务详情";
        }
        return;
    }
    NSString *modeStr = g_autoMode ? @"自动" : @"手动";
    g_statusLabel.text = [NSString stringWithFormat:@"[%@|%@] 共 %lu 站%@",
                          g_enabled ? @"ON" : @"OFF",
                          modeStr,
                          (unsigned long)g_stations.count,
                          expSuffix];
}

static void SecUpdateStationPicker(void) {
    if (!g_stationPicker) return;
    NSDictionary *t = DisplayStation();
    NSString *title = t ? SecStationListTitle(t) : @"▼ 选择站点";
    [g_stationPicker setTitle:title forState:UIControlStateNormal];
    g_stationPicker.enabled = g_stations.count > 0;
}

static UIViewController *SecPresenterVC(void) {
    __block UIViewController *top = nil;
    SecForEachWindow(^(UIWindow *win) {
        if (top) return;
        top = SecTopViewController(win.rootViewController);
    });
    return top;
}

static void SecSetPanelVisible(BOOL visible) {
    g_panelVisible = visible;
    if (g_panel) g_panel.hidden = !visible;
}

static BOOL SecTryActivate(NSString *code) {
    if (!g_deviceUUID.length) g_deviceUUID = [SecDeviceID keychainDeviceUUID];
    NSString *trimmed = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return NO;
    NSString *formatted = SecLicenseCanonicalCode(trimmed);
    if (!formatted.length) return NO;
    NSString *expiry = SecLicenseExpiryFromCode(formatted);
    if (expiry.length && SecLicenseIsExpired(expiry)) return NO;
    if (!SecLicenseVerify(g_deviceUUID, formatted, kSecLicenseDefaultSecret)) return NO;
    if (![SecDeviceID saveActivationCode:formatted]) return NO;
    g_licensed = YES;
    SecInstallHooks();
    SecUpdateLicenseUI();
    SecPanelLog(@"授权成功 到期 %@", [SecDeviceID licenseExpiryDisplay]);
    return YES;
}

static void SecUpdateLicenseUI(void) {
    if (!g_panel) return;
    BOOL licensed = g_licensed;
    CGFloat pw = 280;
    CGFloat ph = licensed ? 272 : 128;
    CGRect f = g_panel.frame;
    g_panel.frame = CGRectMake(f.origin.x, f.origin.y, pw, ph);
    g_licenseBox.frame = CGRectMake(0, 0, pw, ph);
    g_mainBox.frame = CGRectMake(0, 0, pw, ph);
    g_licenseBox.hidden = licensed;
    g_mainBox.hidden = !licensed;
    if (g_toggleSwitch) g_toggleSwitch.enabled = licensed;
    if (g_stationPicker) g_stationPicker.enabled = licensed && g_stations.count > 0;
    if (g_modeControl) g_modeControl.enabled = licensed;
    if (!licensed) {
        if (!g_deviceUUID.length) g_deviceUUID = [SecDeviceID keychainDeviceUUID];
        g_licenseUuidLabel.text = g_deviceUUID ?: @"—";
        g_licenseShortLabel.text = SecLicenseDeviceCodeShort(g_deviceUUID) ?: @"—";
        if (g_statusLabel) {
            g_statusLabel.text = @"未授权 — 复制 UUID 后发码";
            g_statusLabel.textColor = [UIColor systemOrangeColor];
        }
        return;
    }
    if (g_statusLabel) g_statusLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    SecUpdateStatusLabel();
    SecUpdateStationPicker();
}

static void SecSetIconVisible(BOOL visible) {
    g_iconVisible = visible;
    if (g_floatingIcon) g_floatingIcon.hidden = !visible;
    if (!visible) SecSetPanelVisible(NO);
}

static void SecInstallThreeFingerGesture(UIWindow *win) {
    if (!win || g_threeFingerInstalled) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                   initWithTarget:[SecToggleHandler shared]
                                   action:@selector(onThreeFingerTap:)];
    tap.numberOfTapsRequired = 3;
    tap.numberOfTouchesRequired = 3;
    tap.cancelsTouchesInView = NO;
    [win addGestureRecognizer:tap];
    g_hostWindow = win;
    g_threeFingerInstalled = YES;
}

static void SecCreateFloatingIcon(UIWindow *win) {
    if (g_floatingIcon) return;

    CGFloat sz = 46;
    g_floatingIcon = [UIButton buttonWithType:UIButtonTypeCustom];
    g_floatingIcon.frame = CGRectMake(20, 68, sz, sz);
    g_floatingIcon.backgroundColor = [UIColor colorWithRed:0.85 green:0.45 blue:0.05 alpha:0.94];
    g_floatingIcon.layer.cornerRadius = sz / 2.0;
    g_floatingIcon.layer.borderWidth = 2;
    g_floatingIcon.layer.borderColor = [UIColor whiteColor].CGColor;
    g_floatingIcon.layer.shadowColor = [UIColor blackColor].CGColor;
    g_floatingIcon.layer.shadowOpacity = 0.35;
    g_floatingIcon.layer.shadowRadius = 4;
    g_floatingIcon.layer.shadowOffset = CGSizeMake(0, 2);
    [g_floatingIcon setTitle:@"SEC" forState:UIControlStateNormal];
    [g_floatingIcon setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    g_floatingIcon.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [g_floatingIcon addTarget:[SecToggleHandler shared]
                         action:@selector(onIconTap:)
               forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *iconPan = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:[SecToggleHandler shared]
                                       action:@selector(onIconPan:)];
    [g_floatingIcon addGestureRecognizer:iconPan];

    [win addSubview:g_floatingIcon];
}

static void SecEnsureUI(void) {
    if (g_panel && g_floatingIcon) return;

    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.hidden && w.alpha > 0) { win = w; break; }
    }
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SecEnsureUI();
        });
        return;
    }

    SecCreateFloatingIcon(win);
    SecInstallThreeFingerGesture(win);

    if (g_panel) {
        [win bringSubviewToFront:g_panel];
        [win bringSubviewToFront:g_floatingIcon];
        return;
    }

    CGFloat pw = 280, ph = 272;
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(20, 124, pw, ph)];
    g_panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    g_panel.layer.cornerRadius = 10;
    g_panel.userInteractionEnabled = YES;

    g_licenseBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, ph)];
    g_licenseBox.backgroundColor = UIColor.clearColor;
    [g_panel addSubview:g_licenseBox];

    UILabel *licTitle = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, pw - 16, 20)];
    licTitle.text = @"SEC 未授权";
    licTitle.textColor = [UIColor systemOrangeColor];
    licTitle.font = [UIFont boldSystemFontOfSize:13];
    [g_licenseBox addSubview:licTitle];

    g_licenseUuidLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 28, pw - 16, 34)];
    g_licenseUuidLabel.textColor = [UIColor colorWithRed:0.55 green:0.85 blue:1.0 alpha:1];
    g_licenseUuidLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    g_licenseUuidLabel.numberOfLines = 2;
    g_licenseUuidLabel.lineBreakMode = NSLineBreakByCharWrapping;
    [g_licenseBox addSubview:g_licenseUuidLabel];

    g_licenseShortLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 64, pw - 16, 14)];
    g_licenseShortLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1];
    g_licenseShortLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightMedium];
    [g_licenseBox addSubview:g_licenseShortLabel];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(8, 84, (pw - 22) / 2.0, 32);
    [copyBtn setTitle:@"复制 UUID" forState:UIControlStateNormal];
    [copyBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    copyBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.45 blue:0.85 alpha:1];
    copyBtn.layer.cornerRadius = 6;
    [copyBtn addTarget:[SecToggleHandler shared] action:@selector(onCopyUUID:) forControlEvents:UIControlEventTouchUpInside];
    [g_licenseBox addSubview:copyBtn];

    UIButton *actBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    actBtn.frame = CGRectMake(14 + (pw - 22) / 2.0, 84, (pw - 22) / 2.0, 32);
    [actBtn setTitle:@"输入激活码" forState:UIControlStateNormal];
    [actBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    actBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    actBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.55 blue:0.28 alpha:1];
    actBtn.layer.cornerRadius = 6;
    [actBtn addTarget:[SecToggleHandler shared] action:@selector(onActivate:) forControlEvents:UIControlEventTouchUpInside];
    [g_licenseBox addSubview:actBtn];

    g_mainBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, ph)];
    g_mainBox.backgroundColor = UIColor.clearColor;
    [g_panel addSubview:g_mainBox];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, 200, 20)];
    title.text = @"SEC 远程自动到达";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:13];
    [g_mainBox addSubview:title];

    g_toggleSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 60, 2, 51, 31)];
    [g_toggleSwitch addTarget:[SecToggleHandler shared] action:@selector(onToggle:) forControlEvents:UIControlEventValueChanged];
    [g_mainBox addSubview:g_toggleSwitch];

    g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 28, pw - 16, 16)];
    g_statusLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    g_statusLabel.font = [UIFont systemFontOfSize:10];
    g_statusLabel.numberOfLines = 1;
    g_statusLabel.text = @"请先打开任务详情";
    [g_mainBox addSubview:g_statusLabel];

    g_stationPicker = [UIButton buttonWithType:UIButtonTypeSystem];
    g_stationPicker.frame = CGRectMake(8, 48, pw - 16, 30);
    [g_stationPicker setTitle:@"▼ 选择站点" forState:UIControlStateNormal];
    [g_stationPicker setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    g_stationPicker.titleLabel.font = [UIFont systemFontOfSize:11];
    g_stationPicker.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    g_stationPicker.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    g_stationPicker.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    g_stationPicker.backgroundColor = [UIColor colorWithRed:0.2 green:0.45 blue:0.85 alpha:1];
    g_stationPicker.layer.cornerRadius = 6;
    g_stationPicker.enabled = NO;
    [g_stationPicker addTarget:[SecToggleHandler shared]
                        action:@selector(onPickStation:)
              forControlEvents:UIControlEventTouchUpInside];
    [g_mainBox addSubview:g_stationPicker];

    g_modeControl = [[UISegmentedControl alloc] initWithItems:@[@"手动", @"全自动"]];
    g_modeControl.frame = CGRectMake(8, 80, pw - 16, 28);
    g_modeControl.selectedSegmentIndex = 0;
    if (@available(iOS 13.0, *)) {
        g_modeControl.selectedSegmentTintColor = [UIColor colorWithRed:0.2 green:0.45 blue:0.85 alpha:1];
    }
    [g_modeControl addTarget:[SecToggleHandler shared]
                      action:@selector(onModeChange:)
            forControlEvents:UIControlEventValueChanged];
    [g_mainBox addSubview:g_modeControl];

    UIView *logBg = [[UIView alloc] initWithFrame:CGRectMake(6, 106, pw - 12, ph - 112)];
    logBg.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
    logBg.layer.cornerRadius = 6;
    [g_mainBox addSubview:logBg];

    UILabel *logTitle = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, pw - 28, 14)];
    logTitle.text = @"日志";
    logTitle.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    logTitle.font = [UIFont systemFontOfSize:9];
    [logBg addSubview:logTitle];

    g_logLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 18, pw - 24, ph - 130)];
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
    [win bringSubviewToFront:g_floatingIcon];
    SecSetPanelVisible(g_panelVisible);
    SecSetIconVisible(g_iconVisible);
    if (!g_deviceUUID.length) g_deviceUUID = [SecDeviceID keychainDeviceUUID];
    SecUpdateLicenseUI();
    SecPanelLog(g_licensed ? @"SEC 已就绪" : @"未授权，请复制 UUID 发码");
}

@implementation SecToggleHandler {
    CGPoint _panStart;
    CGPoint _iconPanStart;
}

+ (instancetype)shared {
    static SecToggleHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [SecToggleHandler new]; });
    return h;
}

- (void)onToggle:(UISwitch *)sender {
    g_licensed = [SecDeviceID isLicensed];
    if (!g_licensed) {
        sender.on = NO;
        g_enabled = NO;
        SecUpdateLicenseUI();
        SecPanelLog(@"未授权或已过期，请重新发码");
        return;
    }
    g_enabled = sender.isOn;
    SecPanelLog(g_enabled
                ? (g_autoMode ? @"已开启 · 全自动" : @"已开启 · 手动")
                : @"已关闭");
    SecUpdateStatusLabel();
    SecUpdateStationPicker();
    if (g_enabled && g_stations.count) {
        SecApplyDriveMode(YES);
        SecUpdateStationPicker();
        SecStartGpsPulse();
        if (!g_taskBcmxdh.length || !g_dealTaskTarget) {
            SecCollectTaskIdsFromUI();
        }
    } else {
        SecStopGpsPulse();
        g_routeActive = NO;
        g_routeFinished = NO;
    }
}

- (void)onModeChange:(UISegmentedControl *)sender {
    g_autoMode = sender.selectedSegmentIndex == 1;
    SecPanelLog(@"模式：%@", g_autoMode ? @"全自动" : @"手动");
    SecUpdateStatusLabel();
    if (g_enabled && g_stations.count) SecApplyDriveMode(YES);
    SecUpdateStationPicker();
}

- (void)onPickStation:(id)sender {
    if (!g_licensed) {
        SecDebugLog(@"未授权，请先激活");
        return;
    }
    if (g_stations.count == 0) {
        SecPanelLog(@"暂无站点，请先打开任务详情");
        return;
    }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"选择站点（按时间顺序）"
                                                              message:nil
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    // ActionSheet 先加的项在底部，倒序添加使显示顺序与 sortTime 一致（早→晚 从上到下）
    for (NSInteger i = (NSInteger)g_stations.count - 1; i >= 0; i--) {
        NSInteger idx = i;
        NSDictionary *s = g_stations[(NSUInteger)i];
        NSString *label = SecStationListTitle(s);
        UIAlertAction *action = [UIAlertAction actionWithTitle:label
                                                           style:UIAlertActionStyleDefault
                                                         handler:^(UIAlertAction *a) {
            SecSelectStationAtIndex((NSInteger)idx);
            SecPanelLog(@"已选：%@", SecStationTitle(s));
        }];
        [ac addAction:action];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *vc = SecPresenterVC();
    if (!vc) {
        SecDebugLog(@"无法弹出站点列表");
        return;
    }
    UIPopoverPresentationController *pop = ac.popoverPresentationController;
    if (pop && g_stationPicker) {
        pop.sourceView = g_stationPicker;
        pop.sourceRect = g_stationPicker.bounds;
    }
    [vc presentViewController:ac animated:YES completion:nil];
}

- (void)onIconTap:(id)sender {
    g_licensed = [SecDeviceID isLicensed];
    SecUpdateLicenseUI();
    SecSetPanelVisible(!g_panelVisible);
    SecDebugLog(g_panelVisible ? @"面板已显示" : @"面板已隐藏");
}

- (void)onIconPan:(UIPanGestureRecognizer *)g {
    if (!g_floatingIcon) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _iconPanStart = g_floatingIcon.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:g_floatingIcon.superview];
        g_floatingIcon.center = CGPointMake(_iconPanStart.x + t.x, _iconPanStart.y + t.y);
    }
}

- (void)onThreeFingerTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateRecognized) return;
    SecSetIconVisible(!g_iconVisible);
    SecDebugLog(g_iconVisible ? @"图标已显示" : @"图标已隐藏");
}

- (void)onCopyUUID:(id)sender {
    if (!g_deviceUUID.length) g_deviceUUID = [SecDeviceID keychainDeviceUUID];
    if (!g_deviceUUID.length) {
        SecDebugLog(@"UUID 读取失败");
        return;
    }
    [UIPasteboard generalPasteboard].string = g_deviceUUID;
    if (g_licensed) {
        SecDebugLog(@"已复制 UUID");
        return;
    }
    UIAlertController *tip = [UIAlertController alertControllerWithTitle:nil
                                                                 message:@"已复制 UUID"
                                                          preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *vc = SecPresenterVC();
    if (!vc) return;
    [vc presentViewController:tip animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [tip dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

- (void)onActivate:(id)sender {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"输入激活码"
                                                                message:@"格式 XXXX-XXXX-XXXX-XXXX-YYYYMMDD"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"激活码";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        NSString *saved = [SecDeviceID savedActivationCode];
        if (saved.length) tf.text = saved;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"激活" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *code = ac.textFields.firstObject.text;
        if (SecTryActivate(code)) return;
        SecDebugLog(@"激活码无效");
        UIAlertController *err = [UIAlertController alertControllerWithTitle:@"激活码无效"
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [err addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *vc = SecPresenterVC();
        if (vc) [vc presentViewController:err animated:YES completion:nil];
    }]];
    UIViewController *vc = SecPresenterVC();
    if (!vc) {
        SecDebugLog(@"无法弹出激活框");
        return;
    }
    [vc presentViewController:ac animated:YES completion:nil];
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
static CLLocation *(*orig_managerLocation)(id, SEL);

static CLLocationCoordinate2D hook_coord(id self, SEL _cmd) {
    double lat, lon;
    if (SecActiveGpsCoords(&lat, &lon)) {
        CLLocationCoordinate2D c;
        c.latitude = lat;
        c.longitude = lon;
        return c;
    }
    return orig_coord(self, _cmd);
}

static double hook_latitude(id self, SEL _cmd) {
    double lat, lon;
    if (SecActiveGpsCoords(&lat, &lon)) return lat;
    return orig_latitude(self, _cmd);
}

static double hook_longitude(id self, SEL _cmd) {
    double lat, lon;
    if (SecActiveGpsCoords(&lat, &lon)) return lon;
    return orig_longitude(self, _cmd);
}

static CLLocation *hook_managerLocation(id self, SEL _cmd) {
    CLLocation *fake = SecFakeLocation();
    if (fake) return fake;
    return orig_managerLocation(self, _cmd);
}

static void (*orig_setBody)(id, SEL, NSData *);

static void hook_setBody(id self, SEL _cmd, NSData *body) {
    if (body.length > 0 && body.length < 65536 && g_enabled && g_stations.count) {
        NSString *raw = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (raw) {
            NSMutableURLRequest *req = (NSMutableURLRequest *)self;
            NSString *url = req.URL.absoluteString;
            if ([url containsString:@"/app/sjb/v1"] &&
                (SecShouldPatchRequestURL(url) || SecBodyLooksLikeGps(raw))) {
                NSString *patched = PatchJsonForRequest(raw, url);
                if (![patched isEqualToString:raw]) {
                    body = [patched dataUsingEncoding:NSUTF8StringEncoding];
                    SecDebugLog(@"改包 %@", SecShortURL(url));
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
    if (g_hooksInstalled) return;
    if (!g_licensed) return;
    g_hooksInstalled = YES;

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

    Method mLoc = class_getInstanceMethod([CLLocationManager class], @selector(location));
    if (mLoc) {
        orig_managerLocation = (CLLocation *(*)(id, SEL))method_getImplementation(mLoc);
        method_setImplementation(mLoc, (IMP)hook_managerLocation);
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

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SecInstallDealTaskHooks();
        SecInstallStayedHooks();
        SecInstallPlateHooks();
        dispatch_async(dispatch_get_main_queue(), ^{
            SecDebugLog(@"业务 Hook 就绪");
        });
    });

    SecDebugLog(@"Hooks 安装完成");
}

#pragma mark - 入口

__attribute__((constructor))
static void SecToggleEntry(void) {
    g_deviceUUID = [SecDeviceID keychainDeviceUUID];
    g_licensed = [SecDeviceID isLicensed];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_licensed) SecInstallHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SecEnsureUI();
        });
    });
}
