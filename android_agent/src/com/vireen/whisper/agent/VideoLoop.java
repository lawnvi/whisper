package com.vireen.whisper.agent;

import com.genymobile.scrcpy.device.Streamer;
import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.util.IO;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.video.CaptureControl;
import com.genymobile.scrcpy.video.SurfaceCapture;
import com.genymobile.scrcpy.video.VideoConstraints;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Bundle;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Surface;

import java.io.IOException;
import java.nio.ByteBuffer;

/**
 * Encodes one stream's virtual display, like upstream's SurfaceEncoder, but
 * keeps the running codec reachable so a window can be paused
 * ({@link MediaCodec#PARAMETER_KEY_SUSPEND}: the app keeps running, nothing is
 * sent), asked for a keyframe or given a new bit rate without restarting the
 * encoder.
 */
final class VideoLoop {

    interface Listener {
        /** The display still exists; the loop is about to release it. */
        void beforeRelease();

        /** The display is gone; its tasks are back on the phone. */
        void afterRelease();

        void onVideoEnded();
    }

    private static final int I_FRAME_INTERVAL_S = 10;
    private static final long REPEAT_FRAME_DELAY_US = 100_000;
    private static final int MAX_CONSECUTIVE_ERRORS = 3;

    private final SurfaceCapture capture;
    private final Streamer streamer;
    private final int maxSize;
    private final float maxFps;
    private final Listener listener;
    private final CaptureControl captureControl = new CaptureControl();

    private Thread thread;
    private volatile boolean stopped;

    // Guarded by this.
    private MediaCodec running;
    private boolean suspended;
    private int bitRate;

    VideoLoop(SurfaceCapture capture, Streamer streamer, int bitRate, int maxSize, float maxFps, Listener listener) {
        this.capture = capture;
        this.streamer = streamer;
        this.bitRate = bitRate;
        this.maxSize = maxSize;
        this.maxFps = maxFps;
        this.listener = listener;
    }

    void start() {
        thread = new Thread(() -> {
            // Some devices deadlock if the encoding thread has no Looper.
            Looper.prepare();
            try {
                stream();
            } catch (Throwable t) {
                if (!(t instanceof IOException && IO.isBrokenPipe((IOException) t)) && !stopped) {
                    Ln.e("video loop failed", t);
                }
            } finally {
                listener.onVideoEnded();
            }
        }, "agent-video");
        thread.start();
    }

    void stop() {
        stopped = true;
        captureControl.reset(CaptureControl.RESET_REASON_TERMINATED);
    }

    /** Waits for the loop to end; a no-op on the loop's own thread (its exit listener). */
    void join(long millis) {
        if (thread != null && thread != Thread.currentThread()) {
            try {
                thread.join(millis);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }

    synchronized void setSuspended(boolean value) {
        suspended = value;
        if (running != null) {
            applySuspend(running, value);
        }
    }

    synchronized void requestKeyframe() {
        if (running != null && !suspended) {
            Bundle params = new Bundle();
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
            setParameters(running, params);
        }
    }

    synchronized void setBitRate(int value) {
        bitRate = value;
        if (running != null) {
            Bundle params = new Bundle();
            params.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, value);
            setParameters(running, params);
        }
    }

    private static void applySuspend(MediaCodec codec, boolean value) {
        Bundle params = new Bundle();
        params.putInt(MediaCodec.PARAMETER_KEY_SUSPEND, value ? 1 : 0);
        if (!value) {
            // The viewer kept the last frame; continue from a clean picture.
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
        }
        setParameters(codec, params);
    }

    private static void setParameters(MediaCodec codec, Bundle params) {
        try {
            codec.setParameters(params);
        } catch (IllegalStateException e) {
            // The codec is being reset; the next session picks the values up.
        }
    }

    private void stream() throws Exception {
        MediaCodec codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        MediaCodecInfo.VideoCapabilities caps =
                codec.getCodecInfo().getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).getVideoCapabilities();
        int alignment = Math.max(8, Math.max(caps.getWidthAlignment(), caps.getHeightAlignment()));
        capture.init(captureControl, new VideoConstraints(maxSize, Integer.highestOneBit(alignment), null));
        int consecutiveErrors = 0;
        try {
            streamer.writeVideoHeader();
            boolean alive = true;
            while (alive) {
                int reasons = captureControl.consumeReset();
                if ((reasons & CaptureControl.RESET_REASON_TERMINATED) != 0) {
                    break;
                }
                capture.prepare();
                Size size = capture.getSize();
                MediaFormat format = createFormat(size);
                Surface surface = null;
                boolean codecStarted = false;
                boolean captureStarted = false;
                try {
                    codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
                    surface = codec.createInputSurface();
                    capture.start(surface);
                    captureStarted = true;
                    codec.start();
                    codecStarted = true;
                    captureControl.setRunningMediaCodec(codec);
                    synchronized (this) {
                        running = codec;
                        if (suspended) {
                            applySuspend(codec, true);
                        }
                    }
                    if (!stopped && !captureControl.isResetRequested()) {
                        boolean clientResize = (reasons & CaptureControl.RESET_REASON_CLIENT_RESIZED) != 0
                                && (reasons & CaptureControl.RESET_REASON_DISPLAY_PROPERTIES_CHANGED) == 0;
                        streamer.writeSessionMeta(size.getWidth(), size.getHeight(), clientResize);
                        encode(codec);
                        consecutiveErrors = 0;
                    }
                    alive = !stopped && !capture.isClosed();
                } catch (IllegalStateException | IllegalArgumentException | IOException e) {
                    if (e instanceof IOException && IO.isBrokenPipe((IOException) e)) {
                        throw e;
                    }
                    if (stopped || ++consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) {
                        throw e;
                    }
                    Ln.w("video encoding error, retrying: " + e);
                    SystemClock.sleep(50);
                } finally {
                    synchronized (this) {
                        running = null;
                    }
                    captureControl.setRunningMediaCodec(null);
                    if (captureStarted) {
                        capture.stop();
                    }
                    if (codecStarted) {
                        try {
                            codec.stop();
                        } catch (IllegalStateException e) {
                            // ignore
                        }
                    }
                    codec.reset();
                    if (surface != null) {
                        surface.release();
                    }
                }
            }
        } finally {
            codec.release();
            listener.beforeRelease();
            capture.release();
            listener.afterRelease();
        }
    }

    private void encode(MediaCodec codec) throws IOException {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        boolean eos;
        do {
            int index = codec.dequeueOutputBuffer(info, -1);
            try {
                eos = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
                if (index >= 0 && info.size > 0) {
                    ByteBuffer buffer = codec.getOutputBuffer(index);
                    streamer.writePacket(buffer, info);
                }
            } finally {
                if (index >= 0) {
                    codec.releaseOutputBuffer(index, false);
                }
            }
        } while (!eos);
    }

    private synchronized MediaFormat createFormat(Size size) {
        MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, size.getWidth(), size.getHeight());
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate);
        // Required by configure(); the real frame rate is variable.
        format.setInteger(MediaFormat.KEY_FRAME_RATE, 60);
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        format.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL_S);
        format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, REPEAT_FRAME_DELAY_US);
        format.setInteger(MediaFormat.KEY_PRIORITY, 0);
        format.setInteger(MediaFormat.KEY_LATENCY, 1);
        if (maxFps > 0) {
            format.setFloat("max-fps-to-encoder", maxFps);
        }
        return format;
    }
}
