package com.copote.yygk.app.mine.ui.helper;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import com.blankj.utilcode.util.SPUtils;
import com.copote.yygk.task.bean.CurrentTaskResult.DataBean.PbrwBean.RwzxListBean;
import com.tencent.map.geolocation.TencentLocationListener;
import com.tencent.map.geolocation.TencentLocationRequest;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;
import java.util.Locale;
import java.util.Random;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public final class LocationBypassHelper {
    public static final String SP_NAME = "location_bypass";
    public static final String KEY_ENABLED = "enabled";
    public static final String KEY_AUTO_MODE = "auto_mode";
    /** 兼容旧版 patch 开关名，UI 不再展示。 */
    public static final String KEY_SIGN = "feat_sign";
    public static final String KEY_AUTO_CHECK = "feat_auto_check";
    public static final String KEY_STATION = "feat_station";
    public static final String KEY_STATION_AUTO = "feat_station_auto";
    public static final String KEY_POSITION = "feat_position";
    public static final String KEY_CLOCK = "feat_clock";
    public static final String KEY_LAT = "lat";
    public static final String KEY_LNG = "lng";
    public static final String KEY_ZDDM = "zddm";
    public static final String KEY_USER_PICKED = "user_picked";
    public static final String KEY_STREET = "street_address";
    public static final String KEY_LICENSE_ACTIVATION = "license_activation";
    public static final String KEY_LICENSE_EXPIRY_YMD = "license_expiry_ymd";

    private static final int LICENSE_GATE_MAGIC = 0x5A3C0000;
    private static final int LICENSE_LANE_LAT = 0x4C41;
    private static final int LICENSE_LANE_LNG = 0x4C4E;
    private static final String DRIVER_SP = "XP_E6_DRIVER";
    private static final String DRIVER_KEY_USER_NAME = "userName";

    private static volatile int licenseTokenCache;
    private static volatile long licenseTokenAtMs;

    private static boolean bootstrapped;
    private static final double ROUTE_STEP_M = 25d;
    private static final double DRIVE_SPEED_MIN_MS = 60d / 3.6d;
    private static final double DRIVE_SPEED_MAX_MS = 80d / 3.6d;
    /** 围栏内随机偏移上限（相对站点中心，米） */
    private static final double FENCE_JITTER_MAX_M = 35d;
    private static final double FENCE_JITTER_MIN_M = 3d;
    /** 围栏内随机速度（m/s，与腾讯 SDK getSpeed 一致） */
    private static final int FENCE_SPEED_MIN_MS = 0;
    private static final int FENCE_SPEED_MAX_MS = 8;
    private static final long ROUTE_TICK_MS = 3000L;
    private static final long ACTION_ZDDM_MS = 30000L;
    private static final Object STATION_LOCK = new Object();
    private static final Random RANDOM = new Random();
    private static final Handler GPS_HANDLER = new Handler(Looper.getMainLooper());

    private static double lastTargetLat;
    private static double lastTargetLng;
    /** 腾讯 SDK 最近一次真实经纬度（定位开关上报用）。 */
    private static double lastReadLat;
    private static double lastReadLng;
    private static final ArrayList<StationSlot> stationSlots = new ArrayList<>();
    private static final ArrayList<double[]> routePoints = new ArrayList<>();
    private static final ArrayList<Integer> routeLegEnds = new ArrayList<>();
    private static final ArrayList<Integer> routeLegStationIdx = new ArrayList<>();

    private static boolean userPickedStation;
    private static String selectedZddm;
    private static int stationIndex = -1;
    private static int routeDestIndex = -1;
    private static int routeIndex;
    private static boolean routeActive;
    private static boolean routeFinished;
    private static int gpsPulseIndex;
    private static String actionZddm;
    private static long actionZddmUntil;
    private static String cachedCldm;
    private static boolean gpsPulseScheduled;
    private static boolean autoArrivalPending;
    /** 签到打卡点（与装卸站路线站分离）。 */
    private static double clockSiteLat;
    private static double clockSiteLng;
    private static int clockSiteRadiusM;
    private static double clockPickLat;
    private static double clockPickLng;
    private static boolean clockPickReady;
    private static long clockPickAtMs;
    private static String clockSiteAddress;

    private LocationBypassHelper() {
    }

    static final class StationSlot {
        String bcdh;
        int bcmxdh;
        String zddm;
        String name;
        String zdwz;
        double lat;
        double lng;
        double radiusM = 35d;
        boolean done;
        boolean origin;
    }

    private static final Runnable GPS_TICK = new Runnable() {
        @Override
        public void run() {
            onGpsPulseTick();
            if (gpsPulseScheduled && isMasterEnabled()) {
                GPS_HANDLER.postDelayed(this, ROUTE_TICK_MS);
            }
        }
    };

    public static boolean isMasterEnabled() {
        ensureBootstrapped();
        if (!licenseSpoofPermitted(true)) {
            return false;
        }
        return SPUtils.getInstance(SP_NAME).getBoolean(KEY_ENABLED, false);
    }

    public static void ensureBootstrapped() {
        if (bootstrapped) {
            return;
        }
        bootstrapped = true;
        restorePersistedTargetLocked();
    }

    public static boolean hasSpoofTargetAvailable() {
        ensureBootstrapped();
        if (!licenseSpoofPermitted(true)) {
            return false;
        }
        synchronized (STATION_LOCK) {
            return hasSpoofTargetAvailableLocked();
        }
    }

    public static String getCachedCldm() {
        return cachedCldm;
    }

    public static void setMasterEnabled(boolean enabled) {
        if (enabled && !licenseIsActive()) {
            LocationBypassLogHelper.log(
                    licenseBlockReason() != null ? licenseBlockReason() : "未激活，无法开启");
            LocationBypassOverlayHelper.refreshPanelUi();
            return;
        }
        SPUtils.getInstance(SP_NAME).put(KEY_ENABLED, enabled);
        if (enabled) {
            setAutoMode(false);
            applyDriveMode();
            startGpsPulse();
            LocationBypassGeocodeHelper.scheduleRefresh();
            LocationBypassStationFetchHelper.scheduleFetch();
            LocationBypassLogHelper.log("已关闭真实定位");
            if (!hasStationSelection()) {
                LocationBypassLogHelper.log("请先选择站点");
            }
        } else {
            stopGpsPulse();
            autoArrivalPending = false;
            LocationBypassGeocodeHelper.clear();
            LocationBypassGeocodeHelper.clearClock();
            LocationBypassFakeLocationHub.clear();
            clearClockSiteLocked();
            synchronized (STATION_LOCK) {
                routeActive = false;
                routeFinished = false;
            }
        }
        notifyLocationPipelineRestart();
        LocationBypassOverlayHelper.refreshPanelUi();
    }

    /** SEC 开关切换后，通知首页重新 bind 腾讯定位（ReportLocationService）。 */
    private static void notifyLocationPipelineRestart() {
        try {
            Class<?> eventClass = Class.forName("com.copote.yygk.common.event.RefreshMainEvent");
            Object event = eventClass.getConstructor(String.class).newInstance("sec_toggle");
            Class<?> busClass = Class.forName("org.greenrobot.eventbus.EventBus");
            Object bus = busClass.getMethod("getDefault").invoke(null);
            busClass.getMethod("post", Object.class).invoke(bus, event);
        } catch (Throwable ignored) {
        }
    }

    public static boolean isAutoMode() {
        return false;
    }

    public static void setAutoMode(boolean autoMode) {
        SPUtils.getInstance(SP_NAME).put(KEY_AUTO_MODE, autoMode);
        clearStationSelection();
        LocationBypassLogHelper.log("模式：" + (autoMode ? "全自动" : "手动"));
        if (isMasterEnabled()) {
            applyDriveMode();
            if (!hasStationSelection()) {
                LocationBypassLogHelper.log("请先选择站点");
            }
        }
        LocationBypassOverlayHelper.refreshPanelUi();
    }

    public static boolean isFeatureEnabled(String key) {
        return isMasterEnabled();
    }

    public static boolean getStoredFeatureEnabled(String key) {
        return isMasterEnabled();
    }

    public static void setFeatureEnabled(String key, boolean enabled) {
        setMasterEnabled(enabled);
    }

    public static boolean isEnabled() {
        return isMasterEnabled();
    }

    public static boolean isSignEnabled() {
        return isMasterEnabled();
    }

    public static boolean isAutoCheckEnabled() {
        return isMasterEnabled();
    }

    public static boolean isStationEnabled() {
        return isMasterEnabled();
    }

    public static boolean isStationAutoEnabled() {
        return isMasterEnabled();
    }

    public static boolean isPositionEnabled() {
        return isMasterEnabled();
    }

    public static boolean isClockEnabled() {
        return isMasterEnabled();
    }

    public static boolean isMyTaskEnabled() {
        return isMasterEnabled();
    }

    public static void bindActionZddm(String zddm) {
        if (zddm == null || zddm.length() == 0) {
            return;
        }
        synchronized (STATION_LOCK) {
            actionZddm = zddm;
            actionZddmUntil = System.currentTimeMillis() + ACTION_ZDDM_MS;
            StationSlot slot = stationForZddmLocked(zddm);
            if (slot != null) {
                LocationBypassLogHelper.log("按操作站 " + labelLocked(slot));
            }
        }
    }

    public static void rememberStation(RwzxListBean bean) {
        if (bean == null) {
            return;
        }
        synchronized (STATION_LOCK) {
            StationSlot slot = slotFromBean(bean, false);
            if (slot == null) {
                return;
            }
            bindActionZddm(slot.zddm);
            lastTargetLat = slot.lat;
            lastTargetLng = slot.lng;
            persistTargetToSpLocked();
        }
        LocationBypassGeocodeHelper.scheduleRefresh();
    }

    public static void rememberStationList(List list, String cldm) {
        if (cldm != null && cldm.length() > 0) {
            cachedCldm = cldm;
        }
        try {
            synchronized (STATION_LOCK) {
                String savedZddm = selectedZddm;
                stationSlots.clear();
                stationIndex = -1;
                routeDestIndex = -1;
                routeActive = false;
                routeFinished = false;
                routePoints.clear();
                routeLegEnds.clear();
                routeLegStationIdx.clear();
                routeIndex = 0;

                if (list != null) {
                    for (int i = 0; i < list.size(); i++) {
                        Object item = list.get(i);
                        if (!(item instanceof RwzxListBean)) {
                            continue;
                        }
                        RwzxListBean bean = (RwzxListBean) item;
                        boolean origin = i == 0;
                        StationSlot slot = slotFromBean(bean, origin);
                        if (slot == null) {
                            continue;
                        }
                        if (origin) {
                            slot.done = isAutoLeft(bean);
                        } else {
                            slot.done = isAutoArrived(bean);
                        }
                        stationSlots.add(slot);
                    }
                }

                if (savedZddm != null && savedZddm.length() > 0 && userPickedStation) {
                    int idx = indexForZddmLocked(savedZddm);
                    if (idx >= 0 && !stationSlots.get(idx).done) {
                        stationIndex = idx;
                        updateLastTargetFromIndexLocked(idx);
                    } else {
                        clearStationSelectionLocked();
                    }
                } else {
                    clearStationSelectionLocked();
                }

                if (stationSlots.isEmpty()) {
                    LocationBypassLogHelper.log("暂无站点，请先打开装卸站");
                } else if (isMasterEnabled()) {
                    if (!userPickedStation) {
                        int pending = earliestPendingIndexLocked();
                        if (pending >= 0) {
                            userPickedStation = true;
                            stationIndex = pending;
                            selectedZddm = stationSlots.get(pending).zddm;
                            updateLastTargetFromIndexLocked(pending);
                        }
                    }
                    if (lastTargetLat != 0d || lastTargetLng != 0d) {
                        persistTargetToSpLocked();
                    }
                    applyDriveModeLocked();
                }
            }
            LocationBypassOverlayHelper.refreshPanelUi();
        } catch (Throwable t) {
            LocationBypassLogHelper.log("站点队列失败: " + t.getClass().getSimpleName());
        }
        if (isMasterEnabled() && hasSpoofTargetAvailable()) {
            LocationBypassGeocodeHelper.scheduleRefresh();
            LocationBypassFakeLocationHub.redeliverAll();
        }
    }

    public static void onPositionReported(double lat, double lng) {
        LocationBypassReportDiagHelper.logPostCoords(lat, lng);
        if (!isMasterEnabled()) {
            return;
        }
        synchronized (STATION_LOCK) {
            if (routeActive && !routeFinished) {
                LocationBypassLogHelper.log(String.format(Locale.getDefault(),
                        "上报阶段 %.6f,%.6f", lat, lng));
            }
        }
    }

    public static boolean hasActiveStation() {
        return hasStationSelection();
    }

    public static boolean hasStationSelection() {
        synchronized (STATION_LOCK) {
            return userPickedStation && displayStationLocked() != null;
        }
    }

    public static int getStationCount() {
        synchronized (STATION_LOCK) {
            return stationSlots.size();
        }
    }

    public static int countPendingStations() {
        synchronized (STATION_LOCK) {
            int n = 0;
            for (StationSlot slot : stationSlots) {
                if (!slot.done) {
                    n++;
                }
            }
            return n;
        }
    }

    public static String getStatusText() {
        synchronized (STATION_LOCK) {
            if (stationSlots.isEmpty()) {
                return "请先打开装卸站";
            }
            int pending = countPendingStations();
            if (lastReadLat != 0d && lastReadLng != 0d) {
                return String.format(Locale.US, "[%s] 待到达 %d/%d · GPS %.6f,%.6f",
                        isMasterEnabled() ? "ON" : "OFF",
                        pending,
                        stationSlots.size(),
                        lastReadLat,
                        lastReadLng);
            }
            return String.format(Locale.getDefault(), "[%s] 待到达 %d/%d 站",
                    isMasterEnabled() ? "ON" : "OFF",
                    pending,
                    stationSlots.size());
        }
    }

    public static String getStationLabel(int index) {
        synchronized (STATION_LOCK) {
            return stationListTitleLocked(index);
        }
    }

    /** 下拉/选站按钮：优先显示站点名。 */
    public static String getStationPickerLabel(int index) {
        synchronized (STATION_LOCK) {
            if (index < 0 || index >= stationSlots.size()) {
                return "未知站点";
            }
            StationSlot slot = stationSlots.get(index);
            if (slot.name != null && slot.name.length() > 0) {
                return slot.name;
            }
            return stationTitleLocked(slot);
        }
    }

    static StationSlot resolveGeocodeStation() {
        synchronized (STATION_LOCK) {
            StationSlot slot = spoofTargetLocked();
            if (slot != null) {
                return slot;
            }
            return persistedTargetSlotLocked();
        }
    }

    static double roundTencentCoord(double value) {
        return Math.round(value * 1000000.0d) / 1000000.0d;
    }

    public static int getActiveStationIndex() {
        synchronized (STATION_LOCK) {
            return stationIndex;
        }
    }

    public static int getStationBcmxdh(int index) {
        synchronized (STATION_LOCK) {
            if (index < 0 || index >= stationSlots.size()) {
                return -1;
            }
            return stationSlots.get(index).bcmxdh;
        }
    }

    public static boolean isStationPending(int index) {
        synchronized (STATION_LOCK) {
            if (index < 0 || index >= stationSlots.size()) {
                return false;
            }
            return !stationSlots.get(index).done;
        }
    }

    public static void selectStationByIndex(int index) {
        if (!isMasterEnabled()) {
            LocationBypassLogHelper.log("请先开启总开关");
            return;
        }
        synchronized (STATION_LOCK) {
            if (index < 0 || index >= stationSlots.size()) {
                LocationBypassLogHelper.log("站点无效");
                return;
            }
            StationSlot slot = stationSlots.get(index);
            if (slot.done) {
                LocationBypassLogHelper.log("站点已完成: " + labelLocked(slot));
                return;
            }
            userPickedStation = true;
            stationIndex = index;
            selectedZddm = slot.zddm;
            applyDriveModeLocked();
            if (lastReadLat != 0d && lastReadLng != 0d) {
                LocationBypassLogHelper.log(String.format(Locale.US,
                        "已选 %s · 读取GPS %.6f,%.6f",
                        stationTitleLocked(slot), lastReadLat, lastReadLng));
            } else {
                LocationBypassLogHelper.log("已选：" + stationTitleLocked(slot) + "（等待GPS）");
            }
        }
        LocationBypassGeocodeHelper.scheduleRefresh();
        LocationBypassOverlayHelper.refreshPanelUi();
    }

    public static void clearStationSelection() {
        synchronized (STATION_LOCK) {
            clearStationSelectionLocked();
            persistTargetToSpLocked();
        }
        LocationBypassOverlayHelper.refreshPanelUi();
    }

    public static double pickLat(double real, double alt) {
        return pickCoord(real, alt, true);
    }

    public static double pickLng(double real, double alt) {
        return pickCoord(real, alt, false);
    }

    public static double pickLatSign(double real, double alt) {
        return pickCoord(real, alt, true);
    }

    public static double pickLngSign(double real, double alt) {
        return pickCoord(real, alt, false);
    }

    public static double pickLatAutoCheck(double real, double alt) {
        return pickCoord(real, alt, true);
    }

    public static double pickLngAutoCheck(double real, double alt) {
        return pickCoord(real, alt, false);
    }

    public static double pickLatMyTask(double real, double alt) {
        return pickCoord(real, alt, true);
    }

    public static double pickLngMyTask(double real, double alt) {
        return pickCoord(real, alt, false);
    }

    public static double pickLatStation(double real, double alt) {
        return pickCoord(real, alt, true);
    }

    public static double pickLngStation(double real, double alt) {
        return pickCoord(real, alt, false);
    }

    public static double pickLatPosition(double real, double alt) {
        return pickCoord(real, alt, true);
    }

    public static double pickLngPosition(double real, double alt) {
        return pickCoord(real, alt, false);
    }

    /** /car/position 的 n_sd：路线上随机行驶速度，围栏内随机低速或静止。 */
    public static int pickPositionSpeed(float realSpeed) {
        if (!isMasterEnabled()) {
            return (int) realSpeed;
        }
        synchronized (STATION_LOCK) {
            if (!hasSpoofTargetAvailableLocked()) {
                return (int) realSpeed;
            }
            gpsPulseIndex++;
            if (routeActive && !routeFinished) {
                return (int) Math.round(randomDriveSpeedMs());
            }
            return randomFenceSpeedInt();
        }
    }

    public static double pickLatClock(double real, double alt) {
        if (alt != 0d) {
            return pickCoord(real, alt, true);
        }
        if (isMasterEnabled() && clockSiteLat != 0d && clockSiteLng != 0d) {
            ensureClockPickLocked();
            return clockPickLat;
        }
        return pickCoord(real, 0d, true);
    }

    public static double pickLngClock(double real, double alt) {
        if (alt != 0d) {
            return pickCoord(real, alt, false);
        }
        if (isMasterEnabled() && clockSiteLat != 0d && clockSiteLng != 0d) {
            ensureClockPickLocked();
            return clockPickLng;
        }
        return pickCoord(real, 0d, false);
    }

    /** 签到列表返回后缓存打卡点坐标，供签到页距离判断与上报。 */
    public static void rememberClockSiteFromList(List list) {
        if (list == null || list.isEmpty()) {
            return;
        }
        try {
            Object item = list.get(0);
            if (item == null) {
                return;
            }
            Class<?> cls = Class.forName("com.copote.yygk.clockIn.bean.SiteListResult$DataBean");
            Object latObj = cls.getMethod("getDkddwd").invoke(item);
            Object lngObj = cls.getMethod("getDkddjd").invoke(item);
            Object radiusObj = cls.getMethod("getDkddbj").invoke(item);
            Object addrObj = cls.getMethod("getDkdd").invoke(item);
            if (!(latObj instanceof Double) || !(lngObj instanceof Double)) {
                return;
            }
            double lat = (Double) latObj;
            double lng = (Double) lngObj;
            if (lat == 0d && lng == 0d) {
                return;
            }
            int radius = 200;
            if (radiusObj instanceof Integer) {
                radius = (Integer) radiusObj;
            }
            String siteAddr = addrObj instanceof String ? (String) addrObj : null;
            synchronized (STATION_LOCK) {
                clockSiteLat = lat;
                clockSiteLng = lng;
                clockSiteRadiusM = radius > 0 ? radius : 200;
                clockSiteAddress = siteAddr != null && siteAddr.length() > 0 ? siteAddr : null;
                clockPickReady = false;
            }
            LocationBypassGeocodeHelper.scheduleClockRefresh();
            LocationBypassLogHelper.log("已缓存打卡点");
        } catch (Throwable t) {
            LocationBypassLogHelper.log("打卡点缓存失败: " + t.getClass().getSimpleName());
        }
    }

    private static void clearClockSiteLocked() {
        clockSiteLat = 0d;
        clockSiteLng = 0d;
        clockSiteRadiusM = 0;
        clockSiteAddress = null;
        clockPickReady = false;
    }

    static String clockSiteAddressText() {
        synchronized (STATION_LOCK) {
            return clockSiteAddress != null ? clockSiteAddress : "";
        }
    }

    static double peekClockPickLat() {
        synchronized (STATION_LOCK) {
            if (clockSiteLat == 0d && clockSiteLng == 0d) {
                return 0d;
            }
            ensureClockPickLocked();
            return clockPickLat;
        }
    }

    static double peekClockPickLng() {
        synchronized (STATION_LOCK) {
            if (clockSiteLat == 0d && clockSiteLng == 0d) {
                return 0d;
            }
            ensureClockPickLocked();
            return clockPickLng;
        }
    }

    /** 签到页地址：优先圈内逆地理/打卡点 dkdd，避免显示真实街道。 */
    public static String pickClockDisplayAddress(String realAddress) {
        if (!isMasterEnabled()) {
            return realAddress != null ? realAddress : "";
        }
        synchronized (STATION_LOCK) {
            if (clockSiteLat == 0d && clockSiteLng == 0d) {
                return realAddress != null ? realAddress : "";
            }
            ensureClockPickLocked();
        }
        LocationBypassGeocodeHelper.scheduleClockRefresh();
        return LocationBypassGeocodeHelper.resolveClockAddress(realAddress);
    }

    private static void ensureClockPickLocked() {
        synchronized (STATION_LOCK) {
            long now = System.currentTimeMillis();
            if (clockPickReady && now - clockPickAtMs < 3000L) {
                return;
            }
            double[] out = new double[2];
            applyClockSiteJitterLocked(out);
            clockPickLat = roundTencentCoord(out[0]);
            clockPickLng = roundTencentCoord(out[1]);
            clockPickReady = true;
            clockPickAtMs = now;
        }
    }

    private static void applyClockSiteJitterLocked(double[] out) {
        double radiusM = clockSiteRadiusM;
        if (radiusM <= 0 || radiusM > 800) {
            radiusM = FENCE_JITTER_MAX_M;
        }
        double maxM = Math.min(radiusM * 0.85d, FENCE_JITTER_MAX_M);
        if (maxM < FENCE_JITTER_MIN_M) {
            maxM = FENCE_JITTER_MIN_M;
        }
        double angle = RANDOM.nextDouble() * 2d * Math.PI;
        double dist = FENCE_JITTER_MIN_M + RANDOM.nextDouble() * (maxM - FENCE_JITTER_MIN_M);
        double cosLat = Math.cos(Math.toRadians(clockSiteLat));
        if (Math.abs(cosLat) < 0.01) {
            cosLat = 0.01;
        }
        out[0] = clockSiteLat + (dist * Math.cos(angle)) / 111320d;
        out[1] = clockSiteLng + (dist * Math.sin(angle)) / (111320d * cosLat);
    }

    /** 腾讯定位 SDK 读坐标时统一改写（对齐 iOS CLLocation Hook）。 */
    public static double pickTencentLat(double real) {
        return pickCoord(real, 0d, true);
    }

    public static double pickTencentLng(double real) {
        return pickCoord(real, 0d, false);
    }

    public static String pickDisplayLocation(String realAddress) {
        if (!isMasterEnabled()) {
            return realAddress;
        }
        synchronized (STATION_LOCK) {
            if (!hasSpoofDisplayTargetLocked()) {
                return realAddress;
            }
        }
        LocationBypassGeocodeHelper.scheduleRefresh();
        return LocationBypassGeocodeHelper.resolveAddress(realAddress);
    }

    /** 装卸站页顶部定位文案。 */
    public static String pickLoadStationDisplayText(String address) {
        return pickDisplayLocation(address);
    }

    static String stationStreetAddress() {
        synchronized (STATION_LOCK) {
            return stationStreetAddressLocked();
        }
    }

    private static String stationStreetAddressLocked() {
        StationSlot slot = spoofTargetLocked();
        if (slot == null) {
            slot = persistedTargetSlotLocked();
        }
        if (slot == null) {
            return null;
        }
        if (slot.zdwz != null && slot.zdwz.length() > 0) {
            return slot.zdwz;
        }
        if (slot.zddm != null && slot.zddm.length() > 0) {
            int idx = indexForZddmLocked(slot.zddm);
            if (idx >= 0) {
                String zdwz = stationSlots.get(idx).zdwz;
                if (zdwz != null && zdwz.length() > 0) {
                    return zdwz;
                }
            }
        }
        SPUtils sp = SPUtils.getInstance(SP_NAME);
        String savedZddm = sp.getString(KEY_ZDDM, "");
        if (slot.zddm != null && slot.zddm.equals(savedZddm)) {
            String saved = sp.getString(KEY_STREET, "");
            if (saved.length() > 0) {
                return saved;
            }
        }
        return null;
    }

    private static boolean hasSpoofDisplayTargetLocked() {
        return hasSpoofTargetAvailableLocked();
    }

    private static boolean hasSpoofTargetAvailableLocked() {
        if (routeActive) {
            return true;
        }
        if (!stationSlots.isEmpty() && spoofTargetLocked() != null) {
            return true;
        }
        if (lastTargetLat != 0d || lastTargetLng != 0d) {
            return true;
        }
        float spLat = SPUtils.getInstance(SP_NAME).getFloat(KEY_LAT, 0f);
        float spLng = SPUtils.getInstance(SP_NAME).getFloat(KEY_LNG, 0f);
        return spLat != 0f && spLng != 0f;
    }

    /** 拦截腾讯 SDK 真实定位；返回 0 表示已接管，-1 表示继续走原逻辑。 */
    public static int interceptRequestLocationUpdates(
            TencentLocationRequest request,
            TencentLocationListener listener,
            Looper looper) {
        if (!isMasterEnabled() || !hasSpoofTargetAvailable()) {
            return -1;
        }
        LocationBypassFakeLocationHub.register(listener, looper, request);
        return 0;
    }

    /** 拦截单次定位请求。 */
    public static int interceptRequestSingleFreshLocation(
            TencentLocationRequest request,
            TencentLocationListener listener,
            Looper looper) {
        if (!isMasterEnabled() || !hasSpoofTargetAvailable()) {
            return -1;
        }
        LocationBypassFakeLocationHub.register(listener, looper, request);
        return 0;
    }

    /** 从假定位 hub 注销；true 表示无需再调 SDK removeUpdates。 */
    public static boolean interceptRemoveUpdates(TencentLocationListener listener) {
        boolean removed = LocationBypassFakeLocationHub.unregister(listener);
        return isMasterEnabled() && removed;
    }

    public static boolean shouldBlockAndroidLocation() {
        return isMasterEnabled() && hasSpoofTargetAvailable();
    }

    public static boolean forceInRange() {
        return isMasterEnabled() && licenseSpoofPermitted(true);
    }

    /** 上报 isFake：SEC 关闭时沿用 SDK 检测结果；SEC 开启且正在 spoof 时强制 0。 */
    public static int resolveIsFake(boolean sdkFake) {
        if (!isMasterEnabled()) {
            return sdkFake ? 1 : 0;
        }
        synchronized (STATION_LOCK) {
            if (routeActive || spoofTargetLocked() != null) {
                return 0;
            }
        }
        return sdkFake ? 1 : 0;
    }

    /** @deprecated 旧补丁误用；保留以免 smali 链接失败，请改用 resolveIsFake。 */
    public static boolean clearFake() {
        return !isMasterEnabled() || !hasSpoofTargetAvailable();
    }

    private static double pickCoord(double real, double alt, boolean lat) {
        if (real != 0d) {
            if (lat) {
                lastReadLat = real;
            } else {
                lastReadLng = real;
            }
        }
        if (!licenseSpoofPermitted(lat)) {
            return real;
        }
        if (!SPUtils.getInstance(SP_NAME).getBoolean(KEY_ENABLED, false)) {
            return real;
        }
        if (alt != 0d) {
            return roundTencentCoord(alt);
        }
        double[] out = new double[1];
        if (resolveActiveCoordsLocked(lat, out)) {
            return roundTencentCoord(out[0]);
        }
        double read = lat ? lastReadLat : lastReadLng;
        if (read != 0d) {
            return roundTencentCoord(read);
        }
        double cached = lat ? lastTargetLat : lastTargetLng;
        if (cached != 0d) {
            return roundTencentCoord(cached);
        }
        return real;
    }

    private static void applyDriveMode() {
        synchronized (STATION_LOCK) {
            applyDriveModeLocked();
        }
        LocationBypassOverlayHelper.refreshPanelUi();
    }

    private static void applyDriveModeLocked() {
        routeFinished = false;
        if (!isMasterEnabled() || stationSlots.isEmpty()) {
            routeActive = false;
            return;
        }
        if (!hasStationSelectionLocked()) {
            routeDestIndex = -1;
            routeActive = false;
            routePoints.clear();
            routeLegEnds.clear();
            routeLegStationIdx.clear();
            routeIndex = 0;
            return;
        }
        routeDestIndex = -1;
        routeActive = false;
        routePoints.clear();
        routeLegEnds.clear();
        routeLegStationIdx.clear();
        routeIndex = 0;
        StationSlot slot = displayStationLocked();
        if (slot != null) {
            LocationBypassLogHelper.log("定位站：" + stationTitleLocked(slot));
        }
        gpsPulseIndex++;
    }

    private static void startGpsPulse() {
        stopGpsPulse();
        gpsPulseScheduled = true;
        GPS_HANDLER.post(GPS_TICK);
    }

    private static void stopGpsPulse() {
        gpsPulseScheduled = false;
        GPS_HANDLER.removeCallbacks(GPS_TICK);
    }

    private static void onGpsPulseTick() {
        if (!isMasterEnabled()) {
            return;
        }
        synchronized (STATION_LOCK) {
            gpsPulseIndex++;
            if (autoArrivalPending) {
                autoArrivalPending = false;
                handleAutoStationArrivedLocked();
            } else if (routeActive && !routeFinished) {
                if (routePoints.size() > 1) {
                    double speed = randomDriveSpeedMs();
                    int advance = Math.max(1, (int) (speed * ROUTE_TICK_MS / 1000d / ROUTE_STEP_M));
                    int prev = routeIndex;
                    routeIndex = Math.min(routeIndex + advance, routePoints.size() - 1);

                    for (int leg = 0; leg < routeLegEnds.size(); leg++) {
                        int endIdx = routeLegEnds.get(leg);
                        if (prev < endIdx && routeIndex >= endIdx && leg < routeLegStationIdx.size()) {
                            int passIdx = routeLegStationIdx.get(leg);
                            if (passIdx >= 0 && passIdx < stationSlots.size()) {
                                StationSlot pass = stationSlots.get(passIdx);
                                if (passIdx != routeDestIndex) {
                                    LocationBypassLogHelper.log("途经 " + stationTitleLocked(pass));
                                }
                                if (isAutoMode()) {
                                    markStationArrivedLocked(pass);
                                }
                            }
                        }
                    }

                    if (routeIndex >= routePoints.size() - 1) {
                        routeFinished = true;
                        if (isAutoMode()) {
                            autoArrivalPending = true;
                        }
                    }
                } else if (routePoints.size() == 1) {
                    routeFinished = true;
                    if (isAutoMode()) {
                        autoArrivalPending = true;
                    }
                }
            }
        }
        LocationBypassFakeLocationHub.deliverPeriodic();
        LocationBypassOverlayHelper.refreshPanelUi();
    }

    private static void handleAutoStationArrivedLocked() {
        if (!isAutoMode()) {
            return;
        }
        StationSlot arrived = routeDestStationLocked();
        if (arrived == null) {
            return;
        }
        LocationBypassLogHelper.log("到达 " + stationTitleLocked(arrived));
        markStationArrivedLocked(arrived);
        clearStationSelectionLocked();
        if (!autoSelectNextPendingStationLocked()) {
            routeActive = false;
            routeFinished = false;
            routeDestIndex = -1;
            LocationBypassLogHelper.log("全自动：全部站点已到达");
            return;
        }
        buildAutoRouteLocked();
        StationSlot next = displayStationLocked();
        if (routeActive && next != null) {
            LocationBypassLogHelper.log("全自动：下一站 " + stationTitleLocked(next));
        } else {
            LocationBypassLogHelper.log("全自动：请选择下一站");
        }
    }

    private static boolean autoSelectNextPendingStationLocked() {
        int pending = earliestPendingIndexLocked();
        if (pending < 0) {
            return false;
        }
        userPickedStation = true;
        stationIndex = pending;
        selectedZddm = stationSlots.get(pending).zddm;
        updateLastTargetFromIndexLocked(pending);
        LocationBypassGeocodeHelper.scheduleRefresh();
        return true;
    }

    private static boolean resolveActiveCoordsLocked(boolean lat, double[] out) {
        if (routeActive && !routePoints.isEmpty()) {
            if (!routeFinished) {
                int idx = routeIndex;
                if (idx >= routePoints.size()) {
                    idx = routePoints.size() - 1;
                }
                double[] point = routePoints.get(idx);
                double[] jittered = new double[2];
                applyMicroJitter(point[0], point[1], jittered);
                out[0] = lat ? jittered[0] : jittered[1];
                return true;
            }
            StationSlot dest = routeDestStationLocked();
            if (dest != null) {
                double[] jittered = new double[2];
                applyRandomFenceJitter(dest, jittered);
                out[0] = lat ? jittered[0] : jittered[1];
                return true;
            }
        }
        StationSlot target = spoofTargetLocked();
        if (target != null) {
            double[] jittered = new double[2];
            applyRandomFenceJitter(target, jittered);
            out[0] = lat ? jittered[0] : jittered[1];
            return true;
        }
        if (lastReadLat != 0d && lastReadLng != 0d) {
            double[] jittered = new double[2];
            applyMicroJitter(lastReadLat, lastReadLng, jittered);
            out[0] = lat ? jittered[0] : jittered[1];
            return true;
        }
        return false;
    }

    private static StationSlot spoofTargetLocked() {
        if (!isMasterEnabled()) {
            return null;
        }
        if (!stationSlots.isEmpty()) {
            if (actionZddm != null && actionZddm.length() > 0
                    && System.currentTimeMillis() < actionZddmUntil) {
                StationSlot action = stationForZddmLocked(actionZddm);
                if (action != null) {
                    return action;
                }
            }
            if (isAutoMode() && routeActive && routeDestIndex >= 0) {
                return routeDestStationLocked();
            }
            StationSlot picked = displayStationLocked();
            if (picked != null) {
                return picked;
            }
            int pending = earliestPendingIndexLocked();
            if (pending >= 0) {
                return stationSlots.get(pending);
            }
        }
        return persistedTargetSlotLocked();
    }

    private static StationSlot persistedTargetSlotLocked() {
        double lat = lastTargetLat;
        double lng = lastTargetLng;
        String zddm = selectedZddm;
        if (lat == 0d && lng == 0d) {
            float spLat = SPUtils.getInstance(SP_NAME).getFloat(KEY_LAT, 0f);
            float spLng = SPUtils.getInstance(SP_NAME).getFloat(KEY_LNG, 0f);
            if (spLat == 0f || spLng == 0f) {
                return null;
            }
            lat = spLat;
            lng = spLng;
            if (zddm == null || zddm.length() == 0) {
                zddm = SPUtils.getInstance(SP_NAME).getString(KEY_ZDDM, "");
            }
        }
        StationSlot slot = new StationSlot();
        slot.lat = roundTencentCoord(lat);
        slot.lng = roundTencentCoord(lng);
        slot.zddm = zddm != null ? zddm : "";
        return slot;
    }

    private static StationSlot displayStationLocked() {
        if (!userPickedStation || selectedZddm == null || selectedZddm.length() == 0) {
            return null;
        }
        int idx = indexForZddmLocked(selectedZddm);
        if (idx < 0 || idx >= stationSlots.size()) {
            return persistedTargetSlotLocked();
        }
        StationSlot slot = stationSlots.get(idx);
        if (slot.done) {
            return null;
        }
        stationIndex = idx;
        return slot;
    }

    private static StationSlot routeDestStationLocked() {
        if (routeDestIndex >= 0 && routeDestIndex < stationSlots.size()) {
            return stationSlots.get(routeDestIndex);
        }
        return displayStationLocked();
    }

    private static boolean hasStationSelectionLocked() {
        return displayStationLocked() != null;
    }

    private static void buildAutoRouteLocked() {
        if (!hasStationSelectionLocked()) {
            routeActive = false;
            routeDestIndex = -1;
            return;
        }
        int picked = indexForZddmLocked(selectedZddm);
        if (picked < 0 || stationSlots.get(picked).done) {
            routeActive = false;
            routeDestIndex = -1;
            return;
        }
        buildPendingRouteToLocked(picked);
    }

    private static void buildPendingRouteToLocked(int targetIdx) {
        routePoints.clear();
        routeLegEnds.clear();
        routeLegStationIdx.clear();
        routeFinished = false;
        routeIndex = 0;

        if (stationSlots.isEmpty()) {
            routeActive = false;
            return;
        }
        if (targetIdx < 0) {
            targetIdx = 0;
        }
        if (targetIdx >= stationSlots.size()) {
            targetIdx = stationSlots.size() - 1;
        }
        if (stationSlots.get(targetIdx).done) {
            routeActive = false;
            LocationBypassLogHelper.log("该站已到达，跳过规划");
            return;
        }

        int start = earliestPendingIndexLocked();
        if (start < 0) {
            start = 0;
        }
        if (targetIdx < start) {
            start = targetIdx;
        }

        ArrayList<Integer> chain = new ArrayList<>();
        for (int i = start; i <= targetIdx; i++) {
            if (!stationSlots.get(i).done) {
                chain.add(i);
            }
        }
        if (chain.isEmpty()) {
            routeActive = false;
            routeDestIndex = -1;
            return;
        }

        routeDestIndex = chain.get(chain.size() - 1);
        if (chain.size() == 1) {
            StationSlot s = stationSlots.get(chain.get(0));
            routeDestIndex = chain.get(0);
            routeAppendPoint(s.lat, s.lng);
            routeIndex = 0;
            routeFinished = true;
            routeActive = isMasterEnabled();
            if (isAutoMode() && routeActive) {
                autoArrivalPending = true;
            }
            return;
        }

        for (int c = 0; c < chain.size() - 1; c++) {
            StationSlot a = stationSlots.get(chain.get(c));
            StationSlot b = stationSlots.get(chain.get(c + 1));
            if (c == 0) {
                routeAppendPoint(a.lat, a.lng);
            }
            routeAppendLeg(a.lat, a.lng, b.lat, b.lng);
            routeLegEnds.add(routePoints.size() - 1);
            routeLegStationIdx.add(chain.get(c + 1));
        }

        routeActive = isMasterEnabled() && routePoints.size() > 1;
        if (routeActive) {
            double km = 0d;
            for (int i = 1; i < routePoints.size(); i++) {
                double[] p0 = routePoints.get(i - 1);
                double[] p1 = routePoints.get(i);
                km += haversineM(p0[0], p0[1], p1[0], p1[1]);
            }
            StationSlot fromS = stationSlots.get(chain.get(0));
            StationSlot toS = stationSlots.get(chain.get(chain.size() - 1));
            LocationBypassLogHelper.log(String.format(Locale.getDefault(),
                    "全自动 %.1fkm %s → %s",
                    km / 1000d,
                    stationTitleLocked(fromS),
                    stationTitleLocked(toS)));
        }
    }

    private static void routeAppendPoint(double lat, double lng) {
        if (!routePoints.isEmpty()) {
            double[] last = routePoints.get(routePoints.size() - 1);
            if (Math.abs(last[0] - lat) < 1e-8 && Math.abs(last[1] - lng) < 1e-8) {
                return;
            }
        }
        routePoints.add(new double[] {roundTencentCoord(lat), roundTencentCoord(lng)});
    }

    private static void routeAppendLeg(double lat1, double lng1, double lat2, double lng2) {
        double dist = haversineM(lat1, lng1, lat2, lng2);
        if (dist < 1d) {
            routeAppendPoint(lat2, lng2);
            return;
        }
        int steps = (int) Math.ceil(dist / ROUTE_STEP_M);
        if (steps < 1) {
            steps = 1;
        }
        for (int s = 1; s <= steps; s++) {
            double f = (double) s / (double) steps;
            routeAppendPoint(lat1 + (lat2 - lat1) * f, lng1 + (lng2 - lng1) * f);
        }
    }

    private static double randomDriveSpeedMs() {
        double t = RANDOM.nextDouble();
        return DRIVE_SPEED_MIN_MS + t * (DRIVE_SPEED_MAX_MS - DRIVE_SPEED_MIN_MS);
    }

    private static void applyMicroJitter(double baseLat, double baseLng, double[] out) {
        double cosLat = Math.cos(Math.toRadians(baseLat));
        if (Math.abs(cosLat) < 0.01) {
            cosLat = 0.01;
        }
        double angle = (gpsPulseIndex * 0.7d) % (2d * Math.PI);
        double dist = 2d + (gpsPulseIndex % 4);
        out[0] = baseLat + (dist * Math.cos(angle)) / 111320d;
        out[1] = baseLng + (dist * Math.sin(angle)) / (111320d * cosLat);
    }

    private static void applyRandomFenceJitter(StationSlot slot, double[] out) {
        double radiusM = slot.radiusM;
        if (radiusM <= 0 || radiusM > 800) {
            radiusM = FENCE_JITTER_MAX_M;
        }
        double maxM = Math.min(radiusM * 0.85d, FENCE_JITTER_MAX_M);
        if (maxM < FENCE_JITTER_MIN_M) {
            maxM = FENCE_JITTER_MIN_M;
        }
        double angle = RANDOM.nextDouble() * 2d * Math.PI;
        double dist = FENCE_JITTER_MIN_M + RANDOM.nextDouble() * (maxM - FENCE_JITTER_MIN_M);
        double cosLat = Math.cos(Math.toRadians(slot.lat));
        if (Math.abs(cosLat) < 0.01) {
            cosLat = 0.01;
        }
        out[0] = slot.lat + (dist * Math.cos(angle)) / 111320d;
        out[1] = slot.lng + (dist * Math.sin(angle)) / (111320d * cosLat);
    }

    private static int randomFenceSpeedInt() {
        if (RANDOM.nextFloat() < 0.25f) {
            return FENCE_SPEED_MIN_MS;
        }
        return 1 + RANDOM.nextInt(FENCE_SPEED_MAX_MS);
    }

    private static void markStationArrivedLocked(StationSlot slot) {
        if (slot == null) {
            return;
        }
        slot.done = true;
        if (selectedZddm != null && selectedZddm.equals(slot.zddm)) {
            clearSelectionIfInvalidLocked();
        }
    }

    private static void clearStationSelectionLocked() {
        userPickedStation = false;
        selectedZddm = null;
        stationIndex = -1;
        lastTargetLat = 0d;
        lastTargetLng = 0d;
        persistClearedTargetToSpLocked();
    }

    private static void persistClearedTargetToSpLocked() {
        SPUtils sp = SPUtils.getInstance(SP_NAME);
        sp.put(KEY_LAT, 0f);
        sp.put(KEY_LNG, 0f);
        sp.put(KEY_ZDDM, "");
        sp.put(KEY_USER_PICKED, false);
        sp.put(KEY_STREET, "");
    }

    private static void clearSelectionIfInvalidLocked() {
        if (selectedZddm == null || selectedZddm.length() == 0) {
            return;
        }
        int idx = indexForZddmLocked(selectedZddm);
        if (idx < 0 || idx >= stationSlots.size() || stationSlots.get(idx).done) {
            clearStationSelectionLocked();
        }
    }

    private static int earliestPendingIndexLocked() {
        for (int i = 0; i < stationSlots.size(); i++) {
            if (!stationSlots.get(i).done) {
                return i;
            }
        }
        return -1;
    }

    private static int indexForZddmLocked(String zddm) {
        if (zddm == null || zddm.length() == 0) {
            return -1;
        }
        for (int i = 0; i < stationSlots.size(); i++) {
            if (zddm.equals(stationSlots.get(i).zddm)) {
                return i;
            }
        }
        return -1;
    }

    private static StationSlot stationForZddmLocked(String zddm) {
        int idx = indexForZddmLocked(zddm);
        if (idx < 0) {
            return null;
        }
        return stationSlots.get(idx);
    }

    private static void updateLastTargetFromIndexLocked(int index) {
        if (index >= 0 && index < stationSlots.size()) {
            StationSlot slot = stationSlots.get(index);
            lastTargetLat = slot.lat;
            lastTargetLng = slot.lng;
            persistTargetToSpLocked();
            LocationBypassGeocodeHelper.scheduleRefresh();
        }
    }

    private static void restorePersistedTargetLocked() {
        SPUtils sp = SPUtils.getInstance(SP_NAME);
        userPickedStation = sp.getBoolean(KEY_USER_PICKED, false);
        selectedZddm = sp.getString(KEY_ZDDM, "");
        float lat = sp.getFloat(KEY_LAT, 0f);
        float lng = sp.getFloat(KEY_LNG, 0f);
        if (lat != 0f && lng != 0f) {
            lastTargetLat = lat;
            lastTargetLng = lng;
            LocationBypassGeocodeHelper.scheduleRefresh();
        }
    }

    private static void persistTargetToSpLocked() {
        SPUtils sp = SPUtils.getInstance(SP_NAME);
        sp.put(KEY_LAT, (float) lastTargetLat);
        sp.put(KEY_LNG, (float) lastTargetLng);
        if (selectedZddm != null) {
            sp.put(KEY_ZDDM, selectedZddm);
        }
        sp.put(KEY_USER_PICKED, userPickedStation);
        StationSlot slot = displayStationLocked();
        if (slot == null && selectedZddm != null && selectedZddm.length() > 0) {
            int idx = indexForZddmLocked(selectedZddm);
            if (idx >= 0) {
                slot = stationSlots.get(idx);
            }
        }
        if (slot != null && slot.zdwz != null && slot.zdwz.length() > 0) {
            sp.put(KEY_STREET, slot.zdwz);
        }
    }

    private static StationSlot slotFromBean(RwzxListBean bean, boolean origin) {
        Double lat = bean.getN_zdwd();
        Double lng = bean.getN_zdjd();
        if (lat == null || lng == null || lat == 0d || lng == 0d) {
            return null;
        }
        StationSlot slot = new StationSlot();
        slot.bcdh = bean.getN_bcdh();
        slot.bcmxdh = bean.getN_bcmxdh();
        slot.zddm = bean.getC_zddm();
        String zdmc = bean.getC_zdmc();
        slot.name = zdmc != null ? zdmc : "";
        String zdwz = bean.getC_zdwz();
        slot.zdwz = zdwz != null ? zdwz : "";
        slot.lat = roundTencentCoord(lat);
        slot.lng = roundTencentCoord(lng);
        slot.done = false;
        slot.origin = origin;
        return slot;
    }

    private static boolean isAutoArrived(RwzxListBean bean) {
        if (bean.getN_cljjqdzt() == 1) {
            return true;
        }
        String arrived = bean.getD_sjddsj();
        if (arrived != null && arrived.length() > 0) {
            return true;
        }
        String manual = bean.getC_sj_sgddsj();
        return manual != null && manual.length() > 0;
    }

    private static boolean isAutoLeft(RwzxListBean bean) {
        String time = bean.getD_sjlksj();
        return time != null && time.length() > 0;
    }

    private static String labelLocked(StationSlot slot) {
        if (slot == null) {
            return "?";
        }
        if (slot.zddm != null && slot.zddm.length() > 0) {
            return slot.zddm;
        }
        return "#" + slot.bcmxdh;
    }

    private static String stationTitleLocked(StationSlot slot) {
        if (slot == null) {
            return "未知站点";
        }
        boolean hasName = slot.name != null && slot.name.length() > 0;
        boolean hasZddm = slot.zddm != null && slot.zddm.length() > 0;
        if (hasName && hasZddm) {
            return slot.name + " · " + slot.zddm;
        }
        if (hasName) {
            return slot.name;
        }
        if (hasZddm) {
            return slot.zddm;
        }
        return "未命名站点";
    }

    private static String stationListTitleLocked(int index) {
        if (index < 0 || index >= stationSlots.size()) {
            return "未知站点";
        }
        StationSlot slot = stationSlots.get(index);
        String title = stationTitleLocked(slot);
        if (slot.done) {
            return title + " [已到达]";
        }
        if (index == stationIndex && userPickedStation) {
            return title + " [当前]";
        }
        return title;
    }

    private static double haversineM(double lat1, double lng1, double lat2, double lng2) {
        double r = 6371000d;
        double p1 = Math.toRadians(lat1);
        double p2 = Math.toRadians(lat2);
        double dLat = Math.toRadians(lat2 - lat1);
        double dLng = Math.toRadians(lng2 - lng1);
        double a = Math.sin(dLat / 2d) * Math.sin(dLat / 2d)
                + Math.cos(p1) * Math.cos(p2) * Math.sin(dLng / 2d) * Math.sin(dLng / 2d);
        return r * 2d * Math.atan2(Math.sqrt(a), Math.sqrt(1d - a));
    }

    /** 授权门面：UI 层调用，核心算法在本类 pickCoord / licenseMasterKey 内。 */
    public static boolean licenseIsActive() {
        return licenseSpoofPermitted(true);
    }

    public static boolean licenseGateOpen() {
        return licenseRuntimeToken() != 0;
    }

    public static String licenseStatusLine() {
        if (!licenseIsActive()) {
            String reason = licenseBlockReason();
            if (reason != null && reason.length() > 0) {
                return "授权：" + reason;
            }
            return "授权：未激活";
        }
        int expiry = SPUtils.getInstance(SP_NAME).getInt(KEY_LICENSE_EXPIRY_YMD, 0);
        return "授权：有效至 " + licenseFormatYmd(expiry);
    }

    public static String licenseBuildDeviceCode() {
        Context ctx = licenseAppContext();
        if (ctx == null) {
            return "请先进入应用";
        }
        String name = licenseReadDriverName(ctx);
        String plate = licenseReadPlate(ctx);
        if (name.length() == 0) {
            return "请先登录（缺少姓名）";
        }
        if (plate.length() == 0) {
            return "请先进入首页加载任务（缺少车牌）";
        }
        try {
            String payload = "V1|" + licenseNormalizeName(name) + "|" + licenseNormalizePlate(plate);
            byte[] key = licenseMasterKey();
            byte[] plain = payload.getBytes(StandardCharsets.UTF_8);
            byte[] cipher = licenseXorStream(plain, key);
            byte[] mac = licenseHmacSha256(key, licenseConcat(cipher, "dc-v1".getBytes(StandardCharsets.UTF_8)));
            byte[] packed = new byte[cipher.length + 6];
            System.arraycopy(cipher, 0, packed, 0, cipher.length);
            System.arraycopy(mac, 0, packed, cipher.length, 6);
            return "DC1-" + licenseFormatGroups(licenseBase32Encode(packed));
        } catch (Throwable t) {
            return "设备码生成失败";
        }
    }

    public static String licenseTryActivate(String cardInput) {
        Context ctx = licenseAppContext();
        if (ctx == null) {
            return "无应用上下文";
        }
        if (cardInput == null || cardInput.trim().length() == 0) {
            return "请输入卡密";
        }
        String code = cardInput.trim().toUpperCase(Locale.US).replace(" ", "");
        if (code.startsWith("AK1-")) {
            code = code.substring(4);
        } else if (code.startsWith("AK1")) {
            code = code.substring(3);
        }
        code = code.replace("-", "");
        try {
            byte[] packed = licenseBase32Decode(code);
            if (packed.length < 14) {
                return "卡密格式错误";
            }
            int expiryYmd = ((packed[0] & 0xFF) << 24)
                    | ((packed[1] & 0xFF) << 16)
                    | ((packed[2] & 0xFF) << 8)
                    | (packed[3] & 0xFF);
            if (!licenseIsValidYmd(expiryYmd)) {
                return "到期日无效";
            }
            if (expiryYmd < licenseTodayYmd()) {
                return "卡密已过期";
            }
            byte[] sig = new byte[10];
            System.arraycopy(packed, 4, sig, 0, 10);
            byte[] expect = licenseActivationSig(ctx, expiryYmd);
            if (!licenseSlowEquals(sig, expect)) {
                return "卡密无效（身份不匹配）";
            }
            String formatted = "AK1-" + licenseFormatGroups(licenseBase32Encode(packed));
            SPUtils.getInstance(SP_NAME).put(KEY_LICENSE_ACTIVATION, formatted);
            SPUtils.getInstance(SP_NAME).put(KEY_LICENSE_EXPIRY_YMD, expiryYmd);
            licenseTokenCache = 0;
            licenseTokenAtMs = 0L;
            LocationBypassLogHelper.log("授权成功至 " + licenseFormatYmd(expiryYmd));
            return "激活成功，有效至 " + licenseFormatYmd(expiryYmd);
        } catch (Throwable t) {
            return "卡密解析失败";
        }
    }

    public static String licenseBlockReason() {
        Context ctx = licenseAppContext();
        if (ctx == null) {
            return "未就绪";
        }
        int expiry = SPUtils.getInstance(SP_NAME).getInt(KEY_LICENSE_EXPIRY_YMD, 0);
        String stored = SPUtils.getInstance(SP_NAME).getString(KEY_LICENSE_ACTIVATION, "");
        if (stored == null || stored.length() == 0 || expiry <= 0) {
            if (licenseReadDriverName(ctx).length() == 0) {
                return "请先登录";
            }
            if (licenseReadPlate(ctx).length() == 0) {
                return "请先加载任务";
            }
            return "未激活";
        }
        if (expiry < licenseTodayYmd()) {
            return "已过期";
        }
        if (!licenseVerifyStored(ctx, stored, expiry)) {
            return "卡密失效";
        }
        return null;
    }

    private static boolean licenseSpoofPermitted(boolean lat) {
        int tok = licenseRuntimeToken();
        if (tok == 0) {
            return false;
        }
        int lane = lat ? LICENSE_LANE_LAT : LICENSE_LANE_LNG;
        return ((tok ^ lane) & 0xFFFF0000) == LICENSE_GATE_MAGIC;
    }

    private static int licenseRuntimeToken() {
        long now = System.currentTimeMillis();
        if (licenseTokenCache != 0 && now - licenseTokenAtMs < 15000L) {
            return licenseTokenCache;
        }
        int fresh = licenseComputeToken();
        licenseTokenCache = fresh;
        licenseTokenAtMs = now;
        return fresh;
    }

    private static int licenseComputeToken() {
        Context ctx = licenseAppContext();
        if (ctx == null) {
            return 0;
        }
        int expiry = SPUtils.getInstance(SP_NAME).getInt(KEY_LICENSE_EXPIRY_YMD, 0);
        String stored = SPUtils.getInstance(SP_NAME).getString(KEY_LICENSE_ACTIVATION, "");
        if (!licenseVerifyStored(ctx, stored, expiry)) {
            return 0;
        }
        try {
            byte[] sig = licenseActivationSig(ctx, expiry);
            int tail = ((sig[0] & 0xFF) << 8) | (sig[1] & 0xFF);
            return LICENSE_GATE_MAGIC | (tail & 0xFFFF);
        } catch (Throwable t) {
            return 0;
        }
    }

    private static byte[] licenseMasterKey() throws Exception {
        String seed = licenseSeedPartA()
                + "|" + String.format(Locale.US, "%.3f", ROUTE_STEP_M)
                + "|" + String.format(Locale.US, "%.1f", FENCE_JITTER_MAX_M)
                + "|" + LocationBypassFakeLocationHub.licenseMixFragment()
                + "|" + LocationBypassGeocodeHelper.licenseMixFragment()
                + "|" + String.format(Locale.US, "%d", (long) (DRIVE_SPEED_MIN_MS * 1000d))
                + "|" + (FENCE_SPEED_MAX_MS ^ 0x5A3C);
        return licenseSha256(seed.getBytes(StandardCharsets.UTF_8));
    }

    private static String licenseSeedPartA() {
        return new String(new char[] {
                (char) 0x73, (char) 0x69, (char) 0x6A, (char) 0x69,
                (char) 0x2D, (char) 0x73, (char) 0x65, (char) 0x63
        });
    }

    private static boolean licenseVerifyStored(Context ctx, String stored, int expiryYmd) {
        if (stored == null || stored.length() == 0 || expiryYmd <= 0) {
            return false;
        }
        if (expiryYmd < licenseTodayYmd()) {
            return false;
        }
        try {
            String code = stored.toUpperCase(Locale.US).replace(" ", "");
            if (code.startsWith("AK1-")) {
                code = code.substring(4);
            } else if (code.startsWith("AK1")) {
                code = code.substring(3);
            }
            code = code.replace("-", "");
            byte[] packed = licenseBase32Decode(code);
            if (packed.length < 14) {
                return false;
            }
            int expiry = ((packed[0] & 0xFF) << 24)
                    | ((packed[1] & 0xFF) << 16)
                    | ((packed[2] & 0xFF) << 8)
                    | (packed[3] & 0xFF);
            if (expiry != expiryYmd) {
                return false;
            }
            byte[] sig = new byte[10];
            System.arraycopy(packed, 4, sig, 0, 10);
            return licenseSlowEquals(sig, licenseActivationSig(ctx, expiryYmd));
        } catch (Throwable t) {
            return false;
        }
    }

    private static byte[] licenseActivationSig(Context ctx, int expiryYmd) throws Exception {
        String signInput = "V1|"
                + licenseNormalizeName(licenseReadDriverName(ctx)) + "|"
                + licenseNormalizePlate(licenseReadPlate(ctx)) + "|"
                + expiryYmd;
        byte[] full = licenseHmacSha256(licenseMasterKey(), signInput.getBytes(StandardCharsets.UTF_8));
        byte[] sig = new byte[10];
        System.arraycopy(full, 0, sig, 0, 10);
        return sig;
    }

    private static String licenseNormalizeName(String name) {
        if (name == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < name.length(); i++) {
            char c = name.charAt(i);
            if (!Character.isWhitespace(c)) {
                sb.append(c);
            }
        }
        return sb.toString().trim();
    }

    private static String licenseNormalizePlate(String plate) {
        if (plate == null) {
            return "";
        }
        return plate.replace(" ", "").toUpperCase(Locale.US).trim();
    }

    private static String licenseReadDriverName(Context ctx) {
        try {
            String name = SPUtils.getInstance(DRIVER_SP).getString(DRIVER_KEY_USER_NAME, "");
            return name != null ? name : "";
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static String licenseReadPlate(Context ctx) {
        try {
            String plate = SPUtils.getInstance(SP_NAME).getString("fetch_cph", "");
            if (plate != null && plate.length() > 0) {
                return plate;
            }
            plate = SPUtils.getInstance("userInfo").getString("c_cph", "");
            if (plate != null && plate.length() > 0) {
                return plate;
            }
        } catch (Throwable ignored) {
        }
        return "";
    }

    private static Context licenseAppContext() {
        Context ctx = LocationBypassOverlayHelper.getAppContext();
        if (ctx != null) {
            return ctx;
        }
        try {
            Class<?> utils = Class.forName("com.blankj.utilcode.util.Utils");
            return (Context) utils.getMethod("getApp").invoke(null);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static int licenseTodayYmd() {
        Calendar c = Calendar.getInstance();
        return c.get(Calendar.YEAR) * 10000
                + (c.get(Calendar.MONTH) + 1) * 100
                + c.get(Calendar.DAY_OF_MONTH);
    }

    private static boolean licenseIsValidYmd(int ymd) {
        if (ymd < 20240101 || ymd > 20991231) {
            return false;
        }
        int y = ymd / 10000;
        int m = (ymd / 100) % 100;
        int d = ymd % 100;
        return m >= 1 && m <= 12 && d >= 1 && d <= 31 && y >= 2024;
    }

    private static String licenseFormatYmd(int ymd) {
        int y = ymd / 10000;
        int m = (ymd / 100) % 100;
        int d = ymd % 100;
        return String.format(Locale.getDefault(), "%04d-%02d-%02d", y, m, d);
    }

    private static byte[] licenseSha256(byte[] input) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        return md.digest(input);
    }

    private static byte[] licenseHmacSha256(byte[] key, byte[] data) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(data);
    }

    private static byte[] licenseXorStream(byte[] data, byte[] key) throws Exception {
        byte[] stream = licenseExpandStream(key, data.length);
        byte[] out = new byte[data.length];
        for (int i = 0; i < data.length; i++) {
            out[i] = (byte) (data[i] ^ stream[i]);
        }
        return out;
    }

    private static byte[] licenseExpandStream(byte[] key, int len) throws Exception {
        byte[] out = new byte[len];
        int pos = 0;
        int counter = 0;
        while (pos < len) {
            byte[] block = licenseHmacSha256(key, ("lb-stream-" + counter).getBytes(StandardCharsets.UTF_8));
            int copy = Math.min(block.length, len - pos);
            System.arraycopy(block, 0, out, pos, copy);
            pos += copy;
            counter++;
        }
        return out;
    }

    private static byte[] licenseConcat(byte[] a, byte[] b) {
        byte[] out = new byte[a.length + b.length];
        System.arraycopy(a, 0, out, 0, a.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }

    private static boolean licenseSlowEquals(byte[] a, byte[] b) {
        if (a == null || b == null || a.length != b.length) {
            return false;
        }
        int diff = 0;
        for (int i = 0; i < a.length; i++) {
            diff |= a[i] ^ b[i];
        }
        return diff == 0;
    }

    private static final char[] LICENSE_B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".toCharArray();

    private static String licenseBase32Encode(byte[] data) {
        StringBuilder sb = new StringBuilder((data.length * 8 + 4) / 5);
        int buffer = 0;
        int bits = 0;
        for (byte b : data) {
            buffer = (buffer << 8) | (b & 0xFF);
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                sb.append(LICENSE_B32[(buffer >> bits) & 31]);
            }
        }
        if (bits > 0) {
            sb.append(LICENSE_B32[(buffer << (5 - bits)) & 31]);
        }
        return sb.toString();
    }

    private static byte[] licenseBase32Decode(String encoded) {
        String s = encoded.toUpperCase(Locale.US).replace("=", "").replace("-", "").replace(" ", "");
        int buffer = 0;
        int bits = 0;
        int idx = 0;
        byte[] tmp = new byte[(s.length() * 5) / 8 + 4];
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            int val = licenseB32Value(c);
            if (val < 0) {
                continue;
            }
            buffer = (buffer << 5) | val;
            bits += 5;
            if (bits >= 8) {
                bits -= 8;
                tmp[idx++] = (byte) ((buffer >> bits) & 0xFF);
            }
        }
        byte[] out = new byte[idx];
        System.arraycopy(tmp, 0, out, 0, idx);
        return out;
    }

    private static int licenseB32Value(char c) {
        if (c >= 'A' && c <= 'Z') {
            return c - 'A';
        }
        if (c >= '2' && c <= '7') {
            return c - '2' + 26;
        }
        return -1;
    }

    private static String licenseFormatGroups(String raw) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < raw.length(); i++) {
            if (i > 0 && i % 4 == 0) {
                sb.append('-');
            }
            sb.append(raw.charAt(i));
        }
        return sb.toString();
    }
}
