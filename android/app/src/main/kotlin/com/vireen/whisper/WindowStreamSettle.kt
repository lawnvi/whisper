package com.vireen.whisper

/**
 * When a streamed window's picture is ready to show (the rule every
 * receiver shares; the Dart twin is PictureSettle in
 * lib/page/window_stream/viewer/viewer_settle.dart). While a stream opens,
 * the other device fits the window to this screen, so the first frames come
 * at the wrong size; until the picture settles the activity shows a
 * placeholder and a spinner.
 *
 * Stable: the last decoded frame has the size of the latest SIZE message
 * (or, with none, the size frames last changed to) and that size has held
 * for 300 ms of streaming (counted from the first frame at the earliest).
 * 2.5 s after the first frame it counts as stable anyway. It stays stable;
 * after a resume the spinner returns only if no new frame comes in 300 ms.
 *
 * Pure: times are milliseconds from one clock (SystemClock.uptimeMillis).
 */
internal class WindowStreamSettle(private val openedAt: Long) {
    companion object {
        const val QUIET = 300L
        const val CAP = 2500L
        const val RESUME_GRACE = 300L
        const val SLOW_AFTER = 8000L
        private const val SLACK = 2
    }

    private var expectedW = 0
    private var expectedH = 0
    private var expectedAt = -1L
    private var expectedFromFrames = false
    private var decodedW = 0
    private var decodedH = 0
    private var firstFrameAt = -1L
    private var lastFrameAt = -1L
    private var waitingSince = -1L

    var stable = false
        private set

    var settledByCap = false
        private set

    /** Frames are wanted (report each one). */
    val watching get() = !stable || waitingSince >= 0

    fun loading(now: Long) = !stable || (waitingSince >= 0 && now - waitingSince >= RESUME_GRACE)

    fun slow(now: Long): Boolean {
        if (!loading(now)) return false
        var since = if (lastFrameAt >= 0) lastFrameAt else openedAt
        if (waitingSince > since) since = waitingSince
        return now - since >= SLOW_AFTER
    }

    fun alreadySettled() {
        stable = true
    }

    fun sizeMessage(width: Int, height: Int, now: Long) {
        if (width <= 0 || height <= 0) return
        if (width == expectedW && height == expectedH && !expectedFromFrames) return
        if (width != expectedW || height != expectedH) expectedAt = now
        expectedW = width
        expectedH = height
        expectedFromFrames = false
        check(now)
    }

    fun frame(width: Int, height: Int, now: Long) {
        decodedW = width
        decodedH = height
        if (firstFrameAt < 0) firstFrameAt = now
        lastFrameAt = now
        waitingSince = -1L
        if (expectedAt < 0 || (expectedFromFrames && (width != expectedW || height != expectedH))) {
            expectedW = width
            expectedH = height
            expectedFromFrames = true
            expectedAt = now
        }
        check(now)
    }

    fun resumed(now: Long) {
        if (stable) waitingSince = now
    }

    private fun quietSince() = if (firstFrameAt > expectedAt) firstFrameAt else expectedAt

    fun check(now: Long) {
        if (stable) return
        if (firstFrameAt >= 0 && now - firstFrameAt >= CAP) {
            stable = true
            settledByCap = true
            return
        }
        if (expectedAt < 0 || firstFrameAt < 0) return
        if (kotlin.math.abs(expectedW - decodedW) > SLACK || kotlin.math.abs(expectedH - decodedH) > SLACK) return
        if (now - quietSince() < QUIET) return
        stable = true
    }

    /** Milliseconds until the outcome can change without an event, or -1. */
    fun nextCheck(now: Long): Long {
        val candidates = ArrayList<Long>()
        if (!stable) {
            if (expectedAt >= 0) candidates.add(quietSince() + QUIET)
            if (firstFrameAt >= 0) candidates.add(firstFrameAt + CAP)
            candidates.add((if (lastFrameAt >= 0) lastFrameAt else openedAt) + SLOW_AFTER)
        }
        if (waitingSince >= 0) {
            candidates.add(waitingSince + RESUME_GRACE)
            candidates.add(waitingSince + SLOW_AFTER)
        }
        val next = candidates.filter { it > now }.minOrNull() ?: return -1
        return next - now + 1
    }
}
