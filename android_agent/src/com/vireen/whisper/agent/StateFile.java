package com.vireen.whisper.agent;

import com.genymobile.scrcpy.util.Ln;

import android.system.ErrnoException;
import android.system.Os;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * Where a running persistent agent tells adb clients (desktops, the phone's
 * own adb self-start) how to reach it: its pid, socket name, protocol, jar
 * and the adb token. The folder is the shell user's (mode 0700, file 0600):
 * apps can neither list nor read it.
 */
final class StateFile {

    static final String DIR = "/data/local/tmp/whisper-agent";
    static final String PATH = DIR + "/state.json";

    private StateFile() {
    }

    static void write(JSONObject state) throws IOException {
        File dir = new File(DIR);
        if (!dir.isDirectory() && !dir.mkdirs()) {
            throw new IOException("cannot create " + DIR);
        }
        File temp = new File(DIR, "state.json.tmp");
        try {
            Os.chmod(DIR, 0700);
            try (FileOutputStream out = new FileOutputStream(temp)) {
                // Private before anything secret is in it.
                Os.chmod(temp.getPath(), 0600);
                out.write(state.toString().getBytes(StandardCharsets.UTF_8));
                out.getFD().sync();
            }
            Os.rename(temp.getPath(), PATH);
        } catch (ErrnoException e) {
            throw new IOException(e);
        }
    }

    /**
     * Everything a start left on the phone: it is the shell user's, so removing
     * the app doesn't touch it. The running jar stays mapped until the exit.
     */
    static void deleteAll() {
        File dir = new File(DIR);
        File[] state = dir.listFiles();
        if (state != null) {
            for (File file : state) {
                file.delete();
            }
        }
        dir.delete();
        File[] jars = dir.getParentFile().listFiles(
                (parent, name) -> name.startsWith("whisper-agent-") && name.endsWith(".jar"));
        if (jars != null) {
            for (File jar : jars) {
                jar.delete();
            }
        }
    }

    /** Removes the file if it still describes this process. */
    static void deleteIfOurs(int pid) {
        try {
            String text = new String(java.nio.file.Files.readAllBytes(new File(PATH).toPath()), StandardCharsets.UTF_8);
            if (new JSONObject(text).optInt("pid", -1) == pid && !new File(PATH).delete()) {
                Ln.w("could not remove " + PATH);
            }
        } catch (Exception e) {
            // Gone already, or another agent's.
        }
    }
}
