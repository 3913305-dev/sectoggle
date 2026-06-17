/**
 * TPlayer (com.twanjia.teslaplayer) — 内测用响应重写
 * 配合 Quantumult X [rewrite] script-response-body 使用
 * 逻辑对齐 TPlayerFakeVIP.dylib v7
 */

const DIAL_IDS = [
  "amap", "apple_map", "amap_navigation", "apple_maps_navigation",
  "amap_dial", "apple_map_dial", "classic", "emitter", "navigation",
  "tita", "tita_pro", "tita_ultra", "pie", "hud", "hud_dashboard",
  "dashboard", "all_in_one_navigation_dial", "dashboard_startup_dial",
  "model3", "modely", "cybertruck", "retro", "minimal", "neon",
];

const EFFECT_IDS = ["effect_1", "effect_2", "effect_3", "effect_4", "acceleration"];

const AUTH_PATHS = [
  "/auth/phone/login",
  "/auth/phone/password_login",
  "/auth/wechat/app_login",
  "/auth/apple/login",
  "/auth/email/login",
  "/auth/email/register",
  "/user/accountMergeCommit",
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
    avatar_url: "",
  };
}

function wrap(data) {
  return JSON.stringify({ code: 0, msg: "ok", encrypted: false, data });
}

function urlHas(url, needle) {
  return url.toLowerCase().indexOf(needle.toLowerCase()) !== -1;
}

function isAuthUrl(url) {
  return AUTH_PATHS.some((p) => urlHas(url, p));
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
  Object.assign(target, vipData());
}

function markUnlocked(node) {
  if (!node || typeof node !== "object") return;
  if (Array.isArray(node)) {
    node.forEach(markUnlocked);
    return;
  }
  if (node.unlocked !== undefined) node.unlocked = true;
  if (node.is_vip !== undefined) node.is_vip = 1;
  if (node._is_vip !== undefined) node._is_vip = 1;
  if (node.is_lifetime_vip !== undefined) node.is_lifetime_vip = 1;
  if (node.is_lifetime !== undefined) node.is_lifetime = 1;
  if (node._is_lifetime !== undefined) node._is_lifetime = 1;
  if (node.unlocked_all !== undefined) node.unlocked_all = true;
  Object.keys(node).forEach((k) => markUnlocked(node[k]));
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
  const paths = [
    "/vip/checkVipStatus",
    "/vip/activateWithIAP",
    "/vip/getPlanList",
    "/user/getUserInfo",
    "/effect/myUnlocks",
    "/wallpaper/getMyUnlocks",
    "/wallpaper/iapProducts",
    ...AUTH_PATHS,
  ];
  return paths.some((p) => urlHas(url, p));
}

(() => {
  const url = $request.url;
  if (!shouldPatch(url)) {
    $done({});
    return;
  }

  let obj;
  try {
    obj = JSON.parse($response.body);
  } catch (e) {
    $done({});
    return;
  }

  const enc = isEncrypted(obj);
  const dedicated = fakeForUrl(url);

  // --- 登录 / 注册：明文 merge，密文整包 bypass（QX 无法解密后再改）---
  if (isAuthUrl(url)) {
    if (enc) {
      // 密文登录：整包替换成明文 VIP（可能丢失 token，需退出重登试验）
      if (dedicated) {
        $done({ body: dedicated });
        return;
      }
      $done({ body: wrap(vipData()) });
      return;
    }
    mergeVip(ensureDataObject(obj));
    obj.code = 0;
    obj.msg = "ok";
    obj.encrypted = false;
    $done({ body: JSON.stringify(obj) });
    return;
  }

  // --- 有专用假响应的接口 ---
  if (dedicated) {
    if (enc) {
      $done({ body: dedicated });
      return;
    }
    if (urlHas(url, "/vip/checkVipStatus") || urlHas(url, "/user/getUserInfo")) {
      mergeVip(ensureDataObject(obj));
    } else if (urlHas(url, "/vip/activateWithIAP")) {
      Object.assign(ensureDataObject(obj), { activated: true, is_vip: 1, is_lifetime_vip: 1 });
    } else if (urlHas(url, "/effect/myUnlocks") || urlHas(url, "/wallpaper/getMyUnlocks")) {
      Object.assign(ensureDataObject(obj), { list: [], unlocked_all: true });
    } else if (urlHas(url, "/wallpaper/iapProducts") || urlHas(url, "/vip/getPlanList")) {
      obj.data = [];
    }
    obj.code = 0;
    obj.msg = "ok";
    obj.encrypted = false;
    $done({ body: JSON.stringify(obj) });
    return;
  }

  // --- 其它 teslaapi JSON：encrypted 则 bypass，明文则递归 unlocked ---
  if (enc) {
    $done({ body: wrap(vipData()) });
    return;
  }

  markUnlocked(obj);
  obj.encrypted = false;
  $done({ body: JSON.stringify(obj) });
})();
