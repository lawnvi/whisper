package com.vireen.whisper.agent;

import com.genymobile.scrcpy.util.Ln;

import org.json.JSONArray;
import org.json.JSONObject;

import java.lang.reflect.Method;

/**
 * Finds an app that silently swallows every touch on the phone's own screen.
 *
 * Moving a task between displays can leave an activity that is no longer
 * requested visible still marked visible ({@code mVisibleRequested=false
 * mVisible=true}). Its touch sink ({@code ActivityRecordInputSink}) then
 * stays on top of display 0 with no input channel, and the dispatcher drops
 * every touch ("not responsive"): the phone looks frozen. Only that activity
 * becoming visible again, or its task going away, clears it; shell may not
 * start other apps' private activities, so the fix offered is removing the
 * task, after the user agreed on the desktop.
 */
final class TouchGuard {

    /** Apps whose leftover sink blocks touches on display 0, with their task. */
    static JSONArray scan() {
        JSONArray blocked = new JSONArray();
        try {
            for (TouchGuardParser.Blocked app : TouchGuardParser.parse(
                    Shell.run("dumpsys input"), Shell.run("dumpsys activity activities"))) {
                JSONObject entry = new JSONObject();
                entry.put("taskId", app.taskId);
                entry.put("appId", app.appId);
                blocked.put(entry);
            }
        } catch (Exception e) {
            Ln.w("touch guard scan failed: " + e);
        }
        return blocked;
    }

    /** Removes [taskId] (its activities finish; the app stays installed). */
    static boolean removeTask(int taskId) {
        try {
            Class<?> atm = Class.forName("android.app.ActivityTaskManager");
            Object service = atm.getMethod("getService").invoke(null);
            Method remove = service.getClass().getMethod("removeTask", int.class);
            return (boolean) remove.invoke(service, taskId);
        } catch (ReflectiveOperationException | RuntimeException e) {
            Ln.w("removeTask failed: " + e);
            return false;
        }
    }
}
