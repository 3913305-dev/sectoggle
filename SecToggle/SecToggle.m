/**
 * SecToggle.dylib — 悬浮开关「远程自动到达」
 * 注入目标：XiangPostDriver (com.copote.yygk.app.driver)
 * 授权安全测试用途
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

void SecUpdateStatusLabel(void);

@interface SecToggleHandler : NSObject
+ (instancetype)shared;
- (void)onToggle:(UISwitch *)sender;
- (void)onNext:(id)sender;
- (void)onArrive:(id)sender;
- (void)onPan:(UIPanGestureRecognizer *)g;
@end

#pragma mark - 状态

static BOOL g_enabled = NO;
static NSMutableArray *g_stations = nil; // @{@"zddm",@"name",@"jd",@"wd"}
static NSInteger g_stationIndex = 0;
static UIView *g_panel = nil;
static UILabel *g_statusLabel = nil;

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

    id jd = dict[@"n_zdjd"] ?: dict[@"n_jd"];
    id wd = dict[@"n_zdwd"] ?: dict[@"n_wd"];
    double lon = ParseDouble(jd);
    double lat = ParseDouble(wd);
    NSString *zddm = [dict[@"c_zddm"] ?: dict[@"zddm"] ?: @"" description];
    NSString *name = [dict[@"c_zdmc"] ?: dict[@"c_zdjmc"] ?: @"" description];

    if (!isnan(lon) && !isnan(lat) && (lon != 0 || lat != 0)) {
        NSString *key = [NSString stringWithFormat:@"%@@%f,%f", zddm, lon, lat];
        BOOL exists = NO;
        for (NSDictionary *s in g_stations) {
            if ([s[@"key"] isEqualToString:key]) { exists = YES; break; }
        }
        if (!exists) {
            [g_stations addObject:@{@"key":key, @"zddm":zddm, @"name":name,
                                    @"jd":@(lon), @"wd":@(lat)}];
            NSLog(@"[SecToggle] 站点 %@ %@ wd=%f jd=%f", zddm, name, lat, lon);
            dispatch_async(dispatch_get_main_queue(), ^{
                extern void SecUpdateStatusLabel(void);
                SecUpdateStatusLabel();
            });
        }
    }
    for (id k in dict) ExtractStationsFromObject(dict[k], depth + 1);
}

static NSDictionary *CurrentTarget(void) {
    if (!g_enabled || g_stations.count == 0) return nil;
    return g_stations[g_stationIndex % g_stations.count];
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

#pragma mark - UI

void SecUpdateStatusLabel(void) {
    if (!g_statusLabel) return;
    NSDictionary *t = g_stations.count ? g_stations[g_stationIndex % g_stations.count] : nil;
    if (!t) {
        g_statusLabel.text = @"站点: 请先打开任务详情";
        return;
    }
    g_statusLabel.text = [NSString stringWithFormat:@"[%@] %ld/%lu %@\nwd=%.6f jd=%.6f",
                          g_enabled ? @"ON" : @"OFF",
                          (long)(g_stationIndex+1), (unsigned long)g_stations.count,
                          t[@"zddm"], [t[@"wd"] doubleValue], [t[@"jd"] doubleValue]];
}

static void SecCreatePanel(void) {
    if (g_panel) return;
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.hidden && w.alpha > 0) { win = w; break; }
    }
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SecCreatePanel();
        });
        return;
    }

    CGFloat pw = 280, ph = 148;
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(20, 120, pw, ph)];
    g_panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    g_panel.layer.cornerRadius = 10;
    g_panel.userInteractionEnabled = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, 170, 20)];
    title.text = @"SEC 远程自动到达";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:13];
    [g_panel addSubview:title];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(pw-60, 2, 51, 31)];
    [sw addTarget:[SecToggleHandler shared] action:@selector(onToggle:) forControlEvents:UIControlEventValueChanged];
    [g_panel addSubview:sw];

    g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 30, pw-16, 42)];
    g_statusLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    g_statusLabel.font = [UIFont systemFontOfSize:11];
    g_statusLabel.numberOfLines = 0;
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

    UIButton *btnGo = [UIButton buttonWithType:UIButtonTypeSystem];
    btnGo.frame = CGRectMake(136, 88, 136, 34);
    [btnGo setTitle:@"标记已到达" forState:UIControlStateNormal];
    [btnGo setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btnGo.backgroundColor = [UIColor colorWithRed:0.15 green:0.65 blue:0.35 alpha:1];
    btnGo.layer.cornerRadius = 6;
    [btnGo addTarget:[SecToggleHandler shared] action:@selector(onArrive:) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:btnGo];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[SecToggleHandler shared] action:@selector(onPan:)];
    [g_panel addGestureRecognizer:pan];

    [win addSubview:g_panel];
    [win bringSubviewToFront:g_panel];
    NSLog(@"[SecToggle] 悬浮窗已显示");
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
- (void)onNext:(id)sender { NextStation(); }
- (void)onArrive:(id)sender {
    if (!g_stations.count) return;
    if (!g_enabled) return;
    NSDictionary *t = CurrentTarget();
    NSLog(@"[SecToggle] 目标站 %@ 坐标已注入，请在 App 点到达/签到", t[@"zddm"]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NextStation();
    });
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
    NSDictionary *t = CurrentTarget();
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

    Method m1 = class_getInstanceMethod([CLLocation class], @selector(coordinate));
    if (m1) {
        orig_coord = (CLLocationCoordinate2D (*)(id, SEL))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)(void *)hook_coord);
    }

    Method m2 = class_getInstanceMethod([NSMutableURLRequest class], @selector(setHTTPBody:));
    if (m2) {
        orig_setBody = (void (*)(id, SEL, NSData *))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)(void *)hook_setBody);
    }

    Method m3 = class_getClassMethod([NSJSONSerialization class], @selector(JSONObjectWithData:options:error:));
    if (m3) {
        orig_jsonData = (id (*)(id, SEL, NSData *, NSJSONReadingOptions, NSError **))method_getImplementation(m3);
        method_setImplementation(m3, (IMP)(void *)hook_jsonData);
    }

    NSLog(@"[SecToggle] Hooks 安装完成");
}

#pragma mark - 入口

__attribute__((constructor))
static void SecToggleEntry(void) {
    SecInstallHooks();
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SecCreatePanel();
        });
    });
}
