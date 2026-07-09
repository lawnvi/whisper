package com.vireen.whisper

internal enum class PermissionRequestDisposition {
    START,
    MERGED,
    CONFLICT,
}

internal data class PermissionRequestEnqueue(
    val disposition: PermissionRequestDisposition,
    val requestCode: Int? = null,
)

internal data class PendingPermissionCompletion<T>(
    val permission: String,
    val callbacks: List<T>,
)

internal class LocalNetworkPermissionRequestState<T>(
    private val requestCodes: IntRange = DEFAULT_REQUEST_CODES,
) {
    private var nextRequestCode = requestCodes.first
    private var pendingRequestCode: Int? = null
    private var pendingPermission: String? = null
    private val callbacks = mutableListOf<T>()

    init {
        require(!requestCodes.isEmpty() && requestCodes.first >= 0 && requestCodes.last <= 0xffff)
    }

    val hasPendingRequest: Boolean
        get() = pendingRequestCode != null

    fun enqueue(permission: String, callback: T): PermissionRequestEnqueue {
        val activePermission = pendingPermission
        if (activePermission != null) {
            if (activePermission != permission) {
                return PermissionRequestEnqueue(PermissionRequestDisposition.CONFLICT)
            }
            callbacks.add(callback)
            return PermissionRequestEnqueue(PermissionRequestDisposition.MERGED)
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
        return if (permanent) drain() else null
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
        )
        pendingRequestCode = null
        pendingPermission = null
        callbacks.clear()
        return completion
    }

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
