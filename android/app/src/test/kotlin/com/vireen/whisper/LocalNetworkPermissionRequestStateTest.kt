package com.vireen.whisper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalNetworkPermissionRequestStateTest {
    @Test
    fun requiredPermissionMatchesAndroid16CompatAndAndroid17Enforcement() {
        assertNull(requiredLocalNetworkPermission(sdkInt = 35, android16CompatTest = true))
        assertNull(requiredLocalNetworkPermission(sdkInt = 36, android16CompatTest = false))
        assertEquals(
            "android.permission.NEARBY_WIFI_DEVICES",
            requiredLocalNetworkPermission(sdkInt = 36, android16CompatTest = true),
        )
        assertEquals(
            "android.permission.ACCESS_LOCAL_NETWORK",
            requiredLocalNetworkPermission(sdkInt = 37, android16CompatTest = false),
        )
        assertEquals(
            "android.permission.ACCESS_LOCAL_NETWORK",
            requiredLocalNetworkPermission(sdkInt = 40, android16CompatTest = false),
        )
    }

    @Test
    fun configurationDetachPreservesPendingRequestAndMergedCallbacks() {
        val state = LocalNetworkPermissionRequestState<String>(100..110)
        val first = state.enqueue("permission", "first")

        assertEquals(PermissionRequestDisposition.START, first.disposition)
        assertEquals(100, first.requestCode)
        assertNull(state.onActivityDetached(permanent = false))
        assertTrue(state.hasPendingRequest)

        val merged = state.enqueue("permission", "second")
        assertEquals(PermissionRequestDisposition.MERGED, merged.disposition)
        assertNull(merged.requestCode)

        val completion = state.complete(100)
        assertEquals("permission", completion?.permission)
        assertEquals(listOf("first", "second"), completion?.callbacks)
        assertFalse(state.hasPendingRequest)
    }

    @Test
    fun permanentDetachCompletesAndClearsEveryPendingCallback() {
        val state = LocalNetworkPermissionRequestState<String>(200..210)
        state.enqueue("permission", "first")
        state.enqueue("permission", "second")

        val completion = state.onActivityDetached(permanent = true)

        assertEquals(listOf("first", "second"), completion?.callbacks)
        assertFalse(state.hasPendingRequest)
        assertNull(state.complete(200))
    }

    @Test
    fun staleOrUnownedCallbackCannotCompleteANewerRequest() {
        val state = LocalNetworkPermissionRequestState<String>(300..310)
        val firstCode = state.enqueue("permission", "first").requestCode!!
        assertNull(state.complete(firstCode + 99))
        assertTrue(state.hasPendingRequest)
        assertEquals(listOf("first"), state.complete(firstCode)?.callbacks)

        val secondCode = state.enqueue("permission", "second").requestCode!!
        assertNotEquals(firstCode, secondCode)
        assertNull(state.complete(firstCode))
        assertTrue(state.hasPendingRequest)
        assertEquals(listOf("second"), state.complete(secondCode)?.callbacks)
        assertNull(state.complete(secondCode))
    }

    @Test
    fun callbackForAnotherPermissionDoesNotDrainCurrentRequest() {
        val state = LocalNetworkPermissionRequestState<String>(350..360)
        val requestCode = state.enqueue("local-network", "pending").requestCode!!

        assertNull(state.complete(requestCode, listOf("notifications")))
        assertTrue(state.hasPendingRequest)
        assertEquals(
            listOf("pending"),
            state.complete(requestCode, listOf("local-network"))?.callbacks,
        )
    }

    @Test
    fun differentPermissionsRunSerially() {
        val state = LocalNetworkPermissionRequestState<String>(400..410)
        val firstCode = state.enqueue("permission-a", "first").requestCode!!

        val queued = state.enqueue("permission-b", "second")

        assertEquals(PermissionRequestDisposition.QUEUED, queued.disposition)
        assertNull(queued.requestCode)

        val first = state.complete(firstCode)
        assertEquals("permission-a", first?.permission)
        assertEquals(listOf("first"), first?.callbacks)
        assertEquals("permission-b", first?.nextRequest?.permission)
        assertTrue(state.hasPendingRequest)

        val secondCode = first?.nextRequest?.requestCode!!
        val second = state.complete(secondCode)
        assertEquals("permission-b", second?.permission)
        assertEquals(listOf("second"), second?.callbacks)
        assertNull(second?.nextRequest)
        assertFalse(state.hasPendingRequest)
    }

    @Test
    fun matchingQueuedPermissionMergesBehindTheActiveRequest() {
        val state = LocalNetworkPermissionRequestState<String>(420..430)
        val firstCode = state.enqueue("permission-a", "first").requestCode!!

        assertEquals(
            PermissionRequestDisposition.QUEUED,
            state.enqueue("permission-b", "second").disposition,
        )
        assertEquals(
            PermissionRequestDisposition.MERGED,
            state.enqueue("permission-b", "third").disposition,
        )

        val secondRequest = state.complete(firstCode)?.nextRequest!!
        assertEquals(
            listOf("second", "third"),
            state.complete(secondRequest.requestCode)?.callbacks,
        )
    }

    @Test
    fun permanentDetachDrainsActiveAndQueuedCallbacks() {
        val state = LocalNetworkPermissionRequestState<String>(440..450)
        state.enqueue("permission-a", "first")
        state.enqueue("permission-b", "second")
        state.enqueue("permission-b", "third")

        val completions = state.onActivityPermanentlyDetached()

        assertEquals(2, completions.size)
        assertEquals("permission-a", completions[0].permission)
        assertEquals(listOf("first"), completions[0].callbacks)
        assertEquals("permission-b", completions[1].permission)
        assertEquals(listOf("second", "third"), completions[1].callbacks)
        assertFalse(state.hasPendingRequest)
    }

    @Test
    fun deniedPermissionRevokedByPolicyIsRestricted() {
        assertEquals(
            NativeLocalNetworkPermissionStatus.RESTRICTED,
            queryNativePermissionStatus(
                isGranted = { false },
                isRevokedByPolicy = { true },
            ),
        )
        assertEquals(
            NativeLocalNetworkPermissionStatus.DENIED,
            queryNativePermissionStatus(
                isGranted = { false },
                isRevokedByPolicy = { false },
            ),
        )
    }

    @Test
    fun securityExceptionFailsClosedAsRestricted() {
        assertEquals(
            NativeLocalNetworkPermissionStatus.RESTRICTED,
            queryNativePermissionStatus(
                isGranted = { throw SecurityException("blocked") },
                isRevokedByPolicy = { false },
            ),
        )
        assertEquals(
            NativeLocalNetworkPermissionStatus.RESTRICTED,
            queryNativePermissionStatus(
                isGranted = { false },
                isRevokedByPolicy = { throw SecurityException("blocked") },
            ),
        )
    }
}
