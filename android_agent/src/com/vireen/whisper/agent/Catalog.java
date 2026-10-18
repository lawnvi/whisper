package com.vireen.whisper.agent;

import com.genymobile.scrcpy.FakeContext;

import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.SystemClock;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Launchable apps and their icons, from one launcher query (not one lookup per package). */
final class Catalog {

    private static final long CACHE_MS = 60_000;

    private JSONArray cached;
    private long cachedAt;

    static int uidOf(String packageName) {
        try {
            return pm().getApplicationInfo(packageName, 0).uid;
        } catch (PackageManager.NameNotFoundException e) {
            return -1;
        }
    }

    private static PackageManager pm() {
        return FakeContext.get().getPackageManager();
    }

    synchronized JSONArray apps() throws Exception {
        long now = SystemClock.elapsedRealtime();
        if (cached != null && now - cachedAt < CACHE_MS) {
            return cached;
        }
        PackageManager pm = pm();
        Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> activities = pm.queryIntentActivities(launcher, 0);
        Set<String> seen = new HashSet<>();
        JSONArray apps = new JSONArray();
        for (ResolveInfo info : activities) {
            if (info.activityInfo == null) {
                continue;
            }
            ApplicationInfo app = info.activityInfo.applicationInfo;
            if (app == null || !app.enabled || !seen.add(app.packageName)) {
                continue;
            }
            JSONObject entry = new JSONObject();
            entry.put("id", app.packageName);
            entry.put("label", String.valueOf(pm.getApplicationLabel(app)));
            entry.put("system", (app.flags & ApplicationInfo.FLAG_SYSTEM) != 0);
            entry.put("uid", app.uid);
            apps.put(entry);
        }
        cached = apps;
        cachedAt = now;
        return apps;
    }

    /** The app's launcher icon as a square PNG, base64. */
    JSONObject icon(String packageName, int size) throws Exception {
        int edge = Math.max(16, Math.min(size, 512));
        Drawable drawable = pm().getApplicationIcon(packageName);
        Bitmap bitmap = Bitmap.createBitmap(edge, edge, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        drawable.setBounds(0, 0, edge, edge);
        drawable.draw(canvas);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
        bitmap.recycle();
        JSONObject result = new JSONObject();
        result.put("png", Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP));
        return result;
    }
}
