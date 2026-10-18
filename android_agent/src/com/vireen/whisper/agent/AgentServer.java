package com.vireen.whisper.agent;

import com.genymobile.scrcpy.util.Ln;

import android.net.Credentials;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Process;
import android.os.SystemClock;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/**
 * Accepts connections on one abstract socket: desktops through adb forwards
 * and, in the persistent mode, the phone's own Whisper through the
 * {@link AppLink}. Every connection proves the token first; peers other
 * than root and shell are refused before anything is read.
 *
 * <p>Lifetime:
 * <ul>
 *   <li>A stream belongs to the session that opened it. When that session
 *   goes away, its streams are released {@link #GRACE_MS} later (apps go
 *   back to the phone), so a crashed client never strands apps on hidden
 *   displays.</li>
 *   <li>Session mode (started by a desktop for itself): the agent exits
 *   {@link #GRACE_MS} after its last session ended, as before.</li>
 *   <li>Persistent mode ({@code --daemon}, started detached by a desktop
 *   with adb or by the phone's Whisper over its own wireless debugging):
 *   it outlives adb and the starter, and serves every desktop and the
 *   phone's Whisper. It exits when a client asks ({@code shutdown}: the
 *   user turned the service off on the phone), when Whisper is no longer
 *   installed, or {@link #ORPHAN_EXIT_MS} after the last client of any
 *   kind went away (Whisper killed and never back), which bounds what a
 *   forgotten agent costs.</li>
 * </ul>
 */
final class AgentServer {

    static final long GRACE_MS = 20_000;
    static final long ORPHAN_EXIT_MS = 60 * 60_000L;
    static final String DAEMON_SOCKET = "whisper_agent";
    private static final int HELLO_TIMEOUT_MS = 2_000;

    private final String socketName;
    private final byte[] token;
    private final boolean persistent;
    private final String jarSha;
    private final long startedAt = System.currentTimeMillis();
    private final Map<Integer, AgentStream> streams = new ConcurrentHashMap<>();
    private final List<ControlSession> sessions = new CopyOnWriteArrayList<>();
    private final ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor();
    private ScheduledFuture<?> exitTask;
    private final Catalog catalog = new Catalog();
    private final TaskBridge tasks = new TaskBridge();
    private final UiTree uiTree = new UiTree();
    private final PhoneApp phoneApp = new PhoneApp();
    private AppLink appLink;
    private ScheduledFuture<?> stopPoll;
    /** Window count the phone's Whisper last acknowledged, -1 if unknown. */
    private volatile int reported = -1;
    private volatile String reportedViewer = "";
    private int reportedStreams = 0;
    private volatile boolean linked;
    private volatile int whisperUid = -1;
    private volatile boolean exiting;
    private int linkFailures;

    AgentServer(String socketName, byte[] token, boolean persistent, String jarSha) {
        this.socketName = socketName;
        this.token = token.clone();
        this.persistent = persistent;
        this.jarSha = jarSha == null ? "" : jarSha;
    }

    Catalog catalog() {
        return catalog;
    }

    TaskBridge tasks() {
        return tasks;
    }

    UiTree uiTree() {
        return uiTree;
    }

    boolean persistent() {
        return persistent;
    }

    /** Whisper's uid, looked up again when unknown (installed later). */
    int whisperUid() {
        int uid = whisperUid;
        if (uid < 0) {
            uid = Catalog.uidOf(PhoneApp.PACKAGE);
            whisperUid = uid;
        }
        return uid;
    }

    /** Binds the socket; false when another persistent agent holds it. */
    boolean start() throws IOException {
        final LocalServerSocket server;
        try {
            server = new LocalServerSocket(socketName);
        } catch (IOException e) {
            if (persistent) {
                return false;
            }
            throw e;
        }
        Thread accept = new Thread(() -> {
            while (true) {
                try {
                    LocalSocket socket = server.accept();
                    new Thread(() -> handshake(socket), "agent-hello").start();
                } catch (IOException e) {
                    Ln.e("accept failed", e);
                    shutdown();
                    return;
                }
            }
        }, "agent-accept");
        accept.setDaemon(true);
        accept.start();
        if (persistent) {
            appLink = new AppLink(this, socketName, token);
            appLink.start();
            JSONObject state = new JSONObject();
            try {
                state.put("pid", Process.myPid());
                state.put("protocol", Wire.PROTOCOL_VERSION);
                state.put("version", AgentMain.VERSION);
                state.put("jarSha", jarSha);
                state.put("socket", socketName);
                state.put("token", Wire.hex(token));
                state.put("started", startedAt);
            } catch (org.json.JSONException e) {
                throw new IOException(e);
            }
            StateFile.write(state);
            timer.execute(this::pushLink);
        }
        scheduleExit();
        return true;
    }

    // ------------------------------------------------------------ app link

    /**
     * Tells the phone's Whisper where this agent is. Calling its provider
     * starts the app's process once if it is not running, so it learns this
     * even when nobody has it open (it keeps the link for later). Repeated
     * while it did not take it; afterwards again only when Whisper is
     * running without being connected (its data was cleared, say).
     */
    private void pushLink() {
        if (exiting || appSessions() > 0) {
            schedulePush(60_000);
            return;
        }
        boolean installed = whisperUid() >= 0;
        if (!installed) {
            whisperUid = -1;
            linkFailures++;
            // Whisper was removed: nobody would ever use or stop this agent.
            if (linkFailures >= 3) {
                Ln.i("Whisper is not installed; exiting");
                shutdown();
                return;
            }
            schedulePush(20_000);
            return;
        }
        linkFailures = 0;
        if (!linked || whisperRunning()) {
            linked = phoneApp.link(appLink.port(), appLink.token(), Process.myPid(), jarSha);
        }
        schedulePush(linked ? 60_000 : 5_000);
    }

    private void schedulePush(long delayMs) {
        if (!exiting) {
            timer.schedule(this::pushLink, delayMs, TimeUnit.MILLISECONDS);
        }
    }

    private static boolean whisperRunning() {
        return !Shell.run("pidof " + PhoneApp.PACKAGE).trim().isEmpty();
    }

    int appSessions() {
        int count = 0;
        for (ControlSession session : sessions) {
            if (session.isApp()) {
                count++;
            }
        }
        return count;
    }

    // ------------------------------------------------------------- clients

    private void handshake(LocalSocket socket) {
        try {
            Credentials peer = socket.getPeerCredentials();
            if (peer == null || (peer.getUid() != 0 && peer.getUid() != 2000)) {
                Ln.w("refused peer uid " + (peer == null ? "?" : peer.getUid()));
                socket.close();
                return;
            }
            socket.setSoTimeout(HELLO_TIMEOUT_MS);
            Wire.Hello hello = Wire.readHello(socket.getInputStream(), token);
            if (hello == null) {
                socket.close();
                return;
            }
            socket.setSoTimeout(0);
            if (hello.role == Wire.ROLE_CONTROL) {
                ControlSession session = new ControlSession(this, socket, hello.app);
                sessions.add(session);
                cancelExit();
                scheduleTouchCheck(1000);
                session.run(); // blocks until the client disconnects
                sessions.remove(session);
                sessionEnded(session);
                return;
            }
            AgentStream stream = streams.get(hello.stream);
            if (stream == null) {
                socket.close();
                return;
            }
            switch (hello.role) {
                case Wire.ROLE_VIDEO:
                    stream.attachVideo(socket);
                    break;
                case Wire.ROLE_AUDIO:
                    stream.attachAudio(socket);
                    break;
                case Wire.ROLE_INPUT:
                    stream.attachInput(socket);
                    break;
                default:
                    socket.close();
            }
        } catch (IOException e) {
            closeQuietly(socket);
        }
    }

    /** A client went away: its streams go back to the phone a little later. */
    private void sessionEnded(ControlSession session) {
        List<AgentStream> owned = new ArrayList<>();
        for (AgentStream stream : streams.values()) {
            if (stream.owner() == session) {
                owned.add(stream);
            }
        }
        if (!owned.isEmpty()) {
            timer.schedule(() -> {
                for (AgentStream stream : owned) {
                    stream.close();
                }
            }, GRACE_MS, TimeUnit.MILLISECONDS);
        }
        if (sessions.isEmpty()) {
            scheduleExit();
        }
    }

    AgentStream openStream(int id, JSONObject params, ControlSession owner) throws Exception {
        if (streams.containsKey(id)) {
            throw new IllegalArgumentException("stream " + id + " exists");
        }
        AgentStream stream = new AgentStream(this, id, params, owner);
        streams.put(id, stream);
        streamsChanged();
        return stream;
    }

    AgentStream stream(int id) {
        AgentStream stream = streams.get(id);
        if (stream == null) {
            throw new IllegalArgumentException("no stream " + id);
        }
        return stream;
    }

    List<Integer> streamDisplayIds() {
        List<Integer> ids = new ArrayList<>();
        for (AgentStream stream : streams.values()) {
            int display = stream.displayId();
            if (display >= 0) {
                ids.add(display);
            }
        }
        return ids;
    }

    void forget(AgentStream stream) {
        if (streams.remove(stream.id(), stream)) {
            streamsChanged();
        }
    }

    /** What the agent is doing, for a client deciding whether to replace it. */
    JSONObject status() throws org.json.JSONException {
        JSONObject status = new JSONObject();
        status.put("pid", Process.myPid());
        status.put("protocol", Wire.PROTOCOL_VERSION);
        status.put("version", AgentMain.VERSION);
        status.put("jarSha", jarSha);
        status.put("persistent", persistent);
        status.put("streams", streams.size());
        status.put("appSessions", appSessions());
        status.put("sessions", sessions.size());
        status.put("started", startedAt);
        status.put("uptimeMs", SystemClock.elapsedRealtime());
        return status;
    }

    /** Who the phone's notice names: everyone something is streamed to. */
    private String viewers() {
        Set<String> names = new LinkedHashSet<>();
        for (AgentStream stream : streams.values()) {
            String name = stream.viewer();
            if (!name.isEmpty()) {
                names.add(name);
            }
        }
        return String.join(", ", names);
    }

    /**
     * Keeps the phone's Whisper informed (it shows that the phone is being
     * streamed) and, while anything is streamed, polls it for the user
     * pressing "stop" there.
     */
    synchronized void streamsChanged() {
        final int count = streams.size();
        final String names = viewers();
        timer.execute(() -> {
            reported = phoneApp.report(count, names) ? count : -1;
            reportedViewer = names;
        });
        if (count < reportedStreams) {
            // A window just closed and its task went back to the phone.
            scheduleTouchCheck(1500);
        }
        reportedStreams = count;
        if (count > 0 && stopPoll == null) {
            stopPoll = timer.scheduleWithFixedDelay(this::pollStop, 1, 1, TimeUnit.SECONDS);
        } else if (count == 0 && stopPoll != null) {
            stopPoll.cancel(false);
            stopPoll = null;
        }
    }

    /** Tells desktops when an app left behind blocks the phone's touches. */
    void scheduleTouchCheck(long delayMs) {
        timer.schedule(() -> {
            JSONArray blocked = TouchGuard.scan();
            if (blocked.length() > 0) {
                Ln.w("touches on the phone are blocked by " + blocked);
                JSONObject payload = new JSONObject();
                try {
                    payload.put("apps", blocked);
                } catch (org.json.JSONException e) {
                    return;
                }
                broadcast("touchBlocked", payload);
            }
        }, delayMs, TimeUnit.MILLISECONDS);
    }

    private void pollStop() {
        int count = streams.size();
        String names = viewers();
        if (reported != count || !names.equals(reportedViewer)) {
            // The app was starting or restarting when we last told it.
            reported = phoneApp.report(count, names) ? count : -1;
            reportedViewer = names;
        }
        if (!phoneApp.takeStopRequest()) {
            return;
        }
        Ln.i("stopped from the phone");
        broadcast("stoppedOnPhone", new JSONObject());
        for (AgentStream stream : new ArrayList<>(streams.values())) {
            new Thread(() -> {
                try {
                    stream.closeAndReport(false);
                } catch (Exception e) {
                    Ln.w("stop from the phone: " + e);
                }
            }, "agent-stop").start();
        }
    }

    /** Sends an event to every connected session. */
    void broadcast(String name, JSONObject payload) {
        for (ControlSession session : sessions) {
            session.event(name, payload);
        }
    }

    private synchronized void scheduleExit() {
        cancelExit();
        exitTask = timer.schedule(this::shutdown, persistent ? ORPHAN_EXIT_MS : GRACE_MS, TimeUnit.MILLISECONDS);
    }

    private synchronized void cancelExit() {
        if (exitTask != null) {
            exitTask.cancel(false);
            exitTask = null;
        }
    }

    void shutdown() {
        synchronized (this) {
            if (exiting) {
                return;
            }
            exiting = true;
        }
        Ln.i("whisper-agent exiting");
        if (persistent) {
            StateFile.deleteIfOurs(Process.myPid());
        }
        for (AgentStream stream : new ArrayList<>(streams.values())) {
            stream.close();
        }
        uiTree.release();
        phoneApp.report(0, "");
        phoneApp.release();
        System.exit(0);
    }

    static void closeQuietly(LocalSocket socket) {
        try {
            socket.close();
        } catch (IOException e) {
            // ignore
        }
    }
}
