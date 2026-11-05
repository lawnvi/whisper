package com.vireen.whisper.agent;

import com.genymobile.scrcpy.FakeContext;
import com.genymobile.scrcpy.util.Ln;

import android.content.Context;
import android.content.pm.LauncherApps;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.UserHandle;

/**
 * The system tells the agent when Whisper is uninstalled, so that it never has
 * to keep checking: removing an app leaves this process running, because it is
 * the shell user's and not the app's. A broadcast receiver registered from here
 * got no sign of life on Android 15, and this is public API.
 */
final class WhisperWatch extends LauncherApps.Callback {

    private final AgentServer server;

    private WhisperWatch(AgentServer server) {
        this.server = server;
    }

    /** False when this Android won't have it: the caller then has to check. */
    static boolean start(AgentServer server) {
        try {
            HandlerThread thread = new HandlerThread("whisper-watch");
            thread.setDaemon(true);
            thread.start();
            // Made here, not fetched from the context: the service checks that
            // the package named by the caller is its own, and a fetched one
            // would name the system's.
            LauncherApps apps = LauncherApps.class.getConstructor(Context.class)
                    .newInstance(FakeContext.get());
            apps.registerCallback(new WhisperWatch(server), new Handler(thread.getLooper()));
            Ln.i("watching for Whisper's removal");
            return true;
        } catch (ReflectiveOperationException | RuntimeException e) {
            Ln.w("cannot watch for Whisper's removal: " + e);
            return false;
        }
    }

    @Override
    public void onPackageRemoved(String packageName, UserHandle user) {
        if (PhoneApp.PACKAGE.equals(packageName)) {
            Ln.i("Whisper was removed");
            server.whisperRemoved();
        }
    }

    @Override
    public void onPackageAdded(String packageName, UserHandle user) {
        // Nothing to do.
    }

    @Override
    public void onPackageChanged(String packageName, UserHandle user) {
        // Nothing to do.
    }

    @Override
    public void onPackagesAvailable(String[] packageNames, UserHandle user, boolean replacing) {
        // Nothing to do.
    }

    @Override
    public void onPackagesUnavailable(String[] packageNames, UserHandle user, boolean replacing) {
        // Nothing to do.
    }
}
