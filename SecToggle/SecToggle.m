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
static void SecPanelLog(NSString *format, ...);
static NSString *SecStationTitle(NSDictionary *t);
static NSString *SecStationListTitle(NSDictionary *t);
static UIViewController *SecPresenterVC(void);
static NSString *SecShortURL(NSString *url);
static void SecSelectStationAtIndex(NSInteger idx);
static void SecRefreshFakeLocation(void);
static void SecStartGpsPulse(void);
static void SecStopGpsPulse(void);
static void SecBuildRoute(void);
static void SecSeekRouteToStation(NSInteger idx);
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
static NSString *g_selectedZddm = nil;
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
static NSUInteger g_routeIndex = 0;
static BOOL g_routeActive = NO;
static BOOL g_routeFinished = NO;
static const double kSecRouteStepM = 25.0;
static const double kSecDriveSpeedMinMS = 40.0 / 3.6;
static const double kSecDriveSpeedMaxMS = 60.0 / 3.6;
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
                changed = YES;
                break;
            }
        }
        if (!exists) {
            NSMutableDictionary *entry = [@{@"key":key, @"zddm":zddm, @"name":name,
                                            @"jd":@(lon), @"wd":@(lat), @"queue":@(queue),
                                            @"zdbj":@(zdbj > 0 ? zdbj : 35)} mutableCopy];
            if (!isnan(sortTime)) entry[@"sortTime"] = @(sortTime);
            [g_stations addObject:entry];
            if (g_stations.count <= 12) {
                SecPanelLog(@"解析站点 %@", SecStationTitle(entry));
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
                if (g_enabled && g_stations.count >= 2) SecBuildRoute();
            });
        }
    }
    for (id k in dict) ExtractStationsFromObject(dict[k], depth + 1);
}

static NSDictionary *DisplayStation(void) {
    if (g_stations.count == 0) return nil;
    NSInteger idx = g_stationIndex;
    if (idx < 0 || idx >= (NSInteger)g_stations.count) idx = 0;
    return g_stations[idx];
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

static void SecRouteSyncStationIndex(void) {
    if (g_stations.count <= 1) {
        g_stationIndex = 0;
        return;
    }
    for (NSUInteger leg = 0; leg < g_routeLegEnds.count; leg++) {
        if (g_routeIndex <= [g_routeLegEnds[leg] unsignedIntegerValue]) {
            g_stationIndex = (NSInteger)(leg + 1);
            return;
        }
    }
    g_stationIndex = (NSInteger)g_stations.count - 1;
}

static void SecBuildRoute(void) {
    if (!g_routePoints) g_routePoints = [NSMutableArray array];
    if (!g_routeLegEnds) g_routeLegEnds = [NSMutableArray array];
    [g_routePoints removeAllObjects];
    [g_routeLegEnds removeAllObjects];
    g_routeFinished = NO;

    if (g_stations.count == 0) {
        g_routeActive = NO;
        return;
    }
    if (g_stations.count == 1) {
        NSDictionary *s = g_stations[0];
        SecRouteAppendPoint([s[@"wd"] doubleValue], [s[@"jd"] doubleValue]);
        g_routeIndex = 0;
        g_stationIndex = 0;
        g_routeActive = g_enabled;
        return;
    }

    for (NSUInteger i = 0; i < g_stations.count - 1; i++) {
        NSDictionary *a = g_stations[i];
        NSDictionary *b = g_stations[i + 1];
        double lat1 = [a[@"wd"] doubleValue];
        double lon1 = [a[@"jd"] doubleValue];
        double lat2 = [b[@"wd"] doubleValue];
        double lon2 = [b[@"jd"] doubleValue];
        if (i == 0) SecRouteAppendPoint(lat1, lon1);
        SecRouteAppendLeg(lat1, lon1, lat2, lon2);
        [g_routeLegEnds addObject:@(g_routePoints.count - 1)];
    }

    g_routeIndex = 0;
    SecRouteSyncStationIndex();
    g_routeActive = g_enabled && g_routePoints.count > 1;
    if (g_routeActive) {
        double km = 0;
        for (NSUInteger i = 1; i < g_routePoints.count; i++) {
            km += SecHaversineM([g_routePoints[i-1][0] doubleValue], [g_routePoints[i-1][1] doubleValue],
                                [g_routePoints[i][0] doubleValue], [g_routePoints[i][1] doubleValue]);
        }
        SecPanelLog(@"路线规划 %.1fkm %lu站", km / 1000.0, (unsigned long)g_stations.count);
    }
}

static void SecSeekRouteToStation(NSInteger idx) {
    if (!g_routePoints.count) return;
    if (idx <= 0) {
        g_routeIndex = 0;
    } else if (idx - 1 < (NSInteger)g_routeLegEnds.count) {
        g_routeIndex = (idx == 1) ? 0 : [g_routeLegEnds[idx - 2] unsignedIntegerValue];
    } else {
        g_routeIndex = g_routePoints.count - 1;
    }
    g_routeFinished = NO;
    SecRouteSyncStationIndex();
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
            NSDictionary *t = DisplayStation();
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
        SecPanelLog(@"到达改包 %@", SecStationTitle(t));
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
    g_selectedZddm = [g_stations[idx][@"zddm"] description];
    if (g_routePoints.count >= 2) {
        SecSeekRouteToStation(idx);
    } else {
        g_stationIndex = idx;
        if (g_enabled && g_stations.count >= 2) SecBuildRoute();
        if (g_routePoints.count >= 2) SecSeekRouteToStation(idx);
    }
    SecRefreshFakeLocation();
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
        SecRouteSyncStationIndex();

        for (NSUInteger leg = 0; leg < g_routeLegEnds.count; leg++) {
            NSUInteger endIdx = [g_routeLegEnds[leg] unsignedIntegerValue];
            if (prev < endIdx && g_routeIndex >= endIdx && leg + 1 < g_stations.count) {
                SecPanelLog(@"途经 %@", SecStationTitle(g_stations[leg + 1]));
            }
        }

        if (g_routeIndex >= g_routePoints.count - 1) {
            g_routeFinished = YES;
            SecPanelLog(@"到达 %@", SecStationTitle(DisplayStation()));
        } else if (g_routeIndex != prev) {
            NSDictionary *dest = DisplayStation();
            NSArray *cur = g_routePoints[g_routeIndex];
            double remain = 0;
            for (NSUInteger i = g_routeIndex + 1; i < g_routePoints.count; i++) {
                remain += SecHaversineM([cur[0] doubleValue], [cur[1] doubleValue],
                                        [g_routePoints[i][0] doubleValue], [g_routePoints[i][1] doubleValue]);
                cur = g_routePoints[i];
            }
            SecPanelLog(@"行驶→%@ 剩%.1fkm", SecStationTitle(dest), remain / 1000.0);
        }
        return;
    }

    NSDictionary *t = DisplayStation();
    if (!t) return;
    double lat, lon;
    SecSpoofedCoords(t, &lat, &lon, YES);
    double baseLat = [t[@"wd"] doubleValue];
    double baseLon = [t[@"jd"] doubleValue];
    double cosLat = cos(baseLat * M_PI / 180.0);
    if (fabs(cosLat) < 0.01) cosLat = 0.01;
    double dLatM = (lat - baseLat) * 111320.0;
    double dLonM = (lon - baseLon) * 111320.0 * cosLat;
    double distM = sqrt(dLatM * dLatM + dLonM * dLonM);
    SecPanelLog(@"GPS漂移 %@ ~%.0fm", SecStationTitle(t), distM);
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
        SecPanelLog(@"Hook handleWhenStayedTimerFired ← %@", NSStringFromClass(classes[i]));
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
    g_statusLabel.text = [NSString stringWithFormat:@"[%@] 共 %lu 站%@",
                          g_enabled ? @"ON" : @"OFF",
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
    NSString *expiry = SecLicenseExpiryFromCode(trimmed);
    if (expiry.length && SecLicenseIsExpired(expiry)) return NO;
    if (!SecLicenseVerify(g_deviceUUID, trimmed, kSecLicenseDefaultSecret)) return NO;
    NSString *formatted = SecLicenseCanonicalCode(trimmed);
    if (!formatted.length) return NO;
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
    g_licenseBox.hidden = licensed;
    g_mainBox.hidden = !licensed;
    if (g_toggleSwitch) g_toggleSwitch.enabled = licensed;
    if (g_stationPicker) g_stationPicker.enabled = licensed && g_stations.count > 0;
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

    UILabel *licHint = [[UILabel alloc] initWithFrame:CGRectMake(8, 26, pw - 16, 28)];
    licHint.text = @"复制下方 UUID 到 Windows 发码工具，再点「输入激活码」";
    licHint.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    licHint.font = [UIFont systemFontOfSize:9];
    licHint.numberOfLines = 2;
    [g_licenseBox addSubview:licHint];

    g_licenseUuidLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 56, pw - 16, 34)];
    g_licenseUuidLabel.textColor = [UIColor colorWithRed:0.55 green:0.85 blue:1.0 alpha:1];
    g_licenseUuidLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    g_licenseUuidLabel.numberOfLines = 2;
    g_licenseUuidLabel.lineBreakMode = NSLineBreakByCharWrapping;
    [g_licenseBox addSubview:g_licenseUuidLabel];

    g_licenseShortLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 92, pw - 16, 14)];
    g_licenseShortLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1];
    g_licenseShortLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightMedium];
    [g_licenseBox addSubview:g_licenseShortLabel];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(8, 112, (pw - 22) / 2.0, 32);
    [copyBtn setTitle:@"复制 UUID" forState:UIControlStateNormal];
    [copyBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    copyBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.45 blue:0.85 alpha:1];
    copyBtn.layer.cornerRadius = 6;
    [copyBtn addTarget:[SecToggleHandler shared] action:@selector(onCopyUUID:) forControlEvents:UIControlEventTouchUpInside];
    [g_licenseBox addSubview:copyBtn];

    UIButton *actBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    actBtn.frame = CGRectMake(14 + (pw - 22) / 2.0, 112, (pw - 22) / 2.0, 32);
    [actBtn setTitle:@"输入激活码" forState:UIControlStateNormal];
    [actBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    actBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    actBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.55 blue:0.28 alpha:1];
    actBtn.layer.cornerRadius = 6;
    [actBtn addTarget:[SecToggleHandler shared] action:@selector(onActivate:) forControlEvents:UIControlEventTouchUpInside];
    [g_licenseBox addSubview:actBtn];

    UIView *licLogBg = [[UIView alloc] initWithFrame:CGRectMake(6, 152, pw - 12, ph - 158)];
    licLogBg.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
    licLogBg.layer.cornerRadius = 6;
    [g_licenseBox addSubview:licLogBg];

    UILabel *licLog = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, pw - 28, ph - 170)];
    licLog.text = @"IDFV 仅参考；发码以 UUID 为准。抹机后需重新发码。";
    licLog.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    licLog.font = [UIFont systemFontOfSize:9];
    licLog.numberOfLines = 0;
    [licLogBg addSubview:licLog];

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
    g_stationPicker.frame = CGRectMake(8, 48, pw - 16, 34);
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

    UIView *logBg = [[UIView alloc] initWithFrame:CGRectMake(6, 88, pw - 12, ph - 94)];
    logBg.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
    logBg.layer.cornerRadius = 6;
    [g_mainBox addSubview:logBg];

    UILabel *logTitle = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, pw - 28, 14)];
    logTitle.text = @"日志";
    logTitle.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    logTitle.font = [UIFont systemFontOfSize:9];
    [logBg addSubview:logTitle];

    g_logLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 18, pw - 24, ph - 112)];
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
    SecPanelLog(g_licensed ? @"悬浮窗已显示（路线行驶）" : @"未授权，请复制 UUID 发码");
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
    SecPanelLog(@"开关 %@", g_enabled ? @"ON" : @"OFF");
    SecUpdateStatusLabel();
    SecUpdateStationPicker();
    if (g_enabled && g_stations.count) {
        SecBuildRoute();
        SecRefreshFakeLocation();
        NSDictionary *t = DisplayStation();
        if (t) {
            SecPanelLog(@"GPS→%@", SecStationTitle(t));
        }
        SecStartGpsPulse();
        if (!g_taskBcmxdh.length || !g_dealTaskTarget) {
            SecCollectTaskIdsFromUI();
            if (g_taskBcmxdh.length) SecPanelLog(@"bcmxdh %@", g_taskBcmxdh);
            if (g_dealTaskTarget) SecPanelLog(@"已缓存 service");
        }
    } else {
        SecStopGpsPulse();
        g_routeActive = NO;
        g_routeFinished = NO;
    }
}

- (void)onPickStation:(id)sender {
    if (!g_licensed) {
        SecPanelLog(@"未授权，请先激活");
        return;
    }
    if (g_stations.count == 0) {
        SecPanelLog(@"暂无站点，请先打开任务详情");
        return;
    }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"选择站点（按时间顺序）"
                                                              message:nil
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < g_stations.count; i++) {
        NSUInteger idx = i;
        NSDictionary *s = g_stations[i];
        NSString *label = SecStationListTitle(s);
        UIAlertAction *action = [UIAlertAction actionWithTitle:label
                                                           style:UIAlertActionStyleDefault
                                                         handler:^(UIAlertAction *a) {
            SecSelectStationAtIndex((NSInteger)idx);
            SecPanelLog(@"切换 → %@", SecStationTitle(s));
        }];
        [ac addAction:action];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *vc = SecPresenterVC();
    if (!vc) {
        SecPanelLog(@"无法弹出站点列表");
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
    SecPanelLog(g_panelVisible ? @"面板已显示" : @"面板已隐藏");
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
    SecPanelLog(g_iconVisible ? @"图标已显示" : @"图标已隐藏");
}

- (void)onCopyUUID:(id)sender {
    if (!g_deviceUUID.length) g_deviceUUID = [SecDeviceID keychainDeviceUUID];
    if (!g_deviceUUID.length) {
        SecPanelLog(@"UUID 读取失败");
        return;
    }
    [UIPasteboard generalPasteboard].string = g_deviceUUID;
    if (g_licensed) {
        SecPanelLog(@"已复制 UUID");
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
        SecPanelLog(@"激活码无效或已过期");
        UIAlertController *err = [UIAlertController alertControllerWithTitle:@"激活失败"
                                                                     message:@"请核对 UUID、密钥，或确认激活码未过期"
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [err addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *vc = SecPresenterVC();
        if (vc) [vc presentViewController:err animated:YES completion:nil];
    }]];
    UIViewController *vc = SecPresenterVC();
    if (!vc) {
        SecPanelLog(@"无法弹出激活框");
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
        dispatch_async(dispatch_get_main_queue(), ^{
            SecPanelLog(@"业务 Hook 就绪");
        });
    });

    SecPanelLog(@"Hooks 安装完成");
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
