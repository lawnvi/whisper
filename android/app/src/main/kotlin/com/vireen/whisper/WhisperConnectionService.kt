package com.vireen.whisper

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Reports pairing prompts as short self-managed incoming calls. This gives
 * CallStyle notifications the Android call exemption and lock-screen priority.
 */
class WhisperConnectionService : ConnectionService() {
    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection {
        val extras = incomingExtras(request.extras)
        val notificationId = extras.getInt(EXTRA_NOTIFICATION_ID, INVALID_NOTIFICATION_ID)
        if (notificationId == INVALID_NOTIFICATION_ID || cancelledIds.remove(notificationId)) {
            reportedIds.remove(notificationId)
            return Connection.createFailedConnection(DisconnectCause(DisconnectCause.CANCELED))
        }

        val deviceName = extras.getString(EXTRA_DEVICE_NAME).orEmpty()
        val peerId = extras.getString(EXTRA_PEER_ID).orEmpty()
        val connection = PairingConnection(
            notificationId = notificationId,
            answerIntent = extras.pendingIntent(EXTRA_ANSWER_INTENT),
            rejectIntent = extras.pendingIntent(EXTRA_REJECT_INTENT),
        ).apply {
            setAddress(
                request.address ?: Uri.fromParts(PhoneAccount.SCHEME_SIP, peerId, null),
                TelecomManager.PRESENTATION_ALLOWED,
            )
            setCallerDisplayName(deviceName, TelecomManager.PRESENTATION_ALLOWED)
            setConnectionProperties(Connection.PROPERTY_SELF_MANAGED)
            setAudioModeIsVoip(true)
            setRinging()
        }

        reportedIds.add(notificationId)
        activeConnections.put(notificationId, connection)?.finish(DisconnectCause.CANCELED)
        connection.startTimeout()
        return connection
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ) {
        val notificationId = incomingExtras(request.extras)
            .getInt(EXTRA_NOTIFICATION_ID, INVALID_NOTIFICATION_ID)
        reportedIds.remove(notificationId)
        cancelledIds.remove(notificationId)
    }

    private class PairingConnection(
        private val notificationId: Int,
        private val answerIntent: PendingIntent?,
        private val rejectIntent: PendingIntent?,
    ) : Connection() {
        private val finished = AtomicBoolean(false)
        private val timeout = Runnable { finish(DisconnectCause.MISSED) }

        fun startTimeout() {
            mainHandler.postDelayed(timeout, TIMEOUT_MILLIS)
        }

        override fun onAnswer() {
            resolve(answerIntent, DisconnectCause.LOCAL, answered = true)
        }

        override fun onAnswer(videoState: Int) {
            onAnswer()
        }

        override fun onReject() {
            resolve(rejectIntent, DisconnectCause.REJECTED)
        }

        override fun onDisconnect() {
            resolve(rejectIntent, DisconnectCause.LOCAL)
        }

        override fun onAbort() {
            resolve(rejectIntent, DisconnectCause.CANCELED)
        }

        fun finish(cause: Int) {
            complete(cause = cause)
        }

        private fun resolve(
            action: PendingIntent?,
            cause: Int,
            answered: Boolean = false,
        ) {
            if (!finished.compareAndSet(false, true)) {
                return
            }
            mainHandler.removeCallbacks(timeout)
            if (answered) {
                setActive()
            }
            try {
                action?.send()
            } catch (_: PendingIntent.CanceledException) {
                // The matching pairing request has already ended.
            }
            disconnect(cause)
        }

        private fun complete(cause: Int) {
            if (!finished.compareAndSet(false, true)) {
                return
            }
            mainHandler.removeCallbacks(timeout)
            disconnect(cause)
        }

        private fun disconnect(cause: Int) {
            activeConnections.remove(notificationId, this)
            reportedIds.remove(notificationId)
            cancelledIds.remove(notificationId)
            setDisconnected(DisconnectCause(cause))
            destroy()
        }
    }

    companion object {
        private const val PHONE_ACCOUNT_ID = "whisper_connection_requests"
        private const val EXTRA_NOTIFICATION_ID =
            "com.vireen.whisper.extra.CONNECTION_NOTIFICATION_ID"
        private const val EXTRA_DEVICE_NAME = "com.vireen.whisper.extra.CONNECTION_DEVICE_NAME"
        private const val EXTRA_PEER_ID = "com.vireen.whisper.extra.CONNECTION_PEER_ID"
        private const val EXTRA_ANSWER_INTENT = "com.vireen.whisper.extra.CONNECTION_ANSWER_INTENT"
        private const val EXTRA_REJECT_INTENT = "com.vireen.whisper.extra.CONNECTION_REJECT_INTENT"
        private const val INVALID_NOTIFICATION_ID = -1
        private const val TIMEOUT_MILLIS = 30_000L
        private val mainHandler = Handler(Looper.getMainLooper())
        private val activeConnections = ConcurrentHashMap<Int, PairingConnection>()
        private val reportedIds = ConcurrentHashMap.newKeySet<Int>()
        private val cancelledIds = ConcurrentHashMap.newKeySet<Int>()

        fun ensurePhoneAccount(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                return false
            }
            return try {
                val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                val account = PhoneAccount.builder(phoneAccountHandle(context), "Whisper")
                    .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                    .setSupportedUriSchemes(listOf(PhoneAccount.SCHEME_SIP))
                    .build()
                telecom.registerPhoneAccount(account)
                true
            } catch (_: RuntimeException) {
                false
            }
        }

        fun reportIncoming(
            context: Context,
            notificationId: Int,
            peerId: String,
            deviceName: String,
            answerIntent: PendingIntent,
            rejectIntent: PendingIntent,
        ): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !ensurePhoneAccount(context)) {
                return false
            }
            return try {
                val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                val handle = phoneAccountHandle(context)
                if (!telecom.isIncomingCallPermitted(handle)) {
                    return false
                }
                val callExtras = Bundle().apply {
                    putInt(EXTRA_NOTIFICATION_ID, notificationId)
                    putString(EXTRA_PEER_ID, peerId)
                    putString(EXTRA_DEVICE_NAME, deviceName)
                    putParcelable(EXTRA_ANSWER_INTENT, answerIntent)
                    putParcelable(EXTRA_REJECT_INTENT, rejectIntent)
                }
                val extras = Bundle(callExtras).apply {
                    putParcelable(
                        TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                        Uri.fromParts(PhoneAccount.SCHEME_SIP, peerId, null),
                    )
                    putBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS, callExtras)
                }
                cancelledIds.remove(notificationId)
                reportedIds.add(notificationId)
                telecom.addNewIncomingCall(handle, extras)
                true
            } catch (_: RuntimeException) {
                reportedIds.remove(notificationId)
                false
            }
        }

        fun dismissIncoming(notificationId: Int) {
            val connection = activeConnections[notificationId]
            if (connection != null) {
                mainHandler.post { connection.finish(DisconnectCause.LOCAL) }
                return
            }
            if (reportedIds.remove(notificationId)) {
                cancelledIds.add(notificationId)
                mainHandler.postDelayed(
                    { cancelledIds.remove(notificationId) },
                    5_000L,
                )
            }
        }

        private fun phoneAccountHandle(context: Context): PhoneAccountHandle =
            PhoneAccountHandle(
                ComponentName(context.applicationContext, WhisperConnectionService::class.java),
                PHONE_ACCOUNT_ID,
            )

        private fun incomingExtras(extras: Bundle?): Bundle {
            if (extras == null) {
                return Bundle.EMPTY
            }
            return extras.getBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS) ?: extras
        }

        @Suppress("DEPRECATION")
        private fun Bundle.pendingIntent(key: String): PendingIntent? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                getParcelable(key, PendingIntent::class.java)
            } else {
                getParcelable(key)
            }
    }
}
