package com.vireen.whisper

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Shows a streamed window (H.264 from another device) in a Flutter texture.
 *
 * Control calls (create, resize, dispose) use a method channel on the main
 * thread. Encoded frames arrive on a binary channel bound to a background task
 * queue, sent straight from the Dart stream isolate, so video never waits on
 * the UI thread.
 *
 * Frame message: int64 decoder id, int64 pts (µs), int32 flags (1 config,
 * 2 keyframe), then the Annex-B payload. All little-endian.
 */
class WindowStreamReceiverPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var control: MethodChannel
    private lateinit var activities: MethodChannel
    private lateinit var frames: BasicMessageChannel<ByteBuffer>
    private lateinit var textures: TextureRegistry
    private val decoders = ConcurrentHashMap<Long, StreamDecoder>()

    /** Each window's sound, by decoder id (created on its first format). */
    private val audios = ConcurrentHashMap<Long, WindowStreamAudio>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var appContext: android.content.Context? = null

    // Wi-Fi power save holds packets back for up to a beacon interval
    // (100 ms or more); while a streamed window is open the radio stays
    // awake. Low-latency mode only applies in the foreground with the
    // screen on, which is exactly while a window is being watched.
    private var wifiLock: WifiManager.WifiLock? = null

    private fun updateWifiLock() {
        val context = appContext ?: return
        try {
            if (decoders.isEmpty()) {
                wifiLock?.takeIf { it.isHeld }?.release()
                return
            }
            val lock = wifiLock ?: run {
                val wifi = context.getSystemService(android.content.Context.WIFI_SERVICE) as? WifiManager
                    ?: return
                @Suppress("DEPRECATION")
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifi.createWifiLock(mode, "whisper:window_stream").apply {
                    setReferenceCounted(false)
                }.also { wifiLock = it }
            }
            if (!lock.isHeld) {
                lock.acquire()
            }
        } catch (_: RuntimeException) {
            // A missing permission or radio only costs latency.
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        textures = binding.textureRegistry
        control = MethodChannel(binding.binaryMessenger, CONTROL_CHANNEL)
        control.setMethodCallHandler(this)
        activities = MethodChannel(binding.binaryMessenger, ACTIVITY_CHANNEL)
        activities.setMethodCallHandler { call, result ->
            val id = (call.argument<Number>("id") ?: -1).toLong()
            when (call.method) {
                "open" -> {
                    val context = appContext
                    if (context == null || decoders[id] == null) {
                        result.success(false)
                    } else {
                        WindowStreamActivity.start(
                            context, id, call.argument<String>("title").orEmpty(),
                            call.argument<Double>("scale") ?: 0.75,
                            call.argument<Boolean>("landscape") == true,
                        )
                        result.success(true)
                    }
                }
                "finish" -> {
                    appContext?.let { WindowStreamActivity.finish(it, id) }
                    result.success(null)
                }
                "textFocus" -> {
                    WindowStreamActivity.textFocus(id, call.argument<Boolean>("typing") == true)
                    result.success(null)
                }
                "videoSize" -> {
                    WindowStreamActivity.videoSize(
                        id, call.argument<Number>("width")?.toInt() ?: 0,
                        call.argument<Number>("height")?.toInt() ?: 0,
                    )
                    result.success(null)
                }
                "placeholder" -> {
                    WindowStreamActivity.placeholder(
                        id, call.argument<ByteArray>("picture"), call.argument<ByteArray>("icon"),
                        call.argument<String>("connecting").orEmpty(),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        instance = this
        val queue = binding.binaryMessenger.makeBackgroundTaskQueue()
        frames = BasicMessageChannel(binding.binaryMessenger, FRAME_CHANNEL, BinaryCodec.INSTANCE, queue)
        frames.setMessageHandler { message, reply ->
            if (message != null) {
                onFrame(message)
            }
            // Not null: the frames come from a background isolate, which
            // takes an empty answer for a broken one and never lets go of
            // its wait.
            reply.reply(ByteBuffer.allocateDirect(1).put(0.toByte()))
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (instance === this) {
            instance = null
        }
        activities.setMethodCallHandler(null)
        control.setMethodCallHandler(null)
        frames.setMessageHandler(null)
        decoders.values.forEach { it.release() }
        decoders.clear()
        audios.values.forEach { it.release() }
        audios.clear()
        updateWifiLock()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> {
                val width = call.argument<Int>("width") ?: 1280
                val height = call.argument<Int>("height") ?: 720
                val producer = textures.createSurfaceProducer()
                val decoder = StreamDecoder(producer, width, height) { event, args -> emit(producer.id(), event, args) }
                decoders[producer.id()] = decoder
                updateWifiLock()
                result.success(producer.id())
            }
            "resize" -> {
                val id = (call.argument<Number>("id") ?: -1).toLong()
                decoders[id]?.resize(call.argument<Int>("width") ?: 0, call.argument<Int>("height") ?: 0)
                result.success(null)
            }
            "dispose" -> {
                val id = (call.argument<Number>("id") ?: -1).toLong()
                decoders.remove(id)?.release()
                audios.remove(id)?.release()
                updateWifiLock()
                result.success(null)
            }
            "audioMute" -> {
                val id = (call.argument<Number>("id") ?: -1).toLong()
                audios[id]?.setMuted(call.argument<Boolean>("muted") == true)
                result.success(null)
            }
            "publishIdentity" -> {
                val context = appContext
                val peerId = call.argument<String>("peerId").orEmpty()
                val identityKey = call.argument<String>("identityKey").orEmpty()
                if (context != null && peerId.isNotEmpty() && identityKey.isNotEmpty()) {
                    WindowStreamPhoneState.publishIdentity(context, peerId, identityKey)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun onFrame(message: ByteBuffer) {
        message.order(ByteOrder.LITTLE_ENDIAN)
        if (message.remaining() < HEADER_BYTES) {
            return
        }
        val id = message.getLong()
        val ptsUs = message.getLong()
        val flags = message.getInt()
        if (flags and (FLAG_AUDIO or FLAG_AUDIO_FORMAT) != 0) {
            // The window's sound (playback: see WindowStreamAudio); never video.
            onAudio(id, message.slice(), ptsUs, flags)
            return
        }
        val decoder = decoders[id] ?: return
        decoder.push(message.slice(), ptsUs, flags)
    }

    /** The window's sound: its format (sample rate, channels) or a PCM chunk. */
    @Suppress("UNUSED_PARAMETER")
    private fun onAudio(id: Long, payload: ByteBuffer, ptsUs: Long, flags: Int) {
        if (decoders[id] == null) return
        if (flags and FLAG_AUDIO_FORMAT != 0) {
            if (payload.remaining() < 8) return
            payload.order(ByteOrder.LITTLE_ENDIAN)
            val rate = payload.getInt()
            val channels = payload.getInt()
            val context = appContext ?: return
            val audio = audios.getOrPut(id) {
                WindowStreamAudio(context) { event, args ->
                    emit(id, event, args)
                    if (event == "audio") WindowStreamActivity.soundStarted(id)
                }
            }
            audio.configure(rate, channels)
            return
        }
        audios[id]?.push(payload)
    }

    private fun emit(id: Long, event: String, args: Map<String, Any>) {
        mainHandler.post {
            control.invokeMethod(event, args + mapOf("id" to id))
        }
    }

    internal fun decoder(id: Long): StreamDecoder? = decoders[id]

    /** The window [id] has played sound here. */
    internal fun hasSound(id: Long) = audios[id]?.hasPlayed == true

    internal fun setAudioMuted(id: Long, muted: Boolean) {
        audios[id]?.setMuted(muted)
    }

    /** A window activity's touches, keys and lifecycle, for Whisper to act on. */
    internal fun emitActivity(id: Long, type: String, args: Map<String, Any>) {
        mainHandler.post {
            activities.invokeMethod("event", args + mapOf("id" to id, "event" to type))
        }
    }

    companion object {
        const val CONTROL_CHANNEL = "com.vireen.whisper/window_stream"
        const val ACTIVITY_CHANNEL = "com.vireen.whisper/window_stream_activity"

        @Volatile
        internal var instance: WindowStreamReceiverPlugin? = null
        const val FRAME_CHANNEL = "com.vireen.whisper/window_stream_frames"
        const val HEADER_BYTES = 20
        const val FLAG_CONFIG = 1
        const val FLAG_KEY = 2
        const val FLAG_AUDIO = 16
        const val FLAG_AUDIO_FORMAT = 32
    }
}

/**
 * One MediaCodec decoding into one Flutter SurfaceProducer. Input buffers
 * are handed out by the codec's async callback; frames that find no free
 * buffer are dropped and the decoder waits for the next keyframe, so latency
 * never accumulates.
 */
internal class StreamDecoder(
    private val producer: TextureRegistry.SurfaceProducer,
    private var width: Int,
    private var height: Int,
    private val emit: (String, Map<String, Any>) -> Unit,
) {
    private val thread = HandlerThread("window-stream-decoder").apply { start() }
    private val handler = Handler(thread.looper)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Object()
    private val freeInputs = ArrayDeque<Int>()
    private var codec: MediaCodec? = null
    private var config: ByteArray? = null
    private var waitingForKey = true
    private var released = false
    private val lastKeyframeAsk = AtomicLong(0)

    /** A window activity's surface, drawn into instead of the texture. */
    private var external: Surface? = null
    @Volatile
    var onSize: ((Int, Int) -> Unit)? = null

    /** A picture was handed to the screen (codec thread). */
    @Volatile
    var onFrame: (() -> Unit)? = null
    @Volatile
    private var lastSize: Pair<Int, Int>? = null

    fun videoSize(): Pair<Int, Int>? = lastSize

    // Where frames go: the window activity's surface, else the texture
    // (null while neither is usable, e.g. Whisper's own screen is in the
    // background and the activity just closed).
    private val output: Surface?
        get() = external?.takeIf { it.isValid } ?: producer.surface?.takeIf { it.isValid }

    fun attachSurface(surface: Surface) {
        handler.post {
            external = surface
            switchOutput()
        }
        askKeyframe(force = true)
    }

    /** Called from surfaceDestroyed: must be done before it returns. */
    fun detachSurface() {
        val done = CountDownLatch(1)
        handler.post {
            external = null
            switchOutput()
            done.countDown()
        }
        done.await(500, TimeUnit.MILLISECONDS)
    }

    private fun switchOutput() {
        val target = output
        val active = synchronized(lock) { codec }
        if (target == null) {
            // Nowhere to draw: stop and pick up again when a surface comes.
            stopCodec()
            return
        }
        if (active == null) {
            restartCodec()
            return
        }
        try {
            active.setOutputSurface(target)
        } catch (_: Exception) {
            restartCodec()
        }
    }

    init {
        producer.setSize(width, height)
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                // The engine recreated the surface (e.g. after backgrounding).
                handler.post { if (external == null) restartCodec() }
            }

            override fun onSurfaceCleanup() {
                // A window activity keeps decoding while Whisper's own
                // screen is in the background.
                handler.post { if (external == null) stopCodec() }
            }
        })
    }

    fun resize(newWidth: Int, newHeight: Int) {
        if (newWidth <= 0 || newHeight <= 0) {
            return
        }
        handler.post {
            width = newWidth
            height = newHeight
            producer.setSize(newWidth, newHeight)
        }
    }

    fun push(payload: ByteBuffer, ptsUs: Long, flags: Int) {
        val isConfig = flags and WindowStreamReceiverPlugin.FLAG_CONFIG != 0
        val isKey = flags and WindowStreamReceiverPlugin.FLAG_KEY != 0
        if (isConfig) {
            val bytes = ByteArray(payload.remaining())
            payload.get(bytes)
            handler.post { onConfig(bytes) }
            return
        }
        synchronized(lock) {
            if (released) {
                return
            }
            val active = codec
            if (active == null || (waitingForKey && !isKey)) {
                askKeyframe()
                return
            }
            val index = freeInputs.pollFirst()
            if (index == null) {
                waitingForKey = true
                askKeyframe()
                return
            }
            try {
                val input = active.getInputBuffer(index) ?: return
                input.clear()
                if (payload.remaining() > input.remaining()) {
                    waitingForKey = true
                    active.queueInputBuffer(index, 0, 0, ptsUs, 0)
                    askKeyframe()
                    return
                }
                val length = payload.remaining()
                input.put(payload)
                active.queueInputBuffer(index, 0, length, ptsUs, 0)
                if (isKey) {
                    waitingForKey = false
                }
            } catch (error: IllegalStateException) {
                waitingForKey = true
            }
        }
    }

    private fun askKeyframe(force: Boolean = false) {
        val now = System.currentTimeMillis()
        val last = lastKeyframeAsk.get()
        if ((force || now - last > 400) && lastKeyframeAsk.compareAndSet(last, now)) {
            emit("needKeyframe", emptyMap())
        }
    }

    private fun onConfig(bytes: ByteArray) {
        if (config != null && config!!.contentEquals(bytes) && codec != null) {
            return
        }
        config = bytes
        restartCodec()
    }

    private fun restartCodec() {
        stopCodec()
        val parameterSets = config ?: return
        if (released) {
            return
        }
        val nals = splitAnnexB(parameterSets)
        val sps = nals.firstOrNull { it.isNotEmpty() && (it[0].toInt() and 0x1f) == 7 } ?: return
        val pps = nals.firstOrNull { it.isNotEmpty() && (it[0].toInt() and 0x1f) == 8 } ?: return
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        format.setByteBuffer("csd-0", ByteBuffer.wrap(START_CODE + sps))
        format.setByteBuffer("csd-1", ByteBuffer.wrap(START_CODE + pps))
        format.setInteger(MediaFormat.KEY_PRIORITY, 0)
        // Run the decoder flat out: a frame decodes sooner than at the
        // clock it would pick for 60 fps.
        format.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
        // Room for a whole keyframe of a large window: the default follows
        // the size given above, which may be far smaller than the stream,
        // and a keyframe that does not fit is dropped, then asked for again
        // and again (black window, or a stall every time one is needed).
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8 * 1024 * 1024)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        val created = try {
            MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        } catch (error: Exception) {
            emit("error", mapOf("reason" to "decoder"))
            return
        }
        created.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                synchronized(lock) { freeInputs.addLast(index) }
            }

            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                try {
                    codec.releaseOutputBuffer(index, info.size > 0)
                    if (info.size > 0) onFrame?.invoke()
                } catch (_: IllegalStateException) {
                }
            }

            override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
                synchronized(lock) { waitingForKey = true }
                handler.post { restartCodec() }
                askKeyframe()
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                val w = format.getInteger(MediaFormat.KEY_WIDTH)
                val h = format.getInteger(MediaFormat.KEY_HEIGHT)
                lastSize = w to h
                onSize?.invoke(w, h)
                emit("size", mapOf("width" to w, "height" to h))
            }
        }, handler)
        val target = output
        if (target == null) {
            created.release()
            return
        }
        try {
            created.configure(format, target, null, 0)
            created.start()
        } catch (error: Exception) {
            created.release()
            emit("error", mapOf("reason" to "configure"))
            return
        }
        synchronized(lock) {
            codec = created
            freeInputs.clear()
            waitingForKey = true
        }
        askKeyframe()
    }

    private fun stopCodec() {
        val old = synchronized(lock) {
            val current = codec
            codec = null
            freeInputs.clear()
            waitingForKey = true
            current
        }
        try {
            old?.stop()
        } catch (_: Exception) {
        }
        old?.release()
    }

    fun release() {
        synchronized(lock) { released = true }
        handler.post {
            stopCodec()
            // The engine only takes its texture back on the main thread;
            // releasing it here crashed the app when a window closed.
            mainHandler.post { producer.release() }
            thread.quitSafely()
        }
    }

    companion object {
        private val START_CODE = byteArrayOf(0, 0, 0, 1)

        fun splitAnnexB(data: ByteArray): List<ByteArray> {
            val starts = mutableListOf<Pair<Int, Int>>()
            var i = 0
            while (i + 2 < data.size) {
                if (data[i].toInt() == 0 && data[i + 1].toInt() == 0) {
                    if (data[i + 2].toInt() == 1) {
                        starts.add(i to i + 3)
                        i += 3
                        continue
                    }
                    if (i + 3 < data.size && data[i + 2].toInt() == 0 && data[i + 3].toInt() == 1) {
                        starts.add(i to i + 4)
                        i += 4
                        continue
                    }
                }
                i++
            }
            return starts.mapIndexed { index, (_, payload) ->
                val end = if (index + 1 < starts.size) starts[index + 1].first else data.size
                data.copyOfRange(payload, end)
            }
        }
    }
}
