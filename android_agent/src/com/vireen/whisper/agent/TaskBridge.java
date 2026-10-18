package com.vireen.whisper.agent;

import android.app.ActivityManager;
import android.content.ComponentName;
import android.graphics.Bitmap;
import android.graphics.ColorSpace;
import android.hardware.HardwareBuffer;
import android.os.IBinder;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

/**
 * Recent tasks, moving tasks between displays and task snapshots, through
 * IActivityTaskManager. Hidden signatures differ between releases, so every
 * call looks its method up by name and shape.
 */
final class TaskBridge {

    private static final int RECENT_IGNORE_UNAVAILABLE = 0x0002;
    private static final int RESOLUTION_HIGH = 1;
    private static final int RESOLUTION_LOW = 2;

    private Object service;

    private synchronized Object service() throws Exception {
        if (service == null) {
            service = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null);
        }
        return service;
    }

    static final class Task {
        int taskId;
        String packageName;
        String component;
        int displayId = -1;
        boolean running;
        boolean visible;
        long lastActive;
    }

    List<Task> recent() throws Exception {
        Object atm = service();
        Method getRecent = null;
        for (Method method : atm.getClass().getMethods()) {
            if (method.getName().equals("getRecentTasks") && method.getParameterTypes().length == 3) {
                getRecent = method;
            }
        }
        if (getRecent == null) {
            throw new NoSuchMethodException("getRecentTasks");
        }
        Object slice = getRecent.invoke(atm, 64, RECENT_IGNORE_UNAVAILABLE, 0);
        @SuppressWarnings("unchecked")
        List<Object> list = (List<Object>) slice.getClass().getMethod("getList").invoke(slice);
        List<Task> tasks = new ArrayList<>();
        for (Object item : list) {
            ActivityManager.RecentTaskInfo info = (ActivityManager.RecentTaskInfo) item;
            ComponentName component = info.baseActivity;
            if (component == null && info.baseIntent != null) {
                component = info.baseIntent.getComponent();
            }
            if (component == null || info.taskId <= 0) {
                continue;
            }
            Task task = new Task();
            task.taskId = info.taskId;
            task.packageName = component.getPackageName();
            task.component = component.flattenToShortString();
            task.displayId = intField(info, "displayId", -1);
            task.running = boolField(info, "isRunning", true);
            task.visible = boolField(info, "isVisible", false);
            task.lastActive = longField(info, "lastActiveTime", 0);
            tasks.add(task);
        }
        return tasks;
    }

    JSONArray list(List<Integer> streamedDisplays) throws Exception {
        JSONArray result = new JSONArray();
        for (Task task : recent()) {
            JSONObject entry = new JSONObject();
            entry.put("taskId", task.taskId);
            entry.put("appId", task.packageName);
            entry.put("component", task.component);
            entry.put("displayId", task.displayId);
            entry.put("running", task.running);
            entry.put("visible", task.visible);
            entry.put("lastActive", task.lastActive);
            entry.put("streamed", task.displayId > 0 && streamedDisplays.contains(task.displayId));
            result.put(entry);
        }
        return result;
    }

    /** The most recent running task of [packageName] that no stream shows yet, or -1. */
    int findMovable(String packageName, List<Integer> streamedDisplays) {
        try {
            Task best = null;
            for (Task task : recent()) {
                if (!task.running || !task.packageName.equals(packageName) || streamedDisplays.contains(task.displayId)) {
                    continue;
                }
                if (best == null || task.lastActive > best.lastActive) {
                    best = task;
                }
            }
            return best == null ? -1 : best.taskId;
        } catch (Exception e) {
            return -1;
        }
    }

    /** The task shown on [displayId], or -1. */
    int topTaskOn(int displayId) {
        try {
            Task best = null;
            for (Task task : recent()) {
                if (task.running && task.displayId == displayId && (best == null || task.lastActive > best.lastActive)) {
                    best = task;
                }
            }
            return best == null ? -1 : best.taskId;
        } catch (Exception e) {
            return -1;
        }
    }

    /** What the phone's own screen shows in front. */
    static final class Front {
        int taskId;
        boolean home;
        String component;
    }

    private static final int ACTIVITY_TYPE_HOME = 2;

    /** The task in front on the phone's screen (display 0), home included, or null. */
    Front frontOnPhone() {
        try {
            Object atm = service();
            Method getTasks = null;
            for (Method method : atm.getClass().getMethods()) {
                Class<?>[] types = method.getParameterTypes();
                if (method.getName().equals("getTasks") && types.length >= 1 && types[0] == int.class
                        && (getTasks == null || types.length > getTasks.getParameterTypes().length)) {
                    getTasks = method;
                }
            }
            if (getTasks == null) {
                return null;
            }
            Class<?>[] types = getTasks.getParameterTypes();
            Object[] args = new Object[types.length];
            args[0] = 32;
            for (int i = 1; i < types.length; i++) {
                // (maxNum, filterOnlyVisibleRecents, keepIntentExtra[, displayId = INVALID_DISPLAY])
                args[i] = types[i] == boolean.class ? (Object) Boolean.FALSE : (Object) (-1);
            }
            @SuppressWarnings("unchecked")
            List<Object> list = (List<Object>) getTasks.invoke(atm, args);
            // Running tasks come top-most first.
            for (Object info : list) {
                if (intField(info, "displayId", 0) != 0) {
                    continue;
                }
                ActivityManager.RunningTaskInfo task = (ActivityManager.RunningTaskInfo) info;
                Front front = new Front();
                front.taskId = task.taskId;
                front.home = intField(info, "topActivityType", 0) == ACTIVITY_TYPE_HOME;
                ComponentName component = task.baseActivity != null ? task.baseActivity : task.topActivity;
                front.component = component == null ? null : component.flattenToShortString();
                return front;
            }
        } catch (Exception e) {
            // Unknown release: no restore.
        }
        return null;
    }

    /**
     * Some releases (Android 13) put a released display's task in front on
     * the phone; Android 17 does not. Bring back what was in front so the
     * streamed app only returns to the background.
     */
    void keepInBackground(int streamedTask, Front previous) {
        if (streamedTask < 0) {
            return;
        }
        for (int attempt = 0; attempt < 6; attempt++) {
            android.os.SystemClock.sleep(120);
            Front now = frontOnPhone();
            if (now == null || now.taskId != streamedTask) {
                if (attempt > 1) {
                    return;
                }
                continue;
            }
            if (previous == null || previous.home || previous.taskId == streamedTask) {
                Shell.run("am start -a android.intent.action.MAIN -c android.intent.category.HOME -f 0x10000000");
            } else if (!startFromRecents(previous.taskId) && previous.component != null) {
                Shell.run("am start -n " + previous.component + " -f 0x10200000");
            }
            return;
        }
    }

    private boolean startFromRecents(int taskId) {
        try {
            Object atm = service();
            for (Method method : atm.getClass().getMethods()) {
                Class<?>[] types = method.getParameterTypes();
                if (method.getName().equals("startActivityFromRecents") && types.length == 2 && types[0] == int.class) {
                    method.invoke(atm, taskId, null);
                    return true;
                }
            }
        } catch (Exception e) {
            // Not allowed for shell on this release.
        }
        return false;
    }

    boolean moveToDisplay(int taskId, int displayId) {
        try {
            Object atm = service();
            for (String name : new String[] {"moveRootTaskToDisplay", "moveStackToDisplay"}) {
                for (Method method : atm.getClass().getMethods()) {
                    Class<?>[] types = method.getParameterTypes();
                    if (method.getName().equals(name) && types.length == 2 && types[0] == int.class && types[1] == int.class) {
                        method.invoke(atm, taskId, displayId);
                        return true;
                    }
                }
            }
        } catch (Exception e) {
            // Fall back to the shell command below.
        }
        String out = Shell.run("am display move-stack " + taskId + " " + displayId);
        return !out.contains("Exception") && !out.contains("Error");
    }

    /** A JPEG of the task's last frame, scaled so its long edge is at most [maxEdge]. */
    JSONObject snapshot(int taskId, int maxEdge) throws Exception {
        Object snapshot = takeSnapshot(taskId);
        if (snapshot == null) {
            return null;
        }
        HardwareBuffer buffer = hardwareBuffer(snapshot);
        if (buffer == null) {
            return null;
        }
        ColorSpace colorSpace = colorSpace(snapshot);
        Bitmap wrapped = Bitmap.wrapHardwareBuffer(buffer, colorSpace);
        if (wrapped == null) {
            return null;
        }
        Bitmap soft = wrapped.copy(Bitmap.Config.ARGB_8888, false);
        wrapped.recycle();
        int width = soft.getWidth();
        int height = soft.getHeight();
        int edge = Math.max(width, height);
        if (maxEdge > 0 && edge > maxEdge) {
            float scale = maxEdge / (float) edge;
            Bitmap scaled = Bitmap.createScaledBitmap(soft, Math.max(1, Math.round(width * scale)), Math.max(1, Math.round(height * scale)), true);
            soft.recycle();
            soft = scaled;
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        soft.compress(Bitmap.CompressFormat.JPEG, 82, out);
        JSONObject result = new JSONObject();
        result.put("jpeg", Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP));
        result.put("width", soft.getWidth());
        result.put("height", soft.getHeight());
        soft.recycle();
        return result;
    }

    private Object takeSnapshot(int taskId) throws Exception {
        Object atm = service();
        // Android 17: snapshots moved to ITaskSnapshotManager.
        try {
            Object binder = atm.getClass().getMethod("getTaskSnapshotManager").invoke(atm);
            if (binder != null) {
                Object manager = binder;
                if (binder instanceof IBinder) {
                    String descriptor = ((IBinder) binder).getInterfaceDescriptor();
                    manager = Class.forName(descriptor + "$Stub").getMethod("asInterface", IBinder.class).invoke(null, binder);
                }
                Method get = manager.getClass().getMethod("getTaskSnapshot", int.class, long.class, int.class);
                for (int resolution : new int[] {RESOLUTION_LOW, RESOLUTION_HIGH}) {
                    try {
                        Object snapshot = get.invoke(manager, taskId, 0L, resolution);
                        if (snapshot != null && hardwareBuffer(snapshot) != null) {
                            return snapshot;
                        }
                    } catch (Exception e) {
                        // Try the other resolution.
                    }
                }
            }
        } catch (NoSuchMethodException e) {
            // Older release: below.
        }
        for (Method method : atm.getClass().getMethods()) {
            if (!method.getName().equals("getTaskSnapshot")) {
                continue;
            }
            Class<?>[] types = method.getParameterTypes();
            if (types.length < 2 || types[0] != int.class) {
                continue;
            }
            Object[] args = new Object[types.length];
            args[0] = taskId;
            for (int i = 1; i < types.length; i++) {
                // (taskId, isLowResolution[, takeSnapshotIfNeeded])
                args[i] = types[i] == boolean.class ? (Object) Boolean.valueOf(i == 1 || i == 2) : null;
            }
            try {
                Object snapshot = method.invoke(atm, args);
                if (snapshot != null) {
                    return snapshot;
                }
            } catch (Exception e) {
                // Try the next overload.
            }
        }
        return null;
    }

    private static HardwareBuffer hardwareBuffer(Object snapshot) {
        try {
            Object value = snapshot.getClass().getMethod("getHardwareBuffer").invoke(snapshot);
            if (value instanceof HardwareBuffer) {
                return (HardwareBuffer) value;
            }
        } catch (Exception e) {
            // Fall back to the field.
        }
        Object value = field(snapshot, "mSnapshot");
        if (value instanceof HardwareBuffer) {
            return (HardwareBuffer) value;
        }
        if (value != null) {
            // Android 10 and 11 keep a GraphicBuffer.
            try {
                Method convert = HardwareBuffer.class.getMethod("createFromGraphicBuffer", value.getClass());
                return (HardwareBuffer) convert.invoke(null, value);
            } catch (Exception e) {
                return null;
            }
        }
        return null;
    }

    private static ColorSpace colorSpace(Object snapshot) {
        try {
            Object value = snapshot.getClass().getMethod("getColorSpace").invoke(snapshot);
            if (value instanceof ColorSpace) {
                return (ColorSpace) value;
            }
        } catch (Exception e) {
            // Fall back to the field.
        }
        Object value = field(snapshot, "mColorSpace");
        return value instanceof ColorSpace ? (ColorSpace) value : ColorSpace.get(ColorSpace.Named.SRGB);
    }

    private static Object field(Object target, String name) {
        for (Class<?> type = target.getClass(); type != null; type = type.getSuperclass()) {
            try {
                Field field = type.getDeclaredField(name);
                field.setAccessible(true);
                return field.get(target);
            } catch (NoSuchFieldException e) {
                // Look in the superclass.
            } catch (IllegalAccessException e) {
                return null;
            }
        }
        return null;
    }

    private static int intField(Object target, String name, int fallback) {
        Object value = field(target, name);
        return value instanceof Integer ? (Integer) value : fallback;
    }

    private static boolean boolField(Object target, String name, boolean fallback) {
        Object value = field(target, name);
        return value instanceof Boolean ? (Boolean) value : fallback;
    }

    private static long longField(Object target, String name, long fallback) {
        Object value = field(target, name);
        return value instanceof Long ? (Long) value : fallback;
    }
}
