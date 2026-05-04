package com.vireen.whisper

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AudioSharePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var audioTrack: AudioTrack? = null
    private var activeSessionId: String = ""

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
                    audioTrack?.write(pcm, 0, pcm.size)
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

        val sampleRate = (format["sampleRate"] as? Number)?.toInt() ?: 48000
        val channels = (format["channels"] as? Number)?.toInt() ?: 2
        val channelMask = if (channels == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val minBufferSize = AudioTrack.getMinBufferSize(
            sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val bufferSize = maxOf(minBufferSize, sampleRate * channels * 2 / 5)

        audioTrack = AudioTrack.Builder()
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
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
            .also { it.play() }
    }

    private fun stopPlayback() {
        audioTrack?.let {
            try {
                it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        audioTrack = null
        activeSessionId = ""
    }
}
