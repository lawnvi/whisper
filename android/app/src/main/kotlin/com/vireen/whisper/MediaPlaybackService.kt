package com.vireen.whisper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat

/**
 * 播放端媒体外壳:MediaSession + MediaStyle 通知 + mediaPlayback 前台服务。
 * 只呈现状态、转发控制意图(经 AudioSharePlugin 回 Dart);不触碰播放数据通路。
 * 直播流:不设时长、不显示 seek 条;重连握手期用 STATE_BUFFERING。
 */
class MediaPlaybackService : Service() {
    private var mediaSession: MediaSessionCompat? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        mediaSession = MediaSessionCompat(this, "WhisperMediaSession").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() {
                    AudioSharePlugin.dispatchMediaControl("resume")
                }

                override fun onPause() {
                    AudioSharePlugin.dispatchMediaControl("pause")
                }

                override fun onStop() {
                    AudioSharePlugin.dispatchMediaControl("disconnect")
                }
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val state = intent?.getStringExtra(EXTRA_STATE) ?: STATE_STOPPED
        if (state == STATE_STOPPED) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Whisper"
        val subtitle = intent?.getStringExtra(EXTRA_SUBTITLE) ?: ""
        val canResume = intent?.getBooleanExtra(EXTRA_CAN_RESUME, true) ?: true
        val pauseLabel = intent?.getStringExtra(EXTRA_PAUSE_LABEL) ?: "Pause"
        val playLabel = intent?.getStringExtra(EXTRA_PLAY_LABEL) ?: "Play"
        val disconnectLabel =
            intent?.getStringExtra(EXTRA_DISCONNECT_LABEL) ?: "Disconnect"
        updatePlaybackState(state)
        startForeground(
            NOTIFICATION_ID,
            buildNotification(state, title, subtitle, canResume, pauseLabel, playLabel, disconnectLabel),
        )
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        mediaSession?.release()
        mediaSession = null
        super.onDestroy()
    }

    private fun updatePlaybackState(state: String) {
        val playbackState = when (state) {
            STATE_PLAYING -> PlaybackStateCompat.STATE_PLAYING
            STATE_BUFFERING -> PlaybackStateCompat.STATE_BUFFERING
            else -> PlaybackStateCompat.STATE_PAUSED
        }
        val actions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_STOP
        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(actions)
                .setState(playbackState, PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN, 1.0f)
                .build(),
        )
    }

    private fun buildNotification(
        state: String,
        title: String,
        subtitle: String,
        canResume: Boolean,
        pauseLabel: String,
        playLabel: String,
        disconnectLabel: String,
    ): Notification {
        ensureChannel()
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(buildContentIntent())
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setOngoing(state == STATE_PLAYING || state == STATE_BUFFERING)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)

        if (state == STATE_PLAYING || state == STATE_BUFFERING) {
            builder.addAction(
                android.R.drawable.ic_media_pause, pauseLabel,
                controlIntent("pause", 1),
            )
        } else if (canResume) {
            builder.addAction(
                android.R.drawable.ic_media_play, playLabel,
                controlIntent("resume", 2),
            )
        }
        builder.addAction(
            android.R.drawable.ic_menu_close_clear_cancel, disconnectLabel,
            controlIntent("disconnect", 3),
        )
        // 紧凑视图索引跟随实际 addAction 数量:有播放/暂停键时 disconnect 在 1,否则只有 0。
        val hasPlaybackAction =
            state == STATE_PLAYING || state == STATE_BUFFERING || canResume
        val mediaStyle = androidx.media.app.NotificationCompat.MediaStyle()
            .setMediaSession(mediaSession?.sessionToken)
        if (hasPlaybackAction) {
            mediaStyle.setShowActionsInCompactView(0, 1)
        } else {
            mediaStyle.setShowActionsInCompactView(0)
        }
        builder.setStyle(mediaStyle)
        return builder.build()
    }

    private fun controlIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, MediaControlReceiver::class.java)
            .putExtra(EXTRA_CONTROL_ACTION, action)
        return PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun buildContentIntent(): PendingIntent {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Whisper Media", NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) },
        )
    }

    companion object {
        const val CHANNEL_ID = "whisper.media_playback"
        const val NOTIFICATION_ID = 10023
        const val EXTRA_STATE = "state"
        const val EXTRA_TITLE = "title"
        const val EXTRA_SUBTITLE = "subtitle"
        const val EXTRA_CAN_RESUME = "canResume"
        const val EXTRA_PAUSE_LABEL = "pauseLabel"
        const val EXTRA_PLAY_LABEL = "playLabel"
        const val EXTRA_DISCONNECT_LABEL = "disconnectLabel"
        const val EXTRA_CONTROL_ACTION = "controlAction"
        const val STATE_PLAYING = "playing"
        const val STATE_PAUSED = "paused"
        const val STATE_BUFFERING = "buffering"
        const val STATE_STOPPED = "stopped"
    }
}

/** 通知 action 按钮 → 转发给 AudioSharePlugin(主线程)→ Dart。 */
class MediaControlReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra(MediaPlaybackService.EXTRA_CONTROL_ACTION) ?: return
        AudioSharePlugin.dispatchMediaControl(action)
    }
}
