package com.vireen.whisper

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AudioSharePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "WhisperAudioShare"
    }

    private lateinit var channel: MethodChannel
    private var audioTrack: AudioTrack? = null
    private var activeSessionId: String = ""
    private var activeChannels: Int = 2
    private var writeCount: Int = 0
    private var writeBytes: Long = 0L
    private var droppedWriteCount: Int = 0

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
                if (sessionId == activeSessionId && pcm != null) {
                    val written = audioTrack?.write(pcm, 0, pcm.size) ?: 0
                    writeCount += 1
                    if (written > 0) {
                        writeBytes += written.toLong()
                    }
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
                                "peakLeft=$peakLeft peakRight=$peakRight"
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
        writeCount = 0
        writeBytes = 0L
        droppedWriteCount = 0

        val sampleRate = (format["sampleRate"] as? Number)?.toInt() ?: 48000
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
        val bufferSize = maxOf(minBufferSize, sampleRate * activeChannels * 2 / 5)
        Log.i(
            TAG,
            "startPlayback session=$sessionId sampleRate=$sampleRate channels=$activeChannels " +
                "minBufferSize=$minBufferSize bufferSize=$bufferSize"
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
                    "writeBytes=$writeBytes dropped=$droppedWriteCount"
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
