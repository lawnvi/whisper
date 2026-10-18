package com.vireen.whisper.agent;

import com.genymobile.scrcpy.FakeContext;
import com.genymobile.scrcpy.util.Ln;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.UiAutomation;
import android.content.Context;
import android.graphics.Rect;
import android.os.HandlerThread;
import android.os.Looper;
import android.util.SparseArray;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

import org.json.JSONArray;
import org.json.JSONObject;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/**
 * Reads a display's accessibility tree through a shell-side UiAutomation.
 * While it is connected every app sees an accessibility service running,
 * which some banking and anti-fraud SDKs react to, so it connects only when
 * asked and disconnects after {@link #IDLE_MS} without a request.
 */
final class UiTree {

    private static final long IDLE_MS = 30_000;
    private static final int MAX_NODES = 4000;
    private static final int MAX_TEXT = 500;

    static final int FLAG_CLICKABLE = 1;
    static final int FLAG_LONG_CLICKABLE = 1 << 1;
    static final int FLAG_SCROLLABLE = 1 << 2;
    static final int FLAG_EDITABLE = 1 << 3;
    static final int FLAG_FOCUSED = 1 << 4;
    static final int FLAG_CHECKABLE = 1 << 5;
    static final int FLAG_CHECKED = 1 << 6;
    static final int FLAG_SELECTED = 1 << 7;
    static final int FLAG_ENABLED = 1 << 8;
    static final int FLAG_VISIBLE = 1 << 9;

    private final ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor();
    private UiAutomation automation;
    private HandlerThread thread;
    private ScheduledFuture<?> idle;
    private int nodeCount;

    synchronized JSONObject dump(int displayId) throws Exception {
        UiAutomation ui = connect();
        scheduleIdle();
        long start = System.nanoTime();
        SparseArray<List<AccessibilityWindowInfo>> all = ui.getWindowsOnAllDisplays();
        List<AccessibilityWindowInfo> windows = all.get(displayId);
        nodeCount = 0;
        JSONArray roots = new JSONArray();
        if (windows != null) {
            for (AccessibilityWindowInfo window : windows) {
                AccessibilityNodeInfo root = window.getRoot();
                if (root == null) {
                    continue;
                }
                JSONObject entry = new JSONObject();
                entry.put("type", window.getType());
                CharSequence title = window.getTitle();
                if (title != null) {
                    entry.put("title", clip(title));
                }
                entry.put("root", node(root));
                roots.put(entry);
            }
        }
        JSONObject result = new JSONObject();
        result.put("displayId", displayId);
        result.put("windows", roots);
        result.put("nodes", nodeCount);
        result.put("truncated", nodeCount >= MAX_NODES);
        result.put("tookMs", (System.nanoTime() - start) / 1_000_000);
        return result;
    }

    private JSONObject node(AccessibilityNodeInfo info) throws Exception {
        nodeCount++;
        JSONObject node = new JSONObject();
        CharSequence className = info.getClassName();
        if (className != null) {
            String name = className.toString();
            node.put("cls", name.substring(name.lastIndexOf('.') + 1));
        }
        String id = info.getViewIdResourceName();
        if (id != null) {
            node.put("rid", id);
        }
        CharSequence text = info.getText();
        if (text != null && text.length() > 0) {
            node.put("text", clip(text));
        }
        CharSequence desc = info.getContentDescription();
        if (desc != null && desc.length() > 0) {
            node.put("desc", clip(desc));
        }
        Rect bounds = new Rect();
        info.getBoundsInScreen(bounds);
        JSONArray box = new JSONArray();
        box.put(bounds.left);
        box.put(bounds.top);
        box.put(bounds.right);
        box.put(bounds.bottom);
        node.put("bounds", box);
        node.put("flags", flags(info));
        int count = info.getChildCount();
        if (count > 0 && nodeCount < MAX_NODES) {
            JSONArray children = new JSONArray();
            for (int i = 0; i < count && nodeCount < MAX_NODES; i++) {
                AccessibilityNodeInfo child = info.getChild(i);
                if (child != null) {
                    children.put(node(child));
                }
            }
            node.put("children", children);
        }
        return node;
    }

    private static int flags(AccessibilityNodeInfo info) {
        int flags = 0;
        if (info.isClickable()) {
            flags |= FLAG_CLICKABLE;
        }
        if (info.isLongClickable()) {
            flags |= FLAG_LONG_CLICKABLE;
        }
        if (info.isScrollable()) {
            flags |= FLAG_SCROLLABLE;
        }
        if (info.isEditable()) {
            flags |= FLAG_EDITABLE;
        }
        if (info.isFocused()) {
            flags |= FLAG_FOCUSED;
        }
        if (info.isCheckable()) {
            flags |= FLAG_CHECKABLE;
        }
        if (info.isChecked()) {
            flags |= FLAG_CHECKED;
        }
        if (info.isSelected()) {
            flags |= FLAG_SELECTED;
        }
        if (info.isEnabled()) {
            flags |= FLAG_ENABLED;
        }
        if (info.isVisibleToUser()) {
            flags |= FLAG_VISIBLE;
        }
        return flags;
    }

    private static String clip(CharSequence value) {
        String text = value.toString();
        return text.length() > MAX_TEXT ? text.substring(0, MAX_TEXT) : text;
    }

    private UiAutomation connect() throws Exception {
        if (automation != null) {
            return automation;
        }
        thread = new HandlerThread("agent-ui");
        thread.start();
        Class<?> connectionClass = Class.forName("android.app.UiAutomationConnection");
        Object connection = connectionClass.getConstructor().newInstance();
        Class<?> connectionInterface = Class.forName("android.app.IUiAutomationConnection");
        UiAutomation created = null;
        for (Constructor<?> constructor : UiAutomation.class.getDeclaredConstructors()) {
            Class<?>[] types = constructor.getParameterTypes();
            constructor.setAccessible(true);
            if (types.length == 3 && types[0] == Context.class && types[1] == Looper.class && types[2] == connectionInterface) {
                created = (UiAutomation) constructor.newInstance(FakeContext.get(), thread.getLooper(), connection);
                break;
            }
            if (types.length == 2 && types[0] == Looper.class && types[1] == connectionInterface) {
                created = (UiAutomation) constructor.newInstance(thread.getLooper(), connection);
            }
        }
        if (created == null) {
            thread.quitSafely();
            thread = null;
            throw new IllegalStateException("UiAutomation is not available");
        }
        Method connect = UiAutomation.class.getDeclaredMethod("connect", int.class);
        connect.setAccessible(true);
        try {
            connect.invoke(created, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        } catch (Exception e) {
            thread.quitSafely();
            thread = null;
            // Usually another UiAutomation (uiautomator, Appium) already holds the slot.
            throw new IllegalStateException("uiAutomationBusy");
        }
        AccessibilityServiceInfo info = created.getServiceInfo();
        info.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
                | AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
                | AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS;
        created.setServiceInfo(info);
        automation = created;
        return created;
    }

    private void scheduleIdle() {
        if (idle != null) {
            idle.cancel(false);
        }
        idle = timer.schedule(this::release, IDLE_MS, TimeUnit.MILLISECONDS);
    }

    synchronized void release() {
        if (automation != null) {
            try {
                Method disconnect = UiAutomation.class.getDeclaredMethod("disconnect");
                disconnect.setAccessible(true);
                disconnect.invoke(automation);
            } catch (Exception e) {
                Ln.w("UiAutomation disconnect failed: " + e);
            }
            automation = null;
        }
        if (thread != null) {
            thread.quitSafely();
            thread = null;
        }
    }
}
