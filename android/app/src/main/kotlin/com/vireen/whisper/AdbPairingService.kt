package com.vireen.whisper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.RemoteInput
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.util.concurrent.Executors

/**
 * Takes the Wireless debugging pairing code in a notification, so the user can
 * stay on the system's page that shows it. Anything that opens over that page
 * pauses it, and that closes the code, so a reply here is the only way in.
 *
 * One row from start to end: it appears when the system offers pairing and
 * changes in place until the result, which clears itself. The service itself
 * adds no row: it shares Whisper's foreground notification.
 */
class AdbPairingService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var finder: AdbPortFinder? = null
    private var port: Int? = null
    private var pairing = false
    private var failed = false
    private var starting = false
    private var ended = false
    private var keepRow = false
    private var strings = lastStrings
    private val giveUp = Runnable { finish() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_BEGIN -> begin(intent)
            ACTION_CODE -> {
                val code = RemoteInput.getResultsFromIntent(intent)
                    ?.getCharSequence(KEY_CODE)?.toString()?.trim().orEmpty()
                submit(code)
            }
            ACTION_CANCEL -> finish()
            ACTION_RESULT -> {
                showResult(intent.getBooleanExtra(EXTRA_OK, false))
                keepRow = true
                finish()
            }
        }
        return START_NOT_STICKY
    }

    private fun begin(intent: Intent) {
        strings = intent.getBundleExtra(EXTRA_STRINGS) ?: Bundle()
        lastStrings = strings
        ensureChannel()
        holdForeground()
        if (finder == null) {
            finder = AdbPortFinder(this, AdbPortFinder.PAIRING).also { found ->
                found.start { next ->
                    // A late answer must not bring the row back after the end.
                    if (!ended) {
                        port = next
                        pairingPort = next
                        if (next != null) {
                            failed = false
                        }
                        show()
                    }
                }
            }
        }
        main.removeCallbacks(giveUp)
        main.postDelayed(giveUp, GIVE_UP_MS)
    }

    private fun submit(code: String) {
        val target = port
        if (target == null || pairing || code.isEmpty() ||
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S
        ) {
            show()
            return
        }
        pairing = true
        show()
        val app = applicationContext
        worker.execute {
            val ok = try {
                AdbPairing.pair(AdbIdentity.load(app), target, code)
                true
            } catch (_: Exception) {
                false
            }
            main.post {
                pairing = false
                if (ok) {
                    // Says so until the agent is running: the user is still in
                    // the system's settings, not in Whisper.
                    starting = true
                    show()
                    if (!AdbSelfStartEvents.paired(app)) {
                        finish()
                    }
                } else {
                    failed = true
                    show()
                }
            }
        }
    }

    private fun finish() {
        if (ended) {
            return
        }
        ended = true
        main.removeCallbacks(giveUp)
        finder?.stop()
        finder = null
        pairingPort = null
        releaseForeground()
        stopSelf()
    }

    override fun onDestroy() {
        ended = true
        main.removeCallbacks(giveUp)
        finder?.stop()
        pairingPort = null
        if (!keepRow) {
            notifications().cancel(ROW_ID)
        }
        worker.shutdown()
        super.onDestroy()
    }

    /** Shares Whisper's foreground notification, or starts it if nothing else is using it. */
    private fun holdForeground() {
        val shared = UnifiedForegroundNotification.current(this)
            ?: Notification.Builder(this, UnifiedForegroundNotification.CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_flow)
                .setContentTitle(word("title"))
                .setContentText(word("waitingCode"))
                .setOngoing(true)
                .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                UnifiedForegroundNotification.NOTIFICATION_ID,
                shared,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(UnifiedForegroundNotification.NOTIFICATION_ID, shared)
        }
    }

    /** Leaves the shared notification to whoever else holds it, or takes it away. */
    private fun releaseForeground() {
        if (UnifiedForegroundNotification.current(this) == null) {
            // Detaching first would leave it behind: a cancel can't reach a
            // notification the system still counts as foreground.
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(STOP_FOREGROUND_DETACH)
            UnifiedForegroundNotification.publishCurrent(this)
        }
    }

    private fun show() {
        if (ended) {
            return
        }
        when {
            starting -> notifications().notify(ROW_ID, buildProgress("starting"))
            pairing -> notifications().notify(ROW_ID, buildProgress("pairing"))
            port != null -> notifications().notify(ROW_ID, buildReply())
            // The system's page shows the way until it offers pairing.
            else -> notifications().cancel(ROW_ID)
        }
    }

    private fun word(key: String): String = strings.getString(key).orEmpty()

    private fun rowBuilder(title: String, text: String): Notification.Builder =
        Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_flow)
            .setContentTitle(title)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)

    /**
     * A message with a reply. It has to be both: HyperOS opens the reply field
     * neither on an ongoing notification nor on one in the plain style (seen on
     * Xiaomi, HyperOS 4). Swiping it away gives up.
     */
    private fun buildReply(): Notification {
        val input = RemoteInput.Builder(KEY_CODE).setLabel(word("codeHint")).build()
        val reply = PendingIntent.getService(
            this,
            REQUEST_CODE,
            Intent(this, AdbPairingService::class.java).setAction(ACTION_CODE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        val cancel = PendingIntent.getService(
            this,
            REQUEST_CANCEL,
            Intent(this, AdbPairingService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val text = word(if (failed) "failed" else "enterCode")
        val sender = Person.Builder().setName(word("codeTitle")).build()
        return rowBuilder(word("codeTitle"), text)
            .setStyle(
                Notification.MessagingStyle(sender)
                    .addMessage(text, System.currentTimeMillis(), sender),
            )
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setDeleteIntent(cancel)
            .addAction(
                Notification.Action.Builder(null, word("codeAction"), reply)
                    .addRemoteInput(input)
                    .setSemanticAction(Notification.Action.SEMANTIC_ACTION_REPLY)
                    .setAllowGeneratedReplies(false)
                    .build(),
            )
            .build()
    }

    private fun buildProgress(key: String): Notification =
        rowBuilder(word("title"), word(key)).setOngoing(true).build()

    /** The last word: outlives the service and clears itself after a moment. */
    private fun showResult(ok: Boolean) {
        notifications().notify(
            ROW_ID,
            rowBuilder(word("title"), word(if (ok) "started" else "startFailed"))
                .setAutoCancel(true)
                .setTimeoutAfter(RESULT_SHOWN_MS)
                .build(),
        )
    }

    private fun notifications() =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel() {
        notifications().createNotificationChannel(
            NotificationChannel(
                CHANNEL,
                word("channel"),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply { setSound(null, null) },
        )
    }

    companion object {
        private const val ACTION_BEGIN = "com.vireen.whisper.adb_pairing.BEGIN"
        private const val ACTION_CODE = "com.vireen.whisper.adb_pairing.CODE"
        private const val ACTION_CANCEL = "com.vireen.whisper.adb_pairing.CANCEL"
        private const val ACTION_RESULT = "com.vireen.whisper.adb_pairing.RESULT"
        private const val EXTRA_OK = "ok"
        private const val EXTRA_STRINGS = "strings"
        private const val KEY_CODE = "code"
        private const val CHANNEL = "whisper_adb_pairing"
        private const val ROW_ID = 7315
        private const val REQUEST_CODE = 7311
        private const val REQUEST_CANCEL = 7312
        private const val RESULT_SHOWN_MS = 8_000L

        // The system's pairing page doesn't stay up for long; neither do we.
        private const val GIVE_UP_MS = 5L * 60 * 1000

        private var lastStrings = Bundle()

        /** The pairing port while this service watches it. */
        @Volatile
        var pairingPort: Int? = null
            private set

        fun begin(context: Context, strings: Bundle) {
            context.startForegroundService(
                Intent(context, AdbPairingService::class.java)
                    .setAction(ACTION_BEGIN)
                    .putExtra(EXTRA_STRINGS, strings),
            )
        }

        /** How the start after a pairing in the notification went. */
        fun finishStarting(context: Context, ok: Boolean) {
            context.startService(
                Intent(context, AdbPairingService::class.java)
                    .setAction(ACTION_RESULT)
                    .putExtra(EXTRA_OK, ok),
            )
        }

        fun cancel(context: Context) {
            context.stopService(Intent(context, AdbPairingService::class.java))
        }
    }
}
