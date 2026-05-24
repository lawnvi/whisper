package com.vireen.whisper

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.PlaybackParams
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AudioSharePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "WhisperAudioShare"
        private const val PLAYBACK_NORMAL_SPEED = 1.0f
        private const val PLAYBACK_CATCH_UP_SPEED = 1.012f
        private const val PLAYBACK_CATCH_UP_QUEUE_MICROS = 160_000L
        private const val PLAYBACK_NORMAL_QUEUE_MICROS = 100_000L
        private const val PLAYBACK_STALE_DROP_TOLERANCE_MICROS = 80_000L
        private const val PLAYBACK_RESYNC_QUEUE_MICROS = 220_000L
    }

    private lateinit var channel: MethodChannel
    private var audioTrack: AudioTrack? = null
    private var activeSessionId: String = ""
    private var activeChannels: Int = 2
    private var activeSampleRate: Int = 48000
    private var writtenFrames: Long = 0L
    private var currentPlaybackSpeed: Float = PLAYBACK_NORMAL_SPEED
    private var writeCount: Int = 0
    private var writeBytes: Long = 0L
    private var droppedWriteCount: Int = 0
    private var droppedStaleCount: Int = 0
    private var resyncCount: Int = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.vireen.whisper/audio_share")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopPlayback()
        channel.setMethodCallHandler(null)
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
                        if (droppedStaleCount <= 3 || droppedStaleCount % 50 == 0) {
                            Log.w(
                                TAG,
                                "writePcm stale drop session=$sessionId " +
                                    "targetPlaybackTimeMicros=$targetPlaybackTimeMicros " +
                                    "droppedStale=$droppedStaleCount"
                            )
                        }
                        result.success(null)
                        return
                    }
                    val queuedBeforeMicros = nativeQueuedMicros()
                    if (queuedBeforeMicros > PLAYBACK_RESYNC_QUEUE_MICROS) {
                        resyncPlaybackQueue("preWrite", queuedBeforeMicros)
                    }
                    val written = audioTrack?.write(pcm, 0, pcm.size) ?: 0
                    writeCount += 1
                    if (written > 0) {
                        writeBytes += written.toLong()
                        writtenFrames += written / maxOf(1, activeChannels * 2)
                    }
                    val nativeQueuedMicros = nativeQueuedMicros()
                    updatePlaybackSpeed(nativeQueuedMicros)
                    if (writeCount <= 3 || writeCount % 100 == 0) {
                        val peakLeft = pcmPeak(pcm, activeChannels, 0)
                        val peakRight = if (activeChannels > 1) {
                            pcmPeak(pcm, activeChannels, 1)
                        } else {
                            peakLeft
                        }
                        Log.i(
                            TAG,
                            "writePcm session=$sessionId bytes=${pcm.size} written=$written " +
                                "writeCount=$writeCount writeBytes=$writeBytes " +
                                "targetPlaybackTimeMicros=$targetPlaybackTimeMicros " +
                                "writtenFrames=$writtenFrames nativeQueuedMicros=$nativeQueuedMicros " +
                                "peakLeft=$peakLeft peakRight=$peakRight " +
                                "droppedStale=$droppedStaleCount resync=$resyncCount"
                        )
                    }
                } else {
                    droppedWriteCount += 1
                    if (droppedWriteCount <= 3 || droppedWriteCount % 100 == 0) {
                        Log.w(
                            TAG,
                            "writePcm dropped session=$sessionId active=$activeSessionId " +
                                "hasPcm=${pcm != null} dropped=$droppedWriteCount"
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

            else -> result.notImplemented()
        }
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
        Log.i(
            TAG,
            "startPlayback session=$sessionId sampleRate=$sampleRate channels=$activeChannels " +
                "minBufferSize=$minBufferSize targetBufferSize=$targetBufferSize " +
                "bufferSize=$bufferSize"
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
            Log.i(
                TAG,
                "stopPlayback session=$sessionId writeCount=$writeCount " +
                    "writeBytes=$writeBytes dropped=$droppedWriteCount " +
                    "droppedStale=$droppedStaleCount resync=$resyncCount"
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
        resyncCount = 0
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

    private fun resyncPlaybackQueue(reason: String, nativeQueuedMicros: Long) {
        val track = audioTrack ?: return
        resyncCount += 1
        try {
            track.pause()
            track.flush()
            writtenFrames = playbackHeadFrames(track)
            updatePlaybackSpeed(0L, force = true)
            track.play()
            Log.w(
                TAG,
                "playbackResync session=$activeSessionId reason=$reason " +
                    "nativeQueuedMicros=$nativeQueuedMicros resync=$resyncCount"
            )
        } catch (error: IllegalStateException) {
            Log.w(
                TAG,
                "playbackResync failed reason=$reason nativeQueuedMicros=$nativeQueuedMicros",
                error
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
            Log.i(
                TAG,
                "playbackSpeed session=$activeSessionId speed=$desiredSpeed " +
                    "nativeQueuedMicros=$nativeQueuedMicros"
            )
        } catch (error: IllegalArgumentException) {
            Log.w(TAG, "playbackSpeed failed speed=$desiredSpeed", error)
        } catch (error: IllegalStateException) {
            Log.w(TAG, "playbackSpeed failed speed=$desiredSpeed", error)
        }
    }

    private fun pcmPeak(pcm: ByteArray, channels: Int, targetChannel: Int): Int {
        val normalizedChannels = maxOf(1, channels)
        var peak = 0
        var index = targetChannel.coerceIn(0, normalizedChannels - 1) * 2
        val step = normalizedChannels * 2
        while (index + 1 < pcm.size) {
            val lo = pcm[index].toInt() and 0xff
            val hi = pcm[index + 1].toInt() shl 8
            val sample = (hi or lo).toShort().toInt()
            val absSample = if (sample < 0) -sample else sample
            if (absSample > peak) {
                peak = absSample
            }
            index += step
        }
        return peak
    }
}
