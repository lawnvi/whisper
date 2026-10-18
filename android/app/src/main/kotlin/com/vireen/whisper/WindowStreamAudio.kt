package com.vireen.whisper

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import java.nio.ByteBuffer

/**
 * Plays one streamed window's sound: PCM s16le chunks as the stream
 * delivers them, through a small jitter buffer, on a low-latency
 * AudioTrack. Playback starts once [TARGET_MS] of sound is queued; when the
 * queue grows past [MAX_MS] (a burst after a stall) it is trimmed back to
 * the target, so the sound stays with the picture; when it runs dry (a
 * pause, a gap) the track pauses and waits for the target again rather than
 * stuttering.
 */
internal class WindowStreamAudio(
    private val context: Context,
    private val emit: (String, Map<String, Any>) -> Unit,
) {
    companion object {
        const val TARGET_MS = 60
        const val MAX_MS = 150

        /** How long the writer waits on an empty queue before calling it a gap. */
        private const val DRY_MS = 40L
    }

    private val lock = Object()
    private val queue = ArrayDeque<ByteArray>()
    private var queuedBytes = 0
    private var sampleRate = 0
    private var channels = 0
    private var track: AudioTrack? = null
    private var writer: Thread? = null
    private var playing = false
    private var released = false
    private var announced = false

    /** Sound has arrived (the activity shows its mute button). */
    val hasPlayed get() = synchronized(lock) { announced }

    @Volatile
    private var muted = false

    @Volatile
    private var focusLost = false
    private var focusRequest: AudioFocusRequest? = null
    private var underruns = 0
    private var resyncs = 0
    private var chunks = 0

    private val audioManager get() = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private fun bytesPerMs() = sampleRate * channels * 2 / 1000

    fun configure(rate: Int, channelCount: Int) {
        if (rate !in 8000..192000 || channelCount !in 1..2) return
        synchronized(lock) {
            if (released) return
            if (rate == sampleRate && channelCount == channels && track != null) return
            stopTrackLocked()
            sampleRate = rate
            channels = channelCount
            val mask = if (channelCount == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
            val min = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
            val size = maxOf(min, bytesPerMs() * 40)
            val builder = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate)
                        .setChannelMask(mask)
                        .build(),
                )
                .setBufferSizeInBytes(size)
                .setTransferMode(AudioTrack.MODE_STREAM)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            }
            track = try {
                builder.build().also { applyVolume(it) }
            } catch (_: Exception) {
                null
            }
            if (writer == null) {
                writer = Thread({ writeLoop() }, "window-stream-audio").apply {
                    priority = Thread.MAX_PRIORITY
                    start()
                }
            }
        }
    }

    fun push(payload: ByteBuffer) {
        val bytes = ByteArray(payload.remaining())
        payload.get(bytes)
        var first = false
        synchronized(lock) {
            if (released || track == null || bytesPerMs() == 0 || bytes.isEmpty()) return
            queue.addLast(bytes)
            queuedBytes += bytes.size
            chunks++
            if (queuedBytes > bytesPerMs() * MAX_MS) {
                // Too far behind the picture: back to the target.
                resyncs++
                while (queuedBytes > bytesPerMs() * TARGET_MS && queue.size > 1) {
                    queuedBytes -= queue.removeFirst().size
                }
            }
            if (!announced) {
                announced = true
                first = true
            }
            lock.notifyAll()
        }
        if (first) emit("audio", mapOf("playing" to true))
        // The numbers every 2 s while sound flows, as iOS reports them.
        val now = android.os.SystemClock.uptimeMillis()
        if (now - lastStatsAt >= 2000) {
            lastStatsAt = now
            emit("stats", mapOf("values" to emptyList<Double>(), "audio" to stats()))
        }
    }

    private var lastStatsAt = 0L

    fun setMuted(on: Boolean) {
        muted = on
        synchronized(lock) { track?.let { applyVolume(it) } }
    }

    fun release() {
        synchronized(lock) {
            released = true
            stopTrackLocked()
            lock.notifyAll()
        }
        abandonFocus()
    }

    /** queued ms, underruns, resyncs, playing (1/0), chunks. */
    fun stats(): List<Double> = synchronized(lock) {
        val perMs = bytesPerMs()
        listOf(
            if (perMs > 0) queuedBytes.toDouble() / perMs else 0.0,
            underruns.toDouble(), resyncs.toDouble(), if (playing) 1.0 else 0.0, chunks.toDouble(),
        )
    }

    private fun applyVolume(track: AudioTrack) {
        track.setVolume(if (muted || focusLost) 0f else 1f)
    }

    private fun stopTrackLocked() {
        track?.let {
            try {
                it.pause()
                it.flush()
                it.release()
            } catch (_: Exception) {
            }
        }
        track = null
        queue.clear()
        queuedBytes = 0
        playing = false
    }

    private fun writeLoop() {
        while (true) {
            val chunk: ByteArray
            val target: AudioTrack
            synchronized(lock) {
                while (!released) {
                    val perMs = bytesPerMs()
                    val ready = if (playing) queue.isNotEmpty() else perMs > 0 && queuedBytes >= perMs * TARGET_MS
                    if (ready && track != null) break
                    if (playing && queue.isEmpty()) {
                        lock.wait(DRY_MS)
                        if (queue.isEmpty() && playing && !released) {
                            // A gap or a pause: wait for the target again.
                            underruns++
                            playing = false
                            try {
                                track?.pause()
                            } catch (_: Exception) {
                            }
                        }
                        continue
                    }
                    lock.wait()
                }
                if (released) return
                val current = track ?: return
                if (!playing) {
                    playing = true
                    requestFocus()
                    try {
                        current.play()
                    } catch (_: Exception) {
                    }
                }
                chunk = queue.removeFirst()
                queuedBytes -= chunk.size
                target = current
            }
            try {
                target.write(chunk, 0, chunk.size, AudioTrack.WRITE_BLOCKING)
            } catch (_: Exception) {
                // Released meanwhile.
            }
        }
    }

    // ------------------------------------------------------------ focus
    // Like any video: the window's sound takes the audio focus while it
    // plays, and goes quiet while another app holds it.

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        focusLost = change == AudioManager.AUDIOFOCUS_LOSS ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
        synchronized(lock) { track?.let { applyVolume(it) } }
    }

    private fun requestFocus() {
        if (focusRequest != null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
            )
            .setOnAudioFocusChangeListener(focusListener)
            .build()
        focusRequest = request
        audioManager?.requestAudioFocus(request)
    }

    private fun abandonFocus() {
        val request = focusRequest ?: return
        focusRequest = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioManager?.abandonAudioFocusRequest(request)
        }
    }
}
