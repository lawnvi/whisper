package com.vireen.whisper.agent;

import com.genymobile.scrcpy.Workarounds;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.wrappers.ServiceManager;

import android.os.Looper;

import java.io.FileInputStream;
import java.io.IOException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;

/**
 * whisper-agent entry point, run as the shell user with app_process:
 * <ul>
 *   <li>{@code CLASSPATH=<jar> app_process / com.vireen.whisper.agent.AgentMain --daemon}:
 *   the persistent agent, started detached ({@code setsid}, no terminal) so
 *   it outlives adb. One per phone: the abstract socket
 *   {@value AgentServer#DAEMON_SOCKET} is its lock, and a second one exits
 *   at once (status {@link #ALREADY_RUNNING}). It makes its own tokens and
 *   publishes how to reach it in {@link StateFile} (for adb) and to the
 *   phone's Whisper ({@link PhoneApp#link}).</li>
 *   <li>{@code WHISPER_AGENT_TOKEN=<hex> CLASSPATH=<jar> app_process / com.vireen.whisper.agent.AgentMain <socket name>}:
 *   a desktop's own agent, ending with its last session (older desktops).
 *   The token travels in the environment, which only the shell user can
 *   read, never on the command line.</li>
 * </ul>
 * Once it listens the agent prints {@code whisper-agent ready <protocol>}.
 */
public final class AgentMain {

    public static final String VERSION = "2.0.0";

    /** Exit status of a second persistent agent. */
    static final int ALREADY_RUNNING = 3;

    private AgentMain() {
    }

    public static void main(String... args) {
        int status = 0;
        try {
            status = run(args);
        } catch (Throwable t) {
            Ln.e("whisper-agent failed", t);
            status = 1;
        } finally {
            // Framework threads may be non-daemon; exit explicitly.
            System.exit(status);
        }
    }

    private static int run(String... args) throws Exception {
        if (args.length < 1) {
            throw new IllegalArgumentException("usage: AgentMain --daemon | <socket name>");
        }
        boolean persistent = "--daemon".equals(args[0]);
        byte[] token;
        String socketName;
        if (persistent) {
            token = new byte[Wire.TOKEN_BYTES];
            new SecureRandom().nextBytes(token);
            socketName = AgentServer.DAEMON_SOCKET;
        } else {
            token = Wire.parseHex(System.getenv("WHISPER_AGENT_TOKEN"));
            if (token == null || token.length != Wire.TOKEN_BYTES) {
                throw new IllegalArgumentException("missing or malformed WHISPER_AGENT_TOKEN");
            }
            socketName = args[0];
        }
        Ln.initLogLevel(Ln.Level.INFO);
        Looper.prepareMainLooper();
        Workarounds.apply();
        // Created once on the main thread; stream controllers reuse it.
        ServiceManager.getClipboardManager();

        AgentServer server = new AgentServer(socketName, token, persistent, persistent ? jarSha() : "");
        if (!server.start()) {
            System.out.println("whisper-agent already running");
            System.out.flush();
            return ALREADY_RUNNING;
        }
        System.out.println("whisper-agent ready " + Wire.PROTOCOL_VERSION);
        System.out.flush();
        Looper.loop();
        return 0;
    }

    /** SHA-256 of the jar this process runs, so clients can tell builds apart. */
    private static String jarSha() {
        String path = System.getProperty("java.class.path", "");
        if (path.isEmpty() || path.contains(":")) {
            return "";
        }
        try (FileInputStream in = new FileInputStream(path)) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[64 * 1024];
            int read;
            while ((read = in.read(buffer)) > 0) {
                digest.update(buffer, 0, read);
            }
            return Wire.hex(digest.digest());
        } catch (IOException | NoSuchAlgorithmException e) {
            return "";
        }
    }
}
