package com.vireen.whisper.agent;

import com.genymobile.scrcpy.util.Ln;

import android.net.LocalSocket;
import android.os.Build;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * One client's control connection (a desktop over adb, or the phone's own
 * Whisper over the app link): JSON requests
 * {@code {"id":1,"method":"apps","params":{}}}, answered by
 * {@code {"id":1,"result":…}} or {@code {"id":1,"error":"…"}}, plus events
 * {@code {"event":"launched","data":{…}}}. Requests run concurrently so a slow
 * app list never delays a pause.
 */
final class ControlSession {

    private final AgentServer server;
    private final LocalSocket socket;
    private final OutputStream output;
    private final boolean app;
    private final ExecutorService workers = Executors.newCachedThreadPool();

    /** The client's device name, for the phone's "being streamed" notice. */
    private volatile String viewer = "";

    ControlSession(AgentServer server, LocalSocket socket, boolean app) throws IOException {
        this.server = server;
        this.socket = socket;
        this.output = socket.getOutputStream();
        this.app = app;
    }

    /** The phone's own Whisper, through the app link. */
    boolean isApp() {
        return app;
    }

    String viewer() {
        return viewer;
    }

    void run() {
        try {
            InputStream input = socket.getInputStream();
            while (true) {
                String text = Wire.readMessage(input);
                if (text == null) {
                    break;
                }
                final JSONObject request = new JSONObject(text);
                workers.execute(() -> handle(request));
            }
        } catch (Exception e) {
            Ln.w("control session ended: " + e.getMessage());
        } finally {
            workers.shutdownNow();
            AgentServer.closeQuietly(socket);
        }
    }

    private void handle(JSONObject request) {
        long id = request.optLong("id", -1);
        JSONObject params = request.optJSONObject("params");
        if (params == null) {
            params = new JSONObject();
        }
        JSONObject reply = new JSONObject();
        try {
            reply.put("id", id);
            Object result = dispatch(request.optString("method"), params);
            reply.put("result", result == null ? JSONObject.NULL : result);
        } catch (Throwable t) {
            Throwable cause = t.getCause() != null && t instanceof java.lang.reflect.InvocationTargetException ? t.getCause() : t;
            try {
                reply.put("error", String.valueOf(cause.getMessage() != null ? cause.getMessage() : cause.toString()));
            } catch (Exception ignore) {
                // ignore
            }
        }
        send(reply);
    }

    private Object dispatch(String method, JSONObject params) throws Exception {
        switch (method) {
            case "hello":
                viewer = params.optString("viewer", "");
                return hello();
            case "status":
                return server.status();
            case "apps":
                return server.catalog().apps();
            case "icon":
                return server.catalog().icon(params.getString("appId"), params.optInt("size", 96));
            case "tasks":
                return server.tasks().list(server.streamDisplayIds());
            case "snapshot":
                return server.tasks().snapshot(params.getInt("taskId"), params.optInt("maxEdge", 640));
            case "open":
                server.openStream(params.getInt("stream"), params, this);
                return null;
            case "close":
                return server.stream(params.getInt("stream")).closeAndReport(params.optBoolean("terminate", false));
            case "suspend":
                server.stream(params.getInt("stream")).setSuspended(true);
                return null;
            case "resume":
                server.stream(params.getInt("stream")).setSuspended(false);
                return null;
            case "keyframe":
                server.stream(params.getInt("stream")).requestKeyframe();
                return null;
            case "bitRate":
                server.stream(params.getInt("stream")).setBitRate(params.getInt("bitRate"));
                return null;
            case "uiTree":
                return server.uiTree().dump(params.getInt("displayId"));
            case "ping":
                return System.currentTimeMillis();
            case "touchGuard":
                return TouchGuard.scan();
            case "repairTouch":
                return TouchGuard.removeTask(params.getInt("taskId"));
            case "shutdown":
                // Reply first; the agent releases every stream and exits.
                new Thread(() -> {
                    android.os.SystemClock.sleep(100);
                    server.shutdown();
                }, "agent-shutdown").start();
                return null;
            default:
                throw new IllegalArgumentException("unknown method " + method);
        }
    }

    private JSONObject hello() throws Exception {
        JSONObject hello = new JSONObject();
        hello.put("protocol", Wire.PROTOCOL_VERSION);
        hello.put("agentVersion", AgentMain.VERSION);
        hello.put("sdk", Build.VERSION.SDK_INT);
        hello.put("release", Build.VERSION.RELEASE);
        hello.put("manufacturer", Build.MANUFACTURER);
        hello.put("model", Build.MODEL);
        hello.put("persistent", server.persistent());
        hello.put("pid", android.os.Process.myPid());
        com.genymobile.scrcpy.display.DisplayInfo main =
                com.genymobile.scrcpy.wrappers.ServiceManager.getDisplayManager().getDisplayInfo(0);
        if (main != null) {
            JSONObject display = new JSONObject();
            com.genymobile.scrcpy.model.Size size = main.getSize();
            display.put("width", size.getWidth());
            display.put("height", size.getHeight());
            display.put("rotation", main.getRotation());
            display.put("dpi", main.getDpi());
            hello.put("display", display);
        }
        JSONArray capabilities = new JSONArray();
        capabilities.put("icons");
        capabilities.put("tasks");
        capabilities.put("snapshots");
        capabilities.put("suspend");
        capabilities.put("uiTree");
        if (UidAudioCapture.isSupported()) {
            capabilities.put("perAppAudio");
        }
        hello.put("capabilities", capabilities);
        return hello;
    }

    void event(String name, JSONObject data) {
        JSONObject message = new JSONObject();
        try {
            message.put("event", name);
            message.put("data", data);
        } catch (Exception e) {
            return;
        }
        send(message);
    }

    private synchronized void send(JSONObject message) {
        try {
            Wire.writeMessage(output, message.toString());
        } catch (IOException e) {
            AgentServer.closeQuietly(socket);
        }
    }
}
