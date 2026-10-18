package com.vireen.whisper.agent;

import com.genymobile.scrcpy.FakeContext;
import com.genymobile.scrcpy.util.Ln;

import android.content.AttributionSource;
import android.content.IContentProvider;
import android.content.pm.ProviderInfo;
import android.os.Binder;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * Talks to the Whisper app installed on this phone through its window-stream
 * provider, which only answers root and shell. The app shows that the phone
 * is being streamed (an ongoing notification, a status-bar chip where the
 * system has one), lets the user stop everything from there, and learns how
 * to reach a persistent agent ({@link #link}).
 *
 * <p>The link token goes to whoever holds the provider's authority, so the
 * holder must be the Whisper package itself (a different app could claim
 * the authority while Whisper is not installed).
 */
final class PhoneApp {

    static final String AUTHORITY = "com.vireen.whisper.window_stream";
    static final String PACKAGE = "com.vireen.whisper";

    private final Object lock = new Object();
    private IContentProvider provider;
    private IBinder token;
    private Method call;
    private boolean modernCall;

    /**
     * Tells the app how many windows are streamed and to whom; 0 ends it.
     * False when the app could not be reached (try again later).
     */
    boolean report(int windows, String viewer) {
        Bundle extras = new Bundle();
        extras.putInt("windows", windows);
        extras.putString("viewer", viewer);
        return call("report", extras) != null;
    }

    /** True once the user pressed stop on the phone (cleared by reading). */
    boolean takeStopRequest() {
        Bundle result = call("takeStop", new Bundle());
        return result != null && result.getBoolean("stop", false);
    }

    /**
     * Hands the app the way to this agent: loopback [port] and the link
     * token, with what it needs to tell agents apart. True once it took it.
     */
    boolean link(int port, byte[] linkToken, int pid, String jarSha) {
        Bundle extras = new Bundle();
        extras.putInt("port", port);
        extras.putByteArray("token", linkToken);
        extras.putInt("pid", pid);
        extras.putInt("protocol", Wire.PROTOCOL_VERSION);
        extras.putString("version", AgentMain.VERSION);
        extras.putString("jarSha", jarSha);
        Bundle result = call("link", extras);
        return result != null && result.getBoolean("ok", false);
    }

    private Bundle call(String method, Bundle extras) {
        synchronized (lock) {
            try {
                if (provider == null && !connect()) {
                    return null;
                }
                Object[] args = modernCall
                        ? new Object[]{FakeContext.get().getAttributionSource(), AUTHORITY, method, null, extras}
                        : new Object[]{FakeContext.PACKAGE_NAME, null, AUTHORITY, method, null, extras};
                return (Bundle) call.invoke(provider, args);
            } catch (ReflectiveOperationException | RuntimeException e) {
                // The app may have been killed or updated; reconnect next time.
                Ln.w("phone app call failed: " + e);
                release();
                return null;
            }
        }
    }

    private boolean connect() throws ReflectiveOperationException {
        IBinder newToken = new Binder();
        Object holder = providerHolder(newToken);
        if (holder == null) {
            return false;
        }
        Field providerField = holder.getClass().getDeclaredField("provider");
        providerField.setAccessible(true);
        Field infoField = holder.getClass().getDeclaredField("info");
        infoField.setAccessible(true);
        IContentProvider found = (IContentProvider) providerField.get(holder);
        ProviderInfo info = (ProviderInfo) infoField.get(holder);
        int uid = Catalog.uidOf(PACKAGE);
        if (found == null || info == null || !PACKAGE.equals(info.packageName) || info.applicationInfo == null
                || info.applicationInfo.uid != uid) {
            Ln.w("window-stream provider is not Whisper's: " + (info == null ? "?" : info.packageName));
            removeExternal(newToken);
            return false;
        }
        if (Build.VERSION.SDK_INT >= 31) {
            call = found.getClass().getMethod("call", AttributionSource.class, String.class, String.class, String.class,
                    Bundle.class);
            modernCall = true;
        } else {
            call = found.getClass().getMethod("call", String.class, String.class, String.class, String.class, String.class,
                    Bundle.class);
            modernCall = false;
        }
        provider = found;
        token = newToken;
        return true;
    }

    /** IActivityManager.getContentProviderExternal(authority, user 0, token, tag). */
    private static Object providerHolder(IBinder token) throws ReflectiveOperationException {
        Object manager = activityManager();
        for (Method method : manager.getClass().getMethods()) {
            if (!method.getName().equals("getContentProviderExternal")) {
                continue;
            }
            Class<?>[] types = method.getParameterTypes();
            if (types.length == 4) {
                return method.invoke(manager, AUTHORITY, 0, token, null);
            }
            if (types.length == 3) {
                return method.invoke(manager, AUTHORITY, 0, token);
            }
        }
        throw new NoSuchMethodException("getContentProviderExternal");
    }

    private static Object activityManager() throws ReflectiveOperationException {
        return Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
    }

    private static void removeExternal(IBinder providerToken) {
        try {
            Object manager = activityManager();
            Method remove = manager.getClass().getMethod("removeContentProviderExternal", String.class, IBinder.class);
            remove.invoke(manager, AUTHORITY, providerToken);
        } catch (ReflectiveOperationException | RuntimeException e) {
            // The reference goes away with this process anyway.
        }
    }

    void release() {
        synchronized (lock) {
            if (provider != null) {
                removeExternal(token);
            }
            provider = null;
            token = null;
            call = null;
        }
    }
}
