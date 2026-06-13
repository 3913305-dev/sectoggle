package com.copote.yygk.app.mine.ui.helper;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import com.blankj.utilcode.util.SPUtils;

public final class LocationBypassOverlayHelper {
    private static final String TAG_ROOT = "location_bypass_root";
    private static final String SP_OVERLAY = "location_bypass_overlay";
    private static final String KEY_MARGIN_START = "margin_start";
    private static final String KEY_MARGIN_TOP = "margin_top";
    private static final String KEY_USER_POSITIONED = "user_positioned";
    private static final String KEY_PANEL_MARGIN_START = "panel_margin_start";
    private static final String KEY_PANEL_MARGIN_TOP = "panel_margin_top";
    private static final String KEY_PANEL_USER_POSITIONED = "panel_user_positioned";

    private static ViewGroup rootOverlay;
    private static View dismissScrim;
    private static View iconView;
    private static View panelView;
    private static boolean panelVisible;
    private static TextView statusLabel;
    private static LinearLayout stationListInner;
    private static ScrollView stationListScroll;
    private static Switch masterSwitch;
    private static TextView licenseStatusLabel;
    private static TextView deviceCodeLabel;
    private static EditText activationInput;

    private static float dragStartRawX;
    private static float dragStartRawY;
    private static int dragStartMarginStart;
    private static int dragStartMarginTop;
    private static boolean dragging;

    private static float panelDragStartRawX;
    private static float panelDragStartRawY;
    private static int panelDragStartMarginStart;
    private static int panelDragStartMarginTop;
    private static boolean panelDragging;

    private LocationBypassOverlayHelper() {
    }

    public static Context getAppContext() {
        if (rootOverlay != null) {
            Context ctx = rootOverlay.getContext();
            if (ctx != null) {
                return ctx.getApplicationContext();
            }
        }
        return null;
    }

    public static boolean shouldShowOverlay(Activity activity) {
        if (activity == null || activity.isFinishing()) {
            return false;
        }
        String name = activity.getClass().getName();
        return !name.endsWith(".ProjectStartActivity")
                && name.indexOf("Splash") < 0
                && name.indexOf("Welcome") < 0;
    }

    public static void onResume(Activity activity) {
        if (!shouldShowOverlay(activity)) {
            detach();
            return;
        }
        detach();
        ViewGroup decor = (ViewGroup) activity.getWindow().getDecorView();
        if (decor.findViewWithTag(TAG_ROOT) != null) {
            return;
        }

        Context ctx = activity;
        FrameLayout root = new FrameLayout(ctx);
        root.setTag(TAG_ROOT);
        root.setLayoutParams(new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));
        rootOverlay = root;

        dismissScrim = new View(ctx);
        dismissScrim.setClickable(true);
        dismissScrim.setVisibility(View.GONE);
        dismissScrim.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                hidePanel();
            }
        });
        root.addView(dismissScrim, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        int panelW = dp(ctx, 300);
        panelView = buildPanel(ctx);
        panelView.setVisibility(View.GONE);
        FrameLayout.LayoutParams panelLp = new FrameLayout.LayoutParams(panelW, FrameLayout.LayoutParams.WRAP_CONTENT);
        panelLp.gravity = Gravity.CENTER;
        root.addView(panelView, panelLp);

        iconView = buildIcon(ctx);
        int iconSize = dp(ctx, 46);
        FrameLayout.LayoutParams iconLp = new FrameLayout.LayoutParams(iconSize, iconSize);
        iconLp.gravity = Gravity.TOP | Gravity.START;
        if (isIconUserPositioned(ctx)) {
            iconLp.setMarginStart(loadIconMarginStart(ctx));
            iconLp.topMargin = loadIconMarginTop(ctx);
        } else {
            iconLp.setMarginStart(dp(ctx, 20));
            iconLp.topMargin = dp(ctx, 20);
        }
        root.addView(iconView, iconLp);

        decor.addView(root);
        container = root;
        panelVisible = false;
        refreshPanelUi();
    }

    /** 兼容旧引用 */
    private static ViewGroup container;

    public static void onPause(Activity activity) {
        if (rootOverlay != null && activity != null
                && rootOverlay.getContext() == activity) {
            detach();
        }
    }

    private static void detach() {
        if (rootOverlay != null) {
            ViewGroup parent = (ViewGroup) rootOverlay.getParent();
            if (parent != null) {
                parent.removeView(rootOverlay);
            }
        }
        rootOverlay = null;
        container = null;
        dismissScrim = null;
        iconView = null;
        panelView = null;
        statusLabel = null;
        stationListInner = null;
        stationListScroll = null;
        masterSwitch = null;
        licenseStatusLabel = null;
        deviceCodeLabel = null;
        activationInput = null;
        panelVisible = false;
    }

    public static void refreshPanelUi() {
        if (statusLabel != null) {
            statusLabel.setText(LocationBypassHelper.getStatusText());
        }
        if (licenseStatusLabel != null) {
            licenseStatusLabel.setText(LocationBypassLicenseHelper.getLicenseStatusLine());
        }
        if (deviceCodeLabel != null) {
            deviceCodeLabel.setText(LocationBypassLicenseHelper.buildDeviceCode());
        }
        refreshStationList();
        if (masterSwitch != null) {
            masterSwitch.setOnCheckedChangeListener(null);
            masterSwitch.setChecked(LocationBypassHelper.isMasterEnabled());
            masterSwitch.setEnabled(LocationBypassLicenseHelper.isLicensed());
            masterSwitch.setOnCheckedChangeListener(masterSwitchListener);
        }
    }

    public static void refreshManualTriggerUi() {
        refreshPanelUi();
    }

    private static final CompoundButton.OnCheckedChangeListener masterSwitchListener =
            new CompoundButton.OnCheckedChangeListener() {
                @Override
                public void onCheckedChanged(CompoundButton buttonView, boolean isChecked) {
                    if (isChecked && !LocationBypassLicenseHelper.isLicensed()) {
                        buttonView.setOnCheckedChangeListener(null);
                        buttonView.setChecked(false);
                        buttonView.setOnCheckedChangeListener(masterSwitchListener);
                        LocationBypassLogHelper.log(
                                LocationBypassLicenseHelper.getBlockReason() != null
                                        ? LocationBypassLicenseHelper.getBlockReason()
                                        : "请先激活卡密");
                        refreshPanelUi();
                        return;
                    }
                    LocationBypassHelper.setMasterEnabled(isChecked);
                    LocationBypassLogHelper.log(isChecked ? "定位开关已开启" : "定位开关已关闭");
                }
            };

    private static void refreshStationList() {
        if (stationListInner == null) {
            return;
        }
        stationListInner.removeAllViews();
        Context ctx = stationListInner.getContext();
        int count = LocationBypassHelper.getStationCount();
        int pending = LocationBypassHelper.countPendingStations();
        if (count <= 0) {
            addStationHint(ctx, "请先打开装卸站", false);
            return;
        }
        if (pending == 0) {
            addStationHint(ctx, "全部站点已到达", false);
            return;
        }
        TextView header = new TextView(ctx);
        header.setText("未到达站点（点选）");
        header.setTextSize(9f);
        header.setTextColor(0x8CFFFFFF);
        header.setPadding(dp(ctx, 4), dp(ctx, 2), dp(ctx, 4), dp(ctx, 4));
        stationListInner.addView(header, matchWrap());

        int active = LocationBypassHelper.getActiveStationIndex();
        for (int i = 0; i < count; i++) {
            if (!LocationBypassHelper.isStationPending(i)) {
                continue;
            }
            final int index = i;
            TextView item = new TextView(ctx);
            item.setText(LocationBypassHelper.getStationPickerLabel(i));
            item.setTextSize(11f);
            item.setTextColor(Color.WHITE);
            item.setPadding(dp(ctx, 10), dp(ctx, 8), dp(ctx, 10), dp(ctx, 8));
            item.setClickable(true);
            boolean selected = i == active && LocationBypassHelper.hasStationSelection();
            styleStationItem(item, selected);
            item.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    LocationBypassHelper.selectStationByIndex(index);
                }
            });
            LinearLayout.LayoutParams lp = matchWrap();
            lp.bottomMargin = dp(ctx, 4);
            stationListInner.addView(item, lp);
        }
    }

    private static void addStationHint(Context ctx, String text, boolean enabled) {
        TextView hint = new TextView(ctx);
        hint.setText(text);
        hint.setTextSize(11f);
        hint.setTextColor(0xAAFFFFFF);
        hint.setPadding(dp(ctx, 10), dp(ctx, 8), dp(ctx, 10), dp(ctx, 8));
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(ctx, 6));
        bg.setColor(0xFF484848);
        hint.setBackground(bg);
        hint.setAlpha(enabled ? 1f : 0.55f);
        stationListInner.addView(hint, matchWrap());
    }

    private static void styleStationItem(TextView item, boolean selected) {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(item.getContext(), 6));
        if (selected) {
            bg.setColor(0xFF3366AA);
        } else {
            bg.setColor(0xFF484848);
        }
        item.setBackground(bg);
    }

    private static TextView buildIcon(final Context context) {
        TextView icon = new TextView(context);
        icon.setText("SEC");
        icon.setTextColor(Color.WHITE);
        icon.setTextSize(11f);
        icon.setGravity(Gravity.CENTER);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL);
        bg.setColor(0xF0D9730D);
        bg.setStroke(dp(context, 2), Color.WHITE);
        icon.setBackground(bg);
        icon.setElevation(dp(context, 8));

        final int touchSlop = ViewConfiguration.get(context).getScaledTouchSlop();
        icon.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View v, MotionEvent event) {
                if (rootOverlay == null || iconView == null) {
                    return false;
                }
                FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) iconView.getLayoutParams();
                switch (event.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN:
                        dragStartRawX = event.getRawX();
                        dragStartRawY = event.getRawY();
                        dragStartMarginStart = lp.getMarginStart();
                        dragStartMarginTop = lp.topMargin;
                        dragging = false;
                        return true;
                    case MotionEvent.ACTION_MOVE:
                        float dx = event.getRawX() - dragStartRawX;
                        float dy = event.getRawY() - dragStartRawY;
                        if (!dragging && (Math.abs(dx) > touchSlop || Math.abs(dy) > touchSlop)) {
                            dragging = true;
                            hidePanel();
                        }
                        if (dragging) {
                            int maxX = rootOverlay.getWidth() - iconView.getWidth();
                            int maxY = rootOverlay.getHeight() - iconView.getHeight();
                            lp.setMarginStart(clampMargin(
                                    dragStartMarginStart + (int) dx, 0, maxX));
                            lp.topMargin = clampMargin(
                                    dragStartMarginTop + (int) dy, 0, maxY);
                            iconView.setLayoutParams(lp);
                        }
                        return true;
                    case MotionEvent.ACTION_UP:
                    case MotionEvent.ACTION_CANCEL:
                        if (dragging) {
                            saveIconPosition(context, lp.getMarginStart(), lp.topMargin);
                            dragging = false;
                            return true;
                        }
                        if (panelVisible) {
                            hidePanel();
                        } else {
                            showPanel();
                        }
                        return true;
                    default:
                        return false;
                }
            }
        });
        return icon;
    }

    private static void attachPanelDrag(final Context context, View dragHandle) {
        final int touchSlop = ViewConfiguration.get(context).getScaledTouchSlop();
        dragHandle.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View v, MotionEvent event) {
                if (rootOverlay == null || panelView == null) {
                    return false;
                }
                FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) panelView.getLayoutParams();
                switch (event.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN:
                        panelDragStartRawX = event.getRawX();
                        panelDragStartRawY = event.getRawY();
                        ensurePanelTopStart(lp);
                        panelDragStartMarginStart = lp.getMarginStart();
                        panelDragStartMarginTop = lp.topMargin;
                        panelDragging = false;
                        return true;
                    case MotionEvent.ACTION_MOVE:
                        float dx = event.getRawX() - panelDragStartRawX;
                        float dy = event.getRawY() - panelDragStartRawY;
                        if (!panelDragging && (Math.abs(dx) > touchSlop || Math.abs(dy) > touchSlop)) {
                            panelDragging = true;
                        }
                        if (panelDragging) {
                            int maxX = rootOverlay.getWidth() - panelView.getWidth();
                            int maxY = rootOverlay.getHeight() - panelView.getHeight();
                            lp.setMarginStart(clampMargin(
                                    panelDragStartMarginStart + (int) dx, 0, maxX));
                            lp.topMargin = clampMargin(
                                    panelDragStartMarginTop + (int) dy, 0, maxY);
                            panelView.setLayoutParams(lp);
                        }
                        return true;
                    case MotionEvent.ACTION_UP:
                    case MotionEvent.ACTION_CANCEL:
                        if (panelDragging) {
                            savePanelPosition(context, lp.getMarginStart(), lp.topMargin);
                            panelDragging = false;
                            return true;
                        }
                        return false;
                    default:
                        return false;
                }
            }
        });
    }

    private static void ensurePanelTopStart(FrameLayout.LayoutParams lp) {
        if (lp.gravity == (Gravity.TOP | Gravity.START)) {
            return;
        }
        int marginStart = (rootOverlay.getWidth() - panelView.getWidth()) / 2;
        int marginTop = (rootOverlay.getHeight() - panelView.getHeight()) / 2;
        lp.gravity = Gravity.TOP | Gravity.START;
        lp.setMarginStart(marginStart);
        lp.topMargin = marginTop;
        panelView.setLayoutParams(lp);
    }

    private static int clampMargin(int value, int min, int max) {
        if (value < min) {
            return min;
        }
        if (value > max) {
            return max;
        }
        return value;
    }

    private static void saveIconPosition(Context context, int marginStart, int marginTop) {
        SPUtils.getInstance(SP_OVERLAY).put(KEY_MARGIN_START, marginStart);
        SPUtils.getInstance(SP_OVERLAY).put(KEY_MARGIN_TOP, marginTop);
        SPUtils.getInstance(SP_OVERLAY).put(KEY_USER_POSITIONED, true);
    }

    private static void savePanelPosition(Context context, int marginStart, int marginTop) {
        SPUtils.getInstance(SP_OVERLAY).put(KEY_PANEL_MARGIN_START, marginStart);
        SPUtils.getInstance(SP_OVERLAY).put(KEY_PANEL_MARGIN_TOP, marginTop);
        SPUtils.getInstance(SP_OVERLAY).put(KEY_PANEL_USER_POSITIONED, true);
    }

    private static boolean isIconUserPositioned(Context context) {
        return SPUtils.getInstance(SP_OVERLAY).getBoolean(KEY_USER_POSITIONED, false);
    }

    private static int loadIconMarginStart(Context context) {
        int v = SPUtils.getInstance(SP_OVERLAY).getInt(KEY_MARGIN_START, dp(context, 20));
        return Math.max(0, v);
    }

    private static int loadIconMarginTop(Context context) {
        int v = SPUtils.getInstance(SP_OVERLAY).getInt(KEY_MARGIN_TOP, dp(context, 20));
        return Math.max(0, v);
    }

    private static boolean isPanelUserPositioned(Context context) {
        return SPUtils.getInstance(SP_OVERLAY).getBoolean(KEY_PANEL_USER_POSITIONED, false);
    }

    private static int loadPanelMarginStart(Context context) {
        int v = SPUtils.getInstance(SP_OVERLAY).getInt(KEY_PANEL_MARGIN_START, 0);
        return Math.max(0, v);
    }

    private static int loadPanelMarginTop(Context context) {
        int v = SPUtils.getInstance(SP_OVERLAY).getInt(KEY_PANEL_MARGIN_TOP, 0);
        return Math.max(0, v);
    }

    private static void showPanel() {
        if (panelView == null) {
            return;
        }
        Context ctx = panelView.getContext();
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) panelView.getLayoutParams();
        if (isPanelUserPositioned(ctx)) {
            lp.gravity = Gravity.TOP | Gravity.START;
            lp.setMarginStart(loadPanelMarginStart(ctx));
            lp.topMargin = loadPanelMarginTop(ctx);
        } else {
            lp.gravity = Gravity.CENTER;
            lp.setMarginStart(0);
            lp.topMargin = 0;
        }
        panelView.setLayoutParams(lp);
        panelView.setVisibility(View.VISIBLE);
        if (dismissScrim != null) {
            dismissScrim.setVisibility(View.VISIBLE);
        }
        panelVisible = true;
        refreshPanelUi();
    }

    private static void hidePanel() {
        if (panelView != null) {
            panelView.setVisibility(View.GONE);
        }
        if (dismissScrim != null) {
            dismissScrim.setVisibility(View.GONE);
        }
        panelVisible = false;
        panelDragging = false;
    }

    private static View buildPanel(final Context context) {
        LinearLayout panel = new LinearLayout(context);
        panel.setOrientation(LinearLayout.VERTICAL);
        GradientDrawable shell = new GradientDrawable();
        shell.setCornerRadius(dp(context, 10));
        shell.setColor(0xC0000000);
        panel.setBackground(shell);
        panel.setPadding(dp(context, 8), dp(context, 8), dp(context, 8), dp(context, 8));
        panel.setElevation(dp(context, 12));

        LinearLayout titleRow = new LinearLayout(context);
        titleRow.setOrientation(LinearLayout.HORIZONTAL);
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        attachPanelDrag(context, titleRow);

        TextView title = new TextView(context);
        title.setText("定位开关");
        title.setTextSize(13f);
        title.setTextColor(Color.WHITE);
        titleRow.addView(title, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

        masterSwitch = new Switch(context);
        masterSwitch.setChecked(LocationBypassHelper.isMasterEnabled());
        masterSwitch.setOnCheckedChangeListener(masterSwitchListener);
        titleRow.addView(masterSwitch, wrapWrap());
        panel.addView(titleRow, matchWrap());

        statusLabel = new TextView(context);
        statusLabel.setTextSize(10f);
        statusLabel.setTextColor(0xEBFFFFFF);
        statusLabel.setPadding(0, dp(context, 4), 0, dp(context, 4));
        panel.addView(statusLabel, matchWrap());

        licenseStatusLabel = new TextView(context);
        licenseStatusLabel.setTextSize(10f);
        licenseStatusLabel.setTextColor(0xFFFFE082);
        licenseStatusLabel.setPadding(0, 0, 0, dp(context, 6));
        panel.addView(licenseStatusLabel, matchWrap());

        LinearLayout dcCard = new LinearLayout(context);
        dcCard.setOrientation(LinearLayout.VERTICAL);
        GradientDrawable dcCardBg = new GradientDrawable();
        dcCardBg.setCornerRadius(dp(context, 8));
        dcCardBg.setColor(0xFF1A2332);
        dcCard.setBackground(dcCardBg);
        dcCard.setPadding(dp(context, 10), dp(context, 8), dp(context, 10), dp(context, 10));

        TextView dcTitle = new TextView(context);
        dcTitle.setText("设备码 · 发给管理员");
        dcTitle.setTextSize(12f);
        dcTitle.setTextColor(0xFFFFE082);
        dcCard.addView(dcTitle, matchWrap());

        TextView dcHint = new TextView(context);
        dcHint.setText("复制 DC1 设备码，用发码工具生成 AK1 卡密");
        dcHint.setTextSize(9f);
        dcHint.setTextColor(0x99FFFFFF);
        dcHint.setPadding(0, dp(context, 2), 0, dp(context, 6));
        dcCard.addView(dcHint, matchWrap());

        deviceCodeLabel = new TextView(context);
        deviceCodeLabel.setTextSize(11f);
        deviceCodeLabel.setTextColor(Color.WHITE);
        deviceCodeLabel.setPadding(dp(context, 8), dp(context, 6), dp(context, 8), dp(context, 6));
        deviceCodeLabel.setTextIsSelectable(true);
        deviceCodeLabel.setSingleLine(true);
        deviceCodeLabel.setHorizontallyScrolling(true);
        GradientDrawable dcBg = new GradientDrawable();
        dcBg.setCornerRadius(dp(context, 6));
        dcBg.setColor(0xFF2C3544);
        deviceCodeLabel.setBackground(dcBg);
        dcCard.addView(deviceCodeLabel, matchWrap());

        TextView copyDeviceCodeBtn = new TextView(context);
        copyDeviceCodeBtn.setText("复制设备码");
        copyDeviceCodeBtn.setTextSize(14f);
        copyDeviceCodeBtn.setTextColor(Color.WHITE);
        copyDeviceCodeBtn.setGravity(Gravity.CENTER);
        copyDeviceCodeBtn.setMinHeight(dp(context, 44));
        copyDeviceCodeBtn.setPadding(dp(context, 12), dp(context, 10), dp(context, 12), dp(context, 10));
        GradientDrawable copyBg = new GradientDrawable();
        copyBg.setCornerRadius(dp(context, 8));
        copyBg.setColor(0xFF1976D2);
        copyDeviceCodeBtn.setBackground(copyBg);
        copyDeviceCodeBtn.setClickable(true);
        copyDeviceCodeBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                copyDeviceCodeToClipboard(context);
            }
        });
        LinearLayout.LayoutParams copyLp = matchWrap();
        copyLp.topMargin = dp(context, 8);
        dcCard.addView(copyDeviceCodeBtn, copyLp);

        LinearLayout.LayoutParams dcCardLp = matchWrap();
        dcCardLp.bottomMargin = dp(context, 6);
        panel.addView(dcCard, dcCardLp);

        LinearLayout actCard = new LinearLayout(context);
        actCard.setOrientation(LinearLayout.VERTICAL);
        GradientDrawable actCardBg = new GradientDrawable();
        actCardBg.setCornerRadius(dp(context, 8));
        actCardBg.setColor(0xFF1A2332);
        actCard.setBackground(actCardBg);
        actCard.setPadding(dp(context, 10), dp(context, 8), dp(context, 10), dp(context, 10));

        TextView actTitle = new TextView(context);
        actTitle.setText("激活卡密 AK1");
        actTitle.setTextSize(12f);
        actTitle.setTextColor(0xFFB9F6CA);
        actCard.addView(actTitle, matchWrap());

        TextView actHint = new TextView(context);
        actHint.setText("粘贴管理员发来的 AK1- 卡密后点下方激活");
        actHint.setTextSize(9f);
        actHint.setTextColor(0x99FFFFFF);
        actHint.setPadding(0, dp(context, 2), 0, dp(context, 6));
        actCard.addView(actHint, matchWrap());

        activationInput = new EditText(context);
        activationInput.setHint("AK1-XXXX-XXXX-...");
        activationInput.setTextSize(13f);
        activationInput.setSingleLine(true);
        activationInput.setHorizontallyScrolling(true);
        activationInput.setMinHeight(dp(context, 48));
        activationInput.setGravity(Gravity.CENTER_VERTICAL);
        activationInput.setTextColor(Color.WHITE);
        activationInput.setHintTextColor(0x88FFFFFF);
        activationInput.setPadding(dp(context, 10), dp(context, 10), dp(context, 10), dp(context, 10));
        GradientDrawable inputBg = new GradientDrawable();
        inputBg.setCornerRadius(dp(context, 6));
        inputBg.setColor(0xFF2C3544);
        activationInput.setBackground(inputBg);
        actCard.addView(activationInput, matchWrap());

        TextView activateBtn = new TextView(context);
        activateBtn.setText("激活卡密");
        activateBtn.setTextSize(14f);
        activateBtn.setTextColor(Color.WHITE);
        activateBtn.setGravity(Gravity.CENTER);
        activateBtn.setMinHeight(dp(context, 44));
        activateBtn.setPadding(dp(context, 12), dp(context, 10), dp(context, 12), dp(context, 10));
        GradientDrawable btnBg = new GradientDrawable();
        btnBg.setCornerRadius(dp(context, 8));
        btnBg.setColor(0xFF2E7D32);
        activateBtn.setBackground(btnBg);
        activateBtn.setClickable(true);
        activateBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                String input = activationInput != null && activationInput.getText() != null
                        ? activationInput.getText().toString()
                        : "";
                String msg = LocationBypassLicenseHelper.tryActivate(input);
                showOverlayToast(context, msg);
                LocationBypassLogHelper.log(msg);
                if (activationInput != null) {
                    activationInput.setText("");
                }
                refreshPanelUi();
            }
        });
        LinearLayout.LayoutParams btnLp = matchWrap();
        btnLp.topMargin = dp(context, 8);
        actCard.addView(activateBtn, btnLp);

        LinearLayout.LayoutParams actCardLp = matchWrap();
        actCardLp.bottomMargin = dp(context, 6);
        panel.addView(actCard, actCardLp);

        stationListScroll = new ScrollView(context);
        stationListInner = new LinearLayout(context);
        stationListInner.setOrientation(LinearLayout.VERTICAL);
        stationListScroll.addView(stationListInner, matchWrap());
        LinearLayout.LayoutParams listLp = matchWrap();
        listLp.bottomMargin = dp(context, 6);
        listLp.height = dp(context, 108);
        panel.addView(stationListScroll, listLp);

        refreshPanelUi();
        return panel;
    }

    private static LinearLayout.LayoutParams matchWrap() {
        return new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    private static LinearLayout.LayoutParams wrapWrap() {
        return new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    private static int dp(Context context, int value) {
        float density = context.getResources().getDisplayMetrics().density;
        return (int) (value * density + 0.5f);
    }

    private static void showOverlayToast(Context context, String message) {
        if (context == null || message == null || message.length() == 0) {
            return;
        }
        try {
            Toast toast = Toast.makeText(context.getApplicationContext(), message, Toast.LENGTH_SHORT);
            toast.setGravity(Gravity.CENTER_HORIZONTAL | Gravity.BOTTOM, 0, dp(context, 72));
            toast.show();
        } catch (Throwable t) {
            LocationBypassLogHelper.log(message);
        }
    }

    private static void copyDeviceCodeToClipboard(Context context) {
        String code = deviceCodeLabel != null ? deviceCodeLabel.getText().toString() : "";
        if (code == null || code.length() == 0) {
            showOverlayToast(context, "设备码为空，请稍候再试");
            return;
        }
        if (!code.startsWith("DC1")) {
            showOverlayToast(context, code);
            return;
        }
        try {
            ClipboardManager cm = (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm != null) {
                cm.setPrimaryClip(ClipData.newPlainText("sec_device_code", code));
                showOverlayToast(context, "已复制设备码，可发给管理员");
                LocationBypassLogHelper.log("设备码已复制");
            } else {
                showOverlayToast(context, "复制失败：剪贴板不可用");
            }
        } catch (Throwable t) {
            showOverlayToast(context, "复制失败");
            LocationBypassLogHelper.log("复制失败");
        }
    }
}
