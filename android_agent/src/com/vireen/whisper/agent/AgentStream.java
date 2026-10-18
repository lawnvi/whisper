package com.vireen.whisper.agent;

import com.genymobile.scrcpy.Options;
import com.genymobile.scrcpy.audio.AudioCodec;
import com.genymobile.scrcpy.audio.AudioRawRecorder;
import com.genymobile.scrcpy.control.ControlChannel;
import com.genymobile.scrcpy.control.Controller;
import com.genymobile.scrcpy.control.PositionMapper;
import com.genymobile.scrcpy.device.Device;
import com.genymobile.scrcpy.device.Streamer;
import com.genymobile.scrcpy.display.DisplayInfo;
import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.video.NewDisplayCapture;
import com.genymobile.scrcpy.video.VideoCodec;
import com.genymobile.scrcpy.video.VirtualDisplayListener;
import com.genymobile.scrcpy.wrappers.ServiceManager;

import android.net.LocalSocket;

import org.json.JSONObject;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * One streamed window: a virtual display (released without destroying its
 * content, so the app returns to the phone's background), its encoder, the
 * app's own audio and an upstream {@link Controller} for input. The desktop
 * attaches the video connection first; the display exists once it does, and
 * the task is moved onto it (or the app started there) right after.
 */
final class AgentStream {

    private static final String SCRCPY_VERSION = "5.0.1";

    private final AgentServer server;
    private final ControlSession owner;
    private final String viewer;
    private final int id;
    private final String appId;
    private final int requestedTaskId;
    private final boolean audioWanted;
    private final int bitRate;
    private final int maxSize;
    private final float maxFps;
    private final Options options;
    private final NewDisplayCapture capture;

    // Guarded by this.
    private boolean closed;
    private boolean launched;
    private int displayId = -1;
    private PositionMapper positionMapper;
    private VideoLoop video;
    private AudioRawRecorder audio;
    private Controller controller;
    private boolean terminateOnClose;
    private int releasedTask = -1;
    private final List<LocalSocket> sockets = new ArrayList<>();

    AgentStream(AgentServer server, int id, JSONObject params, ControlSession owner) {
        this.server = server;
        this.owner = owner;
        String named = params.optString("viewer", "");
        this.viewer = named.isEmpty() && owner != null ? owner.viewer() : named;
        this.id = id;
        this.appId = params.optString("appId", null);
        this.requestedTaskId = params.optInt("taskId", -1);
        this.audioWanted = params.optBoolean("audio", true);
        this.bitRate = params.optInt("bitRate", 8_000_000);
        this.maxSize = params.optInt("maxSize", 0);
        this.maxFps = (float) params.optDouble("maxFps", 60);

        int width = params.optInt("width", 0);
        int height = params.optInt("height", 0);
        int dpi = params.optInt("dpi", 0);
        DisplayInfo main = ServiceManager.getDisplayManager().getDisplayInfo(0);
        if (width <= 0 || height <= 0) {
            Size size = main != null ? main.getSize() : new Size(1080, 2400);
            if (main != null && (main.getRotation() % 2) != 0) {
                size = size.rotate();
            }
            width = size.getWidth();
            height = size.getHeight();
        }
        if (dpi <= 0) {
            dpi = main != null ? main.getDpi() : 420;
        }
        this.options = Options.parse(
                SCRCPY_VERSION,
                "new_display=" + width + "x" + height + "/" + dpi,
                "flex_display=true",
                "vd_destroy_content=false",
                "vd_system_decorations=false",
                "display_ime_policy=hide",
                "keep_active=true",
                "clipboard_autosync=false",
                "power_on=false",
                "audio=false",
                "cleanup=false");
        this.capture = new NewDisplayCapture(new DisplayHook(), options);
    }

    int id() {
        return id;
    }

    /** The session that opened this stream; it ends with it. */
    ControlSession owner() {
        return owner;
    }

    /** Where this window is shown, by device name. */
    String viewer() {
        return viewer;
    }

    synchronized int displayId() {
        return displayId;
    }

    // ------------------------------------------------------------- attaching

    void attachVideo(LocalSocket socket) throws IOException {
        VideoLoop loop;
        synchronized (this) {
            if (closed || video != null) {
                AgentServer.closeQuietly(socket);
                return;
            }
            sockets.add(socket);
            // Status byte: tells the desktop the agent accepted this stream.
            socket.getOutputStream().write(0);
            Streamer streamer = new Streamer(socket.getFileDescriptor(), VideoCodec.H264, true, true);
            loop = new VideoLoop(capture, streamer, bitRate, maxSize, maxFps, new VideoHooks());
            video = loop;
        }
        loop.start();
    }

    void attachAudio(LocalSocket socket) throws IOException {
        Streamer streamer = new Streamer(socket.getFileDescriptor(), AudioCodec.RAW, true, true);
        AudioRawRecorder recorder = null;
        synchronized (this) {
            if (closed || audio != null) {
                AgentServer.closeQuietly(socket);
                return;
            }
            sockets.add(socket);
            int uid = audioWanted && appId != null && UidAudioCapture.isSupported() ? Catalog.uidOf(appId) : -1;
            if (uid >= 0) {
                recorder = new AudioRawRecorder(new UidAudioCapture(uid), streamer);
                audio = recorder;
            }
        }
        if (recorder == null) {
            streamer.writeDisableStream(false);
            return;
        }
        recorder.start(fatalError -> Ln.d("stream " + id + " audio ended"));
    }

    void attachInput(LocalSocket socket) throws IOException {
        Controller created = new Controller(new ControlChannel(socket), null, options);
        created.setSurfaceCapture(capture);
        int display;
        PositionMapper mapper;
        synchronized (this) {
            if (closed || controller != null) {
                AgentServer.closeQuietly(socket);
                return;
            }
            sockets.add(socket);
            controller = created;
            display = displayId;
            mapper = positionMapper;
        }
        if (display >= 0) {
            created.onNewVirtualDisplay(display, mapper);
        }
        created.start(fatalError -> Ln.d("stream " + id + " input ended"));
    }

    private final class DisplayHook implements VirtualDisplayListener {
        @Override
        public void onNewVirtualDisplay(int newDisplayId, PositionMapper mapper) {
            Controller target;
            boolean first;
            synchronized (AgentStream.this) {
                displayId = newDisplayId;
                positionMapper = mapper;
                target = controller;
                first = !launched;
                launched = true;
            }
            if (target != null) {
                target.onNewVirtualDisplay(newDisplayId, mapper);
            }
            if (first) {
                new Thread(() -> launch(newDisplayId), "agent-launch").start();
            }
        }
    }

    /** Moves the requested (or a running) task onto the display, else starts the app there. */
    private void launch(int display) {
        int task = requestedTaskId;
        if (task < 0 && appId != null) {
            task = server.tasks().findMovable(appId, server.streamDisplayIds());
        }
        boolean moved = task >= 0 && server.tasks().moveToDisplay(task, display);
        if (!moved && appId != null) {
            Device.startApp(appId, display, false);
        }
        JSONObject data = new JSONObject();
        try {
            data.put("stream", id);
            data.put("displayId", display);
            data.put("taskId", moved ? task : -1);
            data.put("moved", moved);
        } catch (Exception e) {
            return;
        }
        server.broadcast("launched", data);
    }

    // --------------------------------------------------------------- control

    void setSuspended(boolean value) {
        VideoLoop loop;
        synchronized (this) {
            loop = video;
        }
        if (loop != null) {
            loop.setSuspended(value);
        }
    }

    void requestKeyframe() {
        VideoLoop loop;
        synchronized (this) {
            loop = video;
        }
        if (loop != null) {
            loop.requestKeyframe();
        }
    }

    void setBitRate(int value) {
        VideoLoop loop;
        synchronized (this) {
            loop = video;
        }
        if (loop != null) {
            loop.setBitRate(value);
        }
    }

    /** Closes the stream and reports which task was on its display. */
    JSONObject closeAndReport(boolean terminate) throws Exception {
        int display = displayId();
        synchronized (this) {
            terminateOnClose = terminate;
        }
        close();
        JSONObject result = new JSONObject();
        result.put("displayId", display);
        synchronized (this) {
            result.put("taskId", releasedTask);
        }
        return result;
    }

    private final class VideoHooks implements VideoLoop.Listener {
        private TaskBridge.Front front;

        @Override
        public void beforeRelease() {
            int display = displayId();
            if (display < 0) {
                return;
            }
            int task = server.tasks().topTaskOn(display);
            boolean terminate;
            synchronized (AgentStream.this) {
                releasedTask = task;
                terminate = terminateOnClose;
            }
            if (!terminate) {
                front = server.tasks().frontOnPhone();
            }
        }

        @Override
        public void afterRelease() {
            int task;
            boolean terminate;
            synchronized (AgentStream.this) {
                task = releasedTask;
                terminate = terminateOnClose;
            }
            if (terminate) {
                if (appId != null) {
                    Shell.run("am force-stop " + appId);
                }
            } else {
                server.tasks().keepInBackground(task, front);
            }
        }

        @Override
        public void onVideoEnded() {
            close();
        }
    }

    void close() {
        VideoLoop loop;
        AudioRawRecorder recorder;
        Controller input;
        List<LocalSocket> open;
        synchronized (this) {
            if (closed) {
                return;
            }
            closed = true;
            loop = video;
            recorder = audio;
            input = controller;
            open = new ArrayList<>(sockets);
            sockets.clear();
        }
        if (input != null) {
            input.stop();
        }
        if (recorder != null) {
            recorder.stop();
        }
        if (loop != null) {
            loop.stop();
        }
        // Half-close first: blocked writers fail with a broken pipe (quietly)
        // instead of writing to a closed descriptor.
        for (LocalSocket socket : open) {
            shutdown(socket);
        }
        if (loop != null) {
            // The loop releases the display and restores the phone's front
            // task before it ends; wait so the caller sees the final state.
            loop.join(4000);
        }
        if (recorder != null) {
            final AudioRawRecorder ending = recorder;
            Thread reaper = new Thread(() -> {
                try {
                    ending.join();
                } catch (InterruptedException e) {
                    // ignore
                }
                for (LocalSocket socket : open) {
                    AgentServer.closeQuietly(socket);
                }
            }, "agent-reaper");
            reaper.setDaemon(true);
            reaper.start();
        } else {
            for (LocalSocket socket : open) {
                AgentServer.closeQuietly(socket);
            }
        }
        server.forget(this);
        JSONObject data = new JSONObject();
        try {
            data.put("stream", id);
        } catch (Exception e) {
            return;
        }
        server.broadcast("closed", data);
    }

    private static void shutdown(LocalSocket socket) {
        try {
            socket.shutdownInput();
        } catch (IOException e) {
            // ignore
        }
        try {
            socket.shutdownOutput();
        } catch (IOException e) {
            // ignore
        }
    }
}
