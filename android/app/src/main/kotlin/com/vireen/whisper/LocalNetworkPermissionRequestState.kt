package com.vireen.whisper

internal fun requiredLocalNetworkPermission(
    sdkInt: Int,
    android16CompatTest: Boolean,
    nearbyWifiDevicesPermission: String = "android.permission.NEARBY_WIFI_DEVICES",
    accessLocalNetworkPermission: String = "android.permission.ACCESS_LOCAL_NETWORK",
): String? {
    return when {
        sdkInt >= 37 -> accessLocalNetworkPermission
        sdkInt == 36 && android16CompatTest -> nearbyWifiDevicesPermission
        else -> null
    }
}

internal enum class PermissionRequestDisposition {
    START,
    MERGED,
    QUEUED,
}

internal data class PermissionRequestEnqueue(
    val disposition: PermissionRequestDisposition,
    val requestCode: Int? = null,
)

internal data class PendingPermissionCompletion<T>(
    val permission: String,
    val callbacks: List<T>,
    val nextRequest: PendingPermissionRequest? = null,
)

internal data class PendingPermissionRequest(
    val permission: String,
    val requestCode: Int,
)

internal class LocalNetworkPermissionRequestState<T>(
    private val requestCodes: IntRange = DEFAULT_REQUEST_CODES,
) {
    private var nextRequestCode = requestCodes.first
    private var pendingRequestCode: Int? = null
    private var pendingPermission: String? = null
    private val callbacks = mutableListOf<T>()
    private val waiting = mutableListOf<QueuedPermissionRequest<T>>()

    init {
        require(!requestCodes.isEmpty() && requestCodes.first >= 0 && requestCodes.last <= 0xffff)
    }

    val hasPendingRequest: Boolean
        get() = pendingRequestCode != null

    fun enqueue(permission: String, callback: T): PermissionRequestEnqueue {
        val activePermission = pendingPermission
        if (activePermission != null) {
            if (activePermission == permission) {
                callbacks.add(callback)
                return PermissionRequestEnqueue(PermissionRequestDisposition.MERGED)
            }
            val queued = waiting.firstOrNull { it.permission == permission }
            if (queued != null) {
                queued.callbacks.add(callback)
                return PermissionRequestEnqueue(PermissionRequestDisposition.MERGED)
            }
            waiting.add(
                QueuedPermissionRequest(
                    permission = permission,
                    callbacks = mutableListOf(callback),
                ),
            )
            return PermissionRequestEnqueue(PermissionRequestDisposition.QUEUED)
        }

        val requestCode = allocateRequestCode()
        pendingRequestCode = requestCode
        pendingPermission = permission
        callbacks.add(callback)
        return PermissionRequestEnqueue(
            disposition = PermissionRequestDisposition.START,
            requestCode = requestCode,
        )
    }

    fun complete(requestCode: Int): PendingPermissionCompletion<T>? {
        if (pendingRequestCode != requestCode) {
            return null
        }
        return drain()
    }

    fun complete(
        requestCode: Int,
        reportedPermissions: Collection<String>,
    ): PendingPermissionCompletion<T>? {
        if (pendingRequestCode != requestCode || pendingPermission !in reportedPermissions) {
            return null
        }
        return drain()
    }

    fun onActivityDetached(permanent: Boolean): PendingPermissionCompletion<T>? {
        return if (permanent) onActivityPermanentlyDetached().firstOrNull() else null
    }

    fun onActivityPermanentlyDetached(): List<PendingPermissionCompletion<T>> {
        val completions = mutableListOf<PendingPermissionCompletion<T>>()
        val activePermission = pendingPermission
        if (activePermission != null) {
            completions.add(
                PendingPermissionCompletion(
                    permission = activePermission,
                    callbacks = callbacks.toList(),
                ),
            )
        }
        completions.addAll(
            waiting.map { queued ->
                PendingPermissionCompletion(
                    permission = queued.permission,
                    callbacks = queued.callbacks.toList(),
                )
            },
        )
        pendingRequestCode = null
        pendingPermission = null
        callbacks.clear()
        waiting.clear()
        return completions
    }

    private fun allocateRequestCode(): Int {
        val allocated = nextRequestCode
        nextRequestCode = if (allocated == requestCodes.last) {
            requestCodes.first
        } else {
            allocated + 1
        }
        return allocated
    }

    private fun drain(): PendingPermissionCompletion<T>? {
        val permission = pendingPermission ?: return null
        val completion = PendingPermissionCompletion(
            permission = permission,
            callbacks = callbacks.toList(),
            nextRequest = promoteNext(),
        )
        return completion
    }

    private fun promoteNext(): PendingPermissionRequest? {
        pendingRequestCode = null
        pendingPermission = null
        callbacks.clear()
        if (waiting.isEmpty()) {
            return null
        }
        val next = waiting.removeAt(0)
        val requestCode = allocateRequestCode()
        pendingRequestCode = requestCode
        pendingPermission = next.permission
        callbacks.addAll(next.callbacks)
        return PendingPermissionRequest(
            permission = next.permission,
            requestCode = requestCode,
        )
    }

    private data class QueuedPermissionRequest<T>(
        val permission: String,
        val callbacks: MutableList<T>,
    )

    private companion object {
        val DEFAULT_REQUEST_CODES = 0x5200..0x7fff
    }
}

internal enum class NativeLocalNetworkPermissionStatus(val wireValue: String) {
    GRANTED("granted"),
    DENIED("denied"),
    RESTRICTED("restricted"),
    UNKNOWN("unknown"),
}

internal fun queryNativePermissionStatus(
    isGranted: () -> Boolean,
    isRevokedByPolicy: () -> Boolean,
): NativeLocalNetworkPermissionStatus {
    return try {
        when {
            isGranted() -> NativeLocalNetworkPermissionStatus.GRANTED
            isRevokedByPolicy() -> NativeLocalNetworkPermissionStatus.RESTRICTED
            else -> NativeLocalNetworkPermissionStatus.DENIED
        }
    } catch (_: SecurityException) {
        NativeLocalNetworkPermissionStatus.RESTRICTED
    }
}
