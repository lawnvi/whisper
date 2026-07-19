package com.vireen.whisper

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat

/**
 * 播放端媒体外壳:MediaSession + MediaStyle 通知 + mediaPlayback 前台服务。
 * 只呈现状态、转发控制意图(经 AudioSharePlugin 回 Dart);不触碰播放数据通路。
 * 直播流:不设时长、不显示 seek 条;重连握手期用 STATE_BUFFERING。
 */
class MediaPlaybackService : Service() {
    private var mediaSession: MediaSessionCompat? = null
    private var registered = false
    @Volatile
    private var acceptsDirectCommands = true

    // channel 名由 Flutter 侧随启动 Intent 传入已本地化文案,缺省回退英文。
    private var channelName: String = DEFAULT_CHANNEL_NAME

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        acceptsDirectCommands = true
        activeInstance = this
        isRunning = true
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
        acceptSystemCommand(intent)
        return START_NOT_STICKY
    }

    @Synchronized
    private fun acceptSystemCommand(intent: Intent?) {
        acceptsDirectCommands = true
        handleCommand(intent)
    }

    @Synchronized
    private fun deliverCommand(intent: Intent): Boolean {
        if (!acceptsDirectCommands) {
            return false
        }
        handleCommand(intent)
        return true
    }

    @Synchronized
    private fun beginStopping() {
        acceptsDirectCommands = false
    }

    private fun handleCommand(intent: Intent?) {
        intent?.getStringExtra(EXTRA_CHANNEL_NAME)
            ?.takeIf { it.isNotBlank() }?.let { channelName = it }
        val state = intent?.getStringExtra(EXTRA_STATE) ?: STATE_STOPPED
        if (state == STATE_STOPPED) {
            beginStopping()
            updatePlaybackState(state)
            registered = false
            val current = UnifiedForegroundNotification.clearMedia(this)
            startForeground(
                NOTIFICATION_ID,
                current ?: UnifiedForegroundNotification.bootstrap(this),
            )
            if (current == null) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                stopForeground(STOP_FOREGROUND_DETACH)
                UnifiedForegroundNotification.publishCurrent(this)
            }
            stopSelf()
            return
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Whisper"
        val subtitle = intent?.getStringExtra(EXTRA_SUBTITLE) ?: ""
        val canResume = intent?.getBooleanExtra(EXTRA_CAN_RESUME, true) ?: true
        val pauseLabel = intent?.getStringExtra(EXTRA_PAUSE_LABEL) ?: "Pause"
        val playLabel = intent?.getStringExtra(EXTRA_PLAY_LABEL) ?: "Play"
        val disconnectLabel =
            intent?.getStringExtra(EXTRA_DISCONNECT_LABEL) ?: "Disconnect"
        updatePlaybackState(state)
        val notification = UnifiedForegroundNotification.setMedia(
            this,
            state,
            title,
            subtitle,
            canResume,
            pauseLabel,
            playLabel,
            disconnectLabel,
            channelName,
            mediaSession?.sessionToken,
        )
        registered = true
        startForeground(
            NOTIFICATION_ID,
            notification,
        )
    }

    override fun onDestroy() {
        beginStopping()
        isRunning = false
        if (activeInstance === this) {
            activeInstance = null
        }
        if (registered) {
            registered = false
            stopForeground(STOP_FOREGROUND_DETACH)
            UnifiedForegroundNotification.clearMedia(this)
            UnifiedForegroundNotification.publishCurrent(this)
        }
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

    companion object {
        const val NOTIFICATION_ID = UnifiedForegroundNotification.NOTIFICATION_ID
        @Volatile
        var isRunning = false
            private set
        @Volatile
        private var activeInstance: MediaPlaybackService? = null

        fun deliverToRunning(intent: Intent): Boolean {
            val service = activeInstance ?: return false
            return service.deliverCommand(intent)
        }

        fun stopForEngineDetach(context: Context) {
            val intent = Intent(context, MediaPlaybackService::class.java)
                .putExtra(EXTRA_STATE, STATE_STOPPED)
            if (deliverToRunning(intent)) {
                return
            }
            UnifiedForegroundNotification.clearMedia(context)
            context.stopService(intent)
            UnifiedForegroundNotification.publishCurrent(context)
        }
        const val EXTRA_STATE = "state"
        const val EXTRA_TITLE = "title"
        const val EXTRA_SUBTITLE = "subtitle"
        const val EXTRA_CAN_RESUME = "canResume"
        const val EXTRA_PAUSE_LABEL = "pauseLabel"
        const val EXTRA_PLAY_LABEL = "playLabel"
        const val EXTRA_DISCONNECT_LABEL = "disconnectLabel"
        const val EXTRA_CHANNEL_NAME = "channelName"
        const val EXTRA_CONTROL_ACTION = "controlAction"
        private const val DEFAULT_CHANNEL_NAME = "Whisper Media"
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
