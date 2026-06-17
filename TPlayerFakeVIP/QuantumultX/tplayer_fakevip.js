/*
> TPlayer FakeVIP 特别玩家内测
> 引用方式：重写 → 规则资源 → 资源路径填本 js 链接 → 开启资源解析器

[rewrite_local]
^https?://teslaapi\.twanjia\.com url script-response-body https://raw.githubusercontent.com/3913305-dev/sectoggle/main/TPlayerFakeVIP/QuantumultX/tplayer_fakevip.js

[mitm]
hostname = teslaapi.twanjia.com, *.twanjia.com
*/

var TP_DEBUG = true;
var TP_HIT = 0;

function tpDbg(title, body) {
  if (!TP_DEBUG) return;
  TP_HIT++;
  if (TP_HIT <= 5) {
    try { $notify(title, body, $request.url); } catch (e) {}
  }
}

var DIAL_IDS = [
  "amap", "apple_map", "amap_navigation", "apple_maps_navigation",
  "amap_dial", "apple_map_dial", "classic", "emitter", "navigation",
  "tita", "tita_pro", "tita_ultra", "pie", "hud", "hud_dashboard",
  "dashboard", "all_in_one_navigation_dial", "dashboard_startup_dial",
  "model3", "modely", "cybertruck", "retro", "minimal", "neon"
];

var EFFECT_IDS = ["effect_1", "effect_2", "effect_3", "effect_4", "acceleration"];

var AUTH_PATHS = [
  "/auth/phone/login",
  "/auth/phone/password_login",
  "/auth/wechat/app_login",
  "/auth/apple/login",
  "/auth/email/login",
  "/auth/email/register",
  "/user/accountMergeCommit"
];

function vipData() {
  return {
    is_vip: 1,
    _is_vip: 1,
    is_lifetime_vip: 1,
    is_lifetime: 1,
    _is_lifetime: 1,
    is_ad_free: 1,
    _is_ad_free: 1,
    vip_days_left: null,
    _days_left: null,
    vip_end_time: null,
    _vip_end_time: null,
    _subscription_provider: "internal_test",
    dial_unlocks: DIAL_IDS,
    _dial_unlocks: DIAL_IDS,
    effect_unlocks: EFFECT_IDS,
    _effect_unlocks: EFFECT_IDS,
    wallpaper_unlocks: [],
    _wallpaper_unlocks: [],
    mini_player_unlocks: [],
    _mini_player_unlocks: [],
    unlocked_all: true,
    nickname: "VIP",
    avatar_url: ""
  };
}

function wrap(data) {
  return JSON.stringify({ code: 0, msg: "ok", encrypted: false, data: data });
}

function urlHas(url, needle) {
  return url.toLowerCase().indexOf(needle.toLowerCase()) !== -1;
}

function isAuthUrl(url) {
  for (var i = 0; i < AUTH_PATHS.length; i++) {
    if (urlHas(url, AUTH_PATHS[i])) return true;
  }
  return false;
}

function isEncrypted(obj) {
  if (!obj || typeof obj !== "object") return false;
  if (obj.encrypted === true) return true;
  if (typeof obj.data === "string" && obj.data.length > 0) return true;
  return false;
}

function ensureDataObject(obj) {
  if (obj.data && typeof obj.data === "object" && !Array.isArray(obj.data)) {
    return obj.data;
  }
  obj.data = {};
  return obj.data;
}

function mergeVip(target) {
  var v = vipData();
  for (var k in v) {
    if (v.hasOwnProperty(k)) target[k] = v[k];
  }
}

function markUnlocked(node) {
  if (!node || typeof node !== "object") return;
  if (Object.prototype.toString.call(node) === "[object Array]") {
    for (var i = 0; i < node.length; i++) markUnlocked(node[i]);
    return;
  }
  if (node.unlocked !== undefined) node.unlocked = true;
  if (node.is_vip !== undefined) node.is_vip = 1;
  if (node._is_vip !== undefined) node._is_vip = 1;
  if (node.is_lifetime_vip !== undefined) node.is_lifetime_vip = 1;
  if (node.is_lifetime !== undefined) node.is_lifetime = 1;
  if (node._is_lifetime !== undefined) node._is_lifetime = 1;
  if (node.unlocked_all !== undefined) node.unlocked_all = true;
  for (var key in node) {
    if (node.hasOwnProperty(key)) markUnlocked(node[key]);
  }
}

function fakeForUrl(url) {
  if (urlHas(url, "/vip/checkVipStatus") || urlHas(url, "/user/getUserInfo")) {
    return wrap(vipData());
  }
  if (urlHas(url, "/vip/activateWithIAP")) {
    return wrap({ activated: true, is_vip: 1, is_lifetime_vip: 1 });
  }
  if (urlHas(url, "/effect/myUnlocks") || urlHas(url, "/wallpaper/getMyUnlocks")) {
    return wrap({ list: [], unlocked_all: true });
  }
  if (urlHas(url, "/wallpaper/iapProducts") || urlHas(url, "/vip/getPlanList")) {
    return wrap([]);
  }
  return null;
}

function shouldPatch(url) {
  if (!urlHas(url, "teslaapi.twanjia.com")) return false;
  var paths = [
    "/vip/checkVipStatus", "/vip/activateWithIAP", "/vip/getPlanList",
    "/user/getUserInfo", "/effect/myUnlocks", "/wallpaper/getMyUnlocks",
    "/wallpaper/iapProducts"
  ];
  for (var i = 0; i < paths.length; i++) {
    if (urlHas(url, paths[i])) return true;
  }
  return isAuthUrl(url);
}

var url = $request.url;
if (!shouldPatch(url)) {
  $done({});
} else {
  var obj = null;
  try {
    obj = JSON.parse($response.body);
  } catch (e) {
    $done({});
  }

  if (obj) {
    var enc = isEncrypted(obj);
    var dedicated = fakeForUrl(url);

    if (isAuthUrl(url)) {
      if (enc) {
        tpDbg("TPlayer QX", "auth encrypted -> bypass");
        $done({ body: dedicated || wrap(vipData()) });
      } else {
        mergeVip(ensureDataObject(obj));
        obj.code = 0;
        obj.msg = "ok";
        obj.encrypted = false;
        tpDbg("TPlayer QX", "auth merge ok");
        $done({ body: JSON.stringify(obj) });
      }
    } else if (dedicated) {
      if (enc) {
        tpDbg("TPlayer QX", "patch " + (url.split("?")[0].split("/").pop() || "api"));
        $done({ body: dedicated });
      } else {
        if (urlHas(url, "/vip/checkVipStatus") || urlHas(url, "/user/getUserInfo")) {
          mergeVip(ensureDataObject(obj));
        } else if (urlHas(url, "/vip/activateWithIAP")) {
          var d = ensureDataObject(obj);
          d.activated = true;
          d.is_vip = 1;
          d.is_lifetime_vip = 1;
        } else if (urlHas(url, "/effect/myUnlocks") || urlHas(url, "/wallpaper/getMyUnlocks")) {
          var e = ensureDataObject(obj);
          e.list = [];
          e.unlocked_all = true;
        } else if (urlHas(url, "/wallpaper/iapProducts") || urlHas(url, "/vip/getPlanList")) {
          obj.data = [];
        }
        obj.code = 0;
        obj.msg = "ok";
        obj.encrypted = false;
        $done({ body: JSON.stringify(obj) });
      }
    } else if (enc) {
      $done({ body: wrap(vipData()) });
    } else {
      markUnlocked(obj);
      obj.encrypted = false;
      $done({ body: JSON.stringify(obj) });
    }
  }
}
