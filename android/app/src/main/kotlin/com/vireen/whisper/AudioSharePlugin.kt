package com.vireen.whisper

import android.app.ForegroundServiceStartNotAllowedException
import android.content.Context
import android.content.Intent
import android.media.AudioFocusRequest
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.PlaybackParams
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AudioSharePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val PLAYBACK_NORMAL_SPEED = 1.0f
        private const val PLAYBACK_CATCH_UP_SPEED = 1.012f
        private const val PLAYBACK_CATCH_UP_QUEUE_MICROS = 160_000L
        private const val PLAYBACK_NORMAL_QUEUE_MICROS = 100_000L
        private const val PLAYBACK_STALE_DROP_TOLERANCE_MICROS = 80_000L
        private const val PLAYBACK_RESYNC_QUEUE_MICROS = 220_000L
        private var activeInstance: AudioSharePlugin? = null

        fun dispatchMediaControl(action: String) {
            val instance = activeInstance ?: return
            Handler(Looper.getMainLooper()).post {
                instance.channel.invokeMethod("mediaControl", mapOf("action" to action))
            }
        }
    }

    internal lateinit var channel: MethodChannel
    private var audioTrack: AudioTrack? = null
    private var focusRequest: AudioFocusRequest? = null
    private var pausedByTransientLoss = false
    private lateinit var appContext: Context
    private var activeSessionId: String = ""
    private var activeChannels: Int = 2
    private var activeSampleRate: Int = 48000
    private var writtenFrames: Long = 0L
    private var currentPlaybackSpeed: Float = PLAYBACK_NORMAL_SPEED
    private var writeCount: Int = 0
    private var writeBytes: Long = 0L
    private var droppedWriteCount: Int = 0
    private var droppedStaleCount: Int = 0
    private var shortWriteCount: Int = 0
    private var resyncCount: Int = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.vireen.whisper/audio_share")
        channel.setMethodCallHandler(this)
        activeInstance = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopPlayback()
        channel.setMethodCallHandler(null)
        if (activeInstance === this) {
            activeInstance = null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startPlayback" -> {
                val sessionId = call.argument<String>("sessionId") ?: ""
                val format = call.argument<Map<String, Any>>("format") ?: emptyMap()
                startPlayback(sessionId, format)
                result.success(null)
            }

            "writePcm" -> {
                val sessionId = call.argument<String>("sessionId") ?: ""
                val pcm = call.argument<ByteArray>("pcm")
                val targetPlaybackTimeMicros =
                    call.argument<Number>("targetPlaybackTimeMicros")?.toLong() ?: 0L
                if (sessionId == activeSessionId && pcm != null) {
                    if (isStaleFrame(targetPlaybackTimeMicros)) {
                        droppedStaleCount += 1
                        if (NativePrivacyLog.isEnabled &&
                            (droppedStaleCount <= 3 || droppedStaleCount % 50 == 0)
                        ) {
                            NativePrivacyLog.event(
                                NativeLogEvent.audioFrameDroppedStale,
                                count = droppedStaleCount.toLong(),
                            )
                        }
                        result.success(null)
                        return
                    }
                    val queuedBeforeMicros = nativeQueuedMicros()
                    if (queuedBeforeMicros > PLAYBACK_RESYNC_QUEUE_MICROS) {
                        resyncPlaybackQueue()
                    }
                    val written = writePcmNonBlocking(pcm)
                    writeCount += 1
                    if (written > 0) {
                        writeBytes += written.toLong()
                        writtenFrames += written / maxOf(1, activeChannels * 2)
                    }
                    val nativeQueuedMicros = nativeQueuedMicros()
                    updatePlaybackSpeed(nativeQueuedMicros)
                    if (written < pcm.size) {
                        recordShortWrite(writtenBytes = written)
                    }
                } else {
                    droppedWriteCount += 1
                    if (NativePrivacyLog.isEnabled &&
                        (droppedWriteCount <= 3 || droppedWriteCount % 100 == 0)
                    ) {
                        NativePrivacyLog.event(
                            NativeLogEvent.audioFrameDropped,
                            count = droppedWriteCount.toLong(),
                        )
                    }
                }
                result.success(null)
            }

            "stopPlayback" -> {
                val sessionId = call.argument<String>("sessionId") ?: ""
                if (sessionId.isEmpty() || sessionId == activeSessionId) {
                    stopPlayback()
                }
                result.success(null)
            }

            "updateMediaState" -> {
                val state = call.argument<String>("state") ?: MediaPlaybackService.STATE_STOPPED
                if (state == MediaPlaybackService.STATE_PLAYING) {
                    requestFocus()
                } else if (state == MediaPlaybackService.STATE_STOPPED) {
                    abandonFocus()
                }
                val intent = Intent(appContext, MediaPlaybackService::class.java)
                    .putExtra(MediaPlaybackService.EXTRA_STATE, state)
                    .putExtra(MediaPlaybackService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                    .putExtra(MediaPlaybackService.EXTRA_SUBTITLE, call.argument<String>("subtitle") ?: "")
                    .putExtra(
                        MediaPlaybackService.EXTRA_CAN_RESUME,
                        call.argument<Boolean>("canResume") ?: true
                    )
                    .putExtra(
                        MediaPlaybackService.EXTRA_PAUSE_LABEL,
                        call.argument<String>("pauseLabel") ?: ""
                    )
                    .putExtra(
                        MediaPlaybackService.EXTRA_PLAY_LABEL,
                        call.argument<String>("playLabel") ?: ""
                    )
                    .putExtra(
                        MediaPlaybackService.EXTRA_DISCONNECT_LABEL,
                        call.argument<String>("disconnectLabel") ?: ""
                    )
                    .putExtra(
                        MediaPlaybackService.EXTRA_CHANNEL_NAME,
                        call.argument<String>("channelName") ?: ""
                    )
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        appContext.startForegroundService(intent)
                    } else {
                        appContext.startService(intent)
                    }
                } catch (error: Exception) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                        error is ForegroundServiceStartNotAllowedException
                    ) {
                        NativePrivacyLog.event(
                            NativeLogEvent.mediaServiceStartDenied,
                            reason = NativeLogReason.startDenied,
                        )
                    } else {
                        throw error
                    }
                }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                pausedByTransientLoss = true
                dispatchMediaControl("focusPauseTransient")
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                pausedByTransientLoss = false
                dispatchMediaControl("focusPause")
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                audioTrack?.setVolume(0.2f)

            AudioManager.AUDIOFOCUS_GAIN -> {
                audioTrack?.setVolume(1.0f)
                if (pausedByTransientLoss) {
                    pausedByTransientLoss = false
                    dispatchMediaControl("focusResume")
                }
            }
        }
    }

    private fun requestFocus() {
        val manager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = request
            manager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }
    }

    private fun abandonFocus() {
        val manager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val request = focusRequest
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && request != null) {
            manager.abandonAudioFocusRequest(request)
        } else {
            @Suppress("DEPRECATION")
            manager.abandonAudioFocus(focusListener)
        }
        focusRequest = null
        pausedByTransientLoss = false
    }

    private fun startPlayback(sessionId: String, format: Map<String, Any>) {
        stopPlayback()
        activeSessionId = sessionId
        activeSampleRate = 48000
        writtenFrames = 0L
        currentPlaybackSpeed = PLAYBACK_NORMAL_SPEED
        writeCount = 0
        writeBytes = 0L
        droppedWriteCount = 0
        droppedStaleCount = 0
        shortWriteCount = 0
        resyncCount = 0

        val sampleRate = (format["sampleRate"] as? Number)?.toInt() ?: 48000
        activeSampleRate = sampleRate
        val channels = (format["channels"] as? Number)?.toInt() ?: 2
        activeChannels = if (channels == 1) 1 else 2
        val channelMask = if (activeChannels == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val minBufferSize = AudioTrack.getMinBufferSize(
            sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val targetBufferSize = sampleRate * activeChannels * 2 / 20
        val bufferSize = maxOf(minBufferSize, targetBufferSize)
        NativePrivacyLog.event(
            NativeLogEvent.audioPlaybackStarted,
            count = activeChannels.toLong(),
            bytes = bufferSize.toLong(),
        )

        val builder = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelMask)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()
            )
            .setBufferSizeInBytes(bufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }

        audioTrack = builder
            .build()
            .also { it.play() }
    }

    private fun stopPlayback() {
        val sessionId = activeSessionId
        if (sessionId.isNotEmpty()) {
            NativePrivacyLog.event(
                NativeLogEvent.audioPlaybackStopped,
                count = writeCount.toLong(),
                bytes = writeBytes,
            )
        }
        audioTrack?.let {
            try {
                it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        audioTrack = null
        activeSessionId = ""
        activeChannels = 2
        activeSampleRate = 48000
        writtenFrames = 0L
        currentPlaybackSpeed = PLAYBACK_NORMAL_SPEED
        droppedStaleCount = 0
        shortWriteCount = 0
        resyncCount = 0
    }

    private fun writePcmNonBlocking(pcm: ByteArray): Int {
        val track = audioTrack ?: return 0
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            track.write(pcm, 0, pcm.size, AudioTrack.WRITE_NON_BLOCKING)
        } else {
            track.write(pcm, 0, pcm.size)
        }
    }

    private fun recordShortWrite(writtenBytes: Int) {
        shortWriteCount += 1
        if (NativePrivacyLog.isEnabled &&
            (shortWriteCount <= 3 || shortWriteCount % 50 == 0)
        ) {
            NativePrivacyLog.event(
                NativeLogEvent.audioShortWrite,
                count = shortWriteCount.toLong(),
                bytes = writtenBytes.coerceAtLeast(0).toLong(),
            )
        }
    }

    private fun nativeQueuedMicros(): Long {
        val track = audioTrack ?: return 0L
        if (activeSampleRate <= 0) {
            return 0L
        }
        val playbackHeadFrames = playbackHeadFrames(track)
        val queuedFrames = (writtenFrames - playbackHeadFrames).coerceAtLeast(0L)
        return queuedFrames * 1_000_000L / activeSampleRate
    }

    private fun playbackHeadFrames(track: AudioTrack): Long {
        return track.playbackHeadPosition.toLong() and 0xffffffffL
    }

    private fun isStaleFrame(targetPlaybackTimeMicros: Long): Boolean {
        if (targetPlaybackTimeMicros <= 0L) {
            return false
        }
        val nowMicros = System.currentTimeMillis() * 1000L
        return nowMicros - targetPlaybackTimeMicros > PLAYBACK_STALE_DROP_TOLERANCE_MICROS
    }

    private fun resyncPlaybackQueue() {
        val track = audioTrack ?: return
        resyncCount += 1
        try {
            track.pause()
            track.flush()
            writtenFrames = playbackHeadFrames(track)
            updatePlaybackSpeed(0L, force = true)
            track.play()
            NativePrivacyLog.event(
                NativeLogEvent.audioPlaybackResynced,
                reason = NativeLogReason.queueBacklog,
                count = resyncCount.toLong(),
            )
        } catch (_: IllegalStateException) {
            NativePrivacyLog.event(
                NativeLogEvent.audioPlaybackResyncFailed,
                reason = NativeLogReason.invalidState,
            )
        }
    }

    private fun updatePlaybackSpeed(nativeQueuedMicros: Long, force: Boolean = false) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }
        val desiredSpeed = when {
            nativeQueuedMicros > PLAYBACK_CATCH_UP_QUEUE_MICROS -> PLAYBACK_CATCH_UP_SPEED
            nativeQueuedMicros < PLAYBACK_NORMAL_QUEUE_MICROS -> PLAYBACK_NORMAL_SPEED
            else -> currentPlaybackSpeed
        }
        if (!force && desiredSpeed == currentPlaybackSpeed) {
            return
        }
        val track = audioTrack ?: return
        try {
            track.playbackParams = PlaybackParams()
                .allowDefaults()
                .setSpeed(desiredSpeed)
            currentPlaybackSpeed = desiredSpeed
            NativePrivacyLog.event(
                NativeLogEvent.audioPlaybackSpeedChanged,
            )
        } catch (_: IllegalArgumentException) {
            NativePrivacyLog.event(
                NativeLogEvent.audioPlaybackSpeedFailed,
                reason = NativeLogReason.invalidState,
            )
        } catch (_: IllegalStateException) {
            NativePrivacyLog.event(
                NativeLogEvent.audioPlaybackSpeedFailed,
                reason = NativeLogReason.invalidState,
            )
        }
    }
}
