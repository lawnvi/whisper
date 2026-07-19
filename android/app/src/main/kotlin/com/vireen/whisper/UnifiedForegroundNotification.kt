package com.vireen.whisper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.support.v4.media.session.MediaSessionCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Keeps every Whisper foreground workload on one app-level notification.
 *
 * Android still tracks the LAN, transfer, and playback services independently,
 * but notification records are keyed by package and id. Sharing one id and one
 * renderer avoids stacking three near-identical notifications while preserving
 * each service's declared foreground-service type.
 */
object UnifiedForegroundNotification {
    const val CHANNEL_ID = "whisper.keep_alive"
    const val NOTIFICATION_ID = 10021

    private const val DEFAULT_CHANNEL_NAME = "Whisper"
    private const val DEFAULT_CHANNEL_DESCRIPTION =
        "Whisper background connection and activity"
    private const val PREFS_NAME = "whisper.keep_alive.channel"
    private const val PREF_CHANNEL_NAME = "channelName"
    private const val PREF_CHANNEL_DESCRIPTION = "channelDescription"

    private data class KeepAliveState(
        val title: String,
        val text: String,
        val progress: Int?,
        val indeterminate: Boolean,
    )

    private data class TransferState(
        val title: String,
        val text: String,
        val progress: Int?,
    )

    private data class MediaState(
        val state: String,
        val title: String,
        val subtitle: String,
        val canResume: Boolean,
        val pauseLabel: String,
        val playLabel: String,
        val disconnectLabel: String,
        val sessionToken: MediaSessionCompat.Token?,
    )

    data class FinishResult(
        val notification: Notification,
        val hasForegroundOwner: Boolean,
    )

    private var keepAlive: KeepAliveState? = null
    private var transfer: TransferState? = null
    private var media: MediaState? = null

    @Synchronized
    fun bootstrap(context: Context): Notification {
        ensureChannel(context)
        return buildCurrent(context)
            ?: baseBuilder(context, "Whisper", "Keeping connection alive")
                .setOngoing(true)
                .build()
    }

    @Synchronized
    fun setKeepAlive(
        context: Context,
        title: String,
        text: String,
        progress: Int?,
        indeterminate: Boolean,
        channelName: String,
        channelDescription: String,
    ): Notification {
        persistChannelText(context, channelName, channelDescription)
        keepAlive = KeepAliveState(title, text, progress, indeterminate)
        return buildCurrent(context)!!
    }

    @Synchronized
    fun clearKeepAlive(context: Context): Notification? {
        keepAlive = null
        return buildCurrent(context)
    }

    @Synchronized
    fun setTransferProgress(
        context: Context,
        title: String,
        text: String,
        progress: Int,
        channelName: String,
        channelDescription: String,
    ): Notification {
        persistChannelText(context, channelName, channelDescription)
        transfer = TransferState(title, text, progress.coerceIn(0, 100))
        return buildCurrent(context)!!
    }

    @Synchronized
    fun setTransferStatus(
        context: Context,
        title: String,
        text: String,
        channelName: String,
        channelDescription: String,
    ): Notification {
        persistChannelText(context, channelName, channelDescription)
        transfer = TransferState(title, text, null)
        return buildCurrent(context)!!
    }

    @Synchronized
    fun finishTransfer(context: Context, title: String, text: String): FinishResult {
        transfer = null
        val current = buildCurrent(context)
        if (current != null) {
            return FinishResult(current, true)
        }
        ensureChannel(context)
        return FinishResult(
            baseBuilder(context, title, text)
                .setOngoing(false)
                .setAutoCancel(true)
                .build(),
            false,
        )
    }

    @Synchronized
    fun cancelTransfer(context: Context): Notification? {
        transfer = null
        return buildCurrent(context)
    }

    @Synchronized
    fun clearTransfer(context: Context): Notification? {
        transfer = null
        return buildCurrent(context)
    }

    @Synchronized
    fun setMedia(
        context: Context,
        state: String,
        title: String,
        subtitle: String,
        canResume: Boolean,
        pauseLabel: String,
        playLabel: String,
        disconnectLabel: String,
        channelName: String,
        sessionToken: MediaSessionCompat.Token?,
    ): Notification {
        persistChannelText(context, channelName, "")
        media = MediaState(
            state,
            title,
            subtitle,
            canResume,
            pauseLabel,
            playLabel,
            disconnectLabel,
            sessionToken,
        )
        return buildCurrent(context)!!
    }

    @Synchronized
    fun clearMedia(context: Context): Notification? {
        media = null
        return buildCurrent(context)
    }

    @Synchronized
    fun publishCurrent(context: Context) {
        val manager = notificationManager(context)
        val current = buildCurrent(context)
        if (current == null) {
            manager.cancel(NOTIFICATION_ID)
        } else {
            manager.notify(NOTIFICATION_ID, current)
        }
    }

    private fun buildCurrent(context: Context): Notification? {
        ensureChannel(context)
        transfer?.let { state ->
            val builder = baseBuilder(context, state.title, state.text)
                .setOngoing(true)
            val progress = state.progress
            if (progress != null) {
                // ProgressStyle and MediaStyle are mutually exclusive. While
                // audio is active, keep the transfer text/progress but retain
                // the media session and its controls in the unified card.
                if (media == null && supportsLiveUpdates(context)) {
                    builder.setStyle(
                        NotificationCompat.ProgressStyle().setProgress(progress),
                    )
                    builder.setRequestPromotedOngoing(true)
                } else {
                    builder.setProgress(100, progress, false)
                }
            }
            media?.let { mediaState ->
                addMediaControls(context, builder, mediaState)
            }
            return builder.build()
        }

        media?.let { state ->
            val builder = baseBuilder(context, state.title, state.subtitle)
                .setOngoing(
                    state.state == MediaPlaybackService.STATE_PLAYING ||
                    state.state == MediaPlaybackService.STATE_BUFFERING,
                )
            addMediaControls(context, builder, state)
            return builder.build()
        }

        keepAlive?.let { state ->
            val builder = baseBuilder(context, state.title, state.text)
                .setOngoing(true)
            if (state.indeterminate) {
                builder.setProgress(100, 0, true)
            } else if (state.progress != null) {
                builder.setProgress(100, state.progress.coerceIn(0, 100), false)
            }
            return builder.build()
        }
        return null
    }

    private fun addMediaControls(
        context: Context,
        builder: NotificationCompat.Builder,
        state: MediaState,
    ) {
        if (state.state == MediaPlaybackService.STATE_PLAYING ||
            state.state == MediaPlaybackService.STATE_BUFFERING
        ) {
            builder.addAction(
                android.R.drawable.ic_media_pause,
                state.pauseLabel,
                mediaControlIntent(context, "pause", 1),
            )
        } else if (state.canResume) {
            builder.addAction(
                android.R.drawable.ic_media_play,
                state.playLabel,
                mediaControlIntent(context, "resume", 2),
            )
        }
        builder.addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            state.disconnectLabel,
            mediaControlIntent(context, "disconnect", 3),
        )
        val hasPlaybackAction =
            state.state == MediaPlaybackService.STATE_PLAYING ||
                state.state == MediaPlaybackService.STATE_BUFFERING ||
                state.canResume
        val style = androidx.media.app.NotificationCompat.MediaStyle()
            .setMediaSession(state.sessionToken)
        if (hasPlaybackAction) {
            style.setShowActionsInCompactView(0, 1)
        } else {
            style.setShowActionsInCompactView(0)
        }
        builder.setStyle(style)
    }

    private fun baseBuilder(
        context: Context,
        title: String,
        text: String,
    ): NotificationCompat.Builder {
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_whisper)
            .setContentIntent(contentIntent(context))
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
    }

    private fun contentIntent(context: Context): PendingIntent {
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun mediaControlIntent(
        context: Context,
        action: String,
        requestCode: Int,
    ): PendingIntent {
        val intent = Intent(context, MediaControlReceiver::class.java)
            .putExtra(MediaPlaybackService.EXTRA_CONTROL_ACTION, action)
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun supportsLiveUpdates(context: Context): Boolean {
        return Build.VERSION.SDK_INT >= 36 &&
            NotificationManagerCompat.from(context).canPostPromotedNotifications()
    }

    private fun persistChannelText(
        context: Context,
        suggestedName: String,
        suggestedDescription: String,
    ) {
        if (suggestedName.isBlank() && suggestedDescription.isBlank()) {
            return
        }
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val existingName = prefs.getString(PREF_CHANNEL_NAME, null)
        val existingDescription = prefs.getString(PREF_CHANNEL_DESCRIPTION, null)
        prefs.edit()
            .putString(
                PREF_CHANNEL_NAME,
                existingName?.takeIf { it.isNotBlank() }
                    ?: suggestedName.takeIf { it.isNotBlank() }
                    ?: DEFAULT_CHANNEL_NAME,
            )
            .putString(
                PREF_CHANNEL_DESCRIPTION,
                existingDescription?.takeIf { it.isNotBlank() }
                    ?: suggestedDescription.takeIf { it.isNotBlank() }
                    ?: DEFAULT_CHANNEL_DESCRIPTION,
            )
            .apply()
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val channelName = prefs.getString(PREF_CHANNEL_NAME, DEFAULT_CHANNEL_NAME)
            ?.takeIf { it.isNotBlank() } ?: DEFAULT_CHANNEL_NAME
        val channelDescription =
            prefs.getString(PREF_CHANNEL_DESCRIPTION, DEFAULT_CHANNEL_DESCRIPTION)
                ?.takeIf { it.isNotBlank() } ?: DEFAULT_CHANNEL_DESCRIPTION
        val channel = NotificationChannel(
            CHANNEL_ID,
            channelName,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = channelDescription
            setShowBadge(false)
        }
        notificationManager(context).createNotificationChannel(channel)
    }

    private fun notificationManager(context: Context): NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
}
