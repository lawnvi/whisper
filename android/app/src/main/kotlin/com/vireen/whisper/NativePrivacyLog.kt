package com.vireen.whisper

import android.util.Log

internal enum class NativeLogEvent(val wireName: String) {
    audioFrameDropped("audio_frame_dropped"),
    audioFrameDroppedStale("audio_frame_dropped_stale"),
    audioPlaybackResyncFailed("audio_playback_resync_failed"),
    audioPlaybackResynced("audio_playback_resynced"),
    audioPlaybackSpeedChanged("audio_playback_speed_changed"),
    audioPlaybackSpeedFailed("audio_playback_speed_failed"),
    audioPlaybackStarted("audio_playback_started"),
    audioPlaybackStopped("audio_playback_stopped"),
    audioShortWrite("audio_short_write"),
    mediaServiceStartDenied("media_service_start_denied"),
    transferServiceStartDenied("transfer_service_start_denied"),
}

internal enum class NativeLogReason(val wireName: String) {
    none("none"),
    invalidState("invalid_state"),
    queueBacklog("queue_backlog"),
    startDenied("start_denied"),
}

internal object NativePrivacyLog {
    private const val TAG = "WhisperNative"
    private val enabled = System.getenv("WHISPER_REMOTE_INPUT_TRACE") == "1"

    val isEnabled: Boolean
        get() = enabled

    fun event(
        event: NativeLogEvent,
        reason: NativeLogReason = NativeLogReason.none,
        count: Long = 0L,
        bytes: Long = 0L,
    ) {
        if (!enabled) return
        val line =
            "event=${event.wireName} reason=${reason.wireName} count=$count bytes=$bytes"
        Log.d(TAG, line)
    }
}
