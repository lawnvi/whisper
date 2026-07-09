package com.vireen.whisper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalNetworkPermissionRequestStateTest {
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
    fun differentPermissionDoesNotJoinAnInFlightRequest() {
        val state = LocalNetworkPermissionRequestState<String>(400..410)
        state.enqueue("permission-a", "first")

        val conflict = state.enqueue("permission-b", "second")

        assertEquals(PermissionRequestDisposition.CONFLICT, conflict.disposition)
        assertNull(conflict.requestCode)
        assertEquals(listOf("first"), state.complete(400)?.callbacks)
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
