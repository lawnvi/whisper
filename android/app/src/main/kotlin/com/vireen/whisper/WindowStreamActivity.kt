package com.vireen.whisper

import android.app.Activity
import android.animation.ValueAnimator
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.text.SpannableString
import android.text.Spanned
import android.text.style.UnderlineSpan
import android.util.TypedValue
import android.view.Choreographer
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.SeekBar
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.min

/**
 * One streamed window as a task of its own: it shows up in recents next to
 * other apps (as "微信 · MacBook"), opens in landscape and fills the screen.
 * The decoder draws straight into this activity's surface; touches and the
 * keyboard go back to Whisper, which sends them to the other device.
 *
 * Gestures: tap clicks; one finger scrolls (with momentum); press and hold
 * then move drags; press and hold right-clicks; two-finger tap right-clicks.
 */
class WindowStreamActivity : Activity(), SurfaceHolder.Callback {
    companion object {
        private const val EXTRA_ID = "id"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_SCALE = "scale"
        private const val EXTRA_LANDSCAPE = "landscape"
        val STEPS = doubleArrayOf(0.5, 0.75, 1.0, 1.25, 1.5)
        private val open = ConcurrentHashMap<Long, WindowStreamActivity>()

        /** Opens (or brings back) the window for decoder [id]. */
        fun start(context: Context, id: Long, title: String, scale: Double, landscape: Boolean) {
            val intent = Intent(context, WindowStreamActivity::class.java)
                // One task per window: the same data finds the same task.
                .setData(Uri.parse("whisper-window://$id"))
                .putExtra(EXTRA_ID, id)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_SCALE, scale)
                .putExtra(EXTRA_LANDSCAPE, landscape)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
            context.startActivity(intent)
        }

        /**
         * The other device's keyboard focus moved into ([typing]) or out of
         * somewhere to type: the soft keyboard follows, unless the user
         * took it out or put it away themselves meanwhile.
         */
        fun textFocus(id: Long, typing: Boolean) {
            // Often known before the window's task is up: kept for it.
            textFocusOf[id] = typing
            open[id]?.let { activity -> activity.runOnUiThread { activity.followTextFocus(typing) } }
        }

        private val textFocusOf = ConcurrentHashMap<Long, Boolean>()

        /** Windows whose sound is muted here, by decoder id. */
        private val mutedOf = ConcurrentHashMap<Long, Boolean>()

        /** The window's sound began playing: its activity offers to mute it. */
        fun soundStarted(id: Long) {
            open[id]?.let { activity ->
                activity.runOnUiThread {
                    if (activity::soundButton.isInitialized) activity.soundButton.visibility = View.VISIBLE
                }
            }
        }

        /** The source's SIZE messages, by window (often before its task is up). */
        private val sizeOf = ConcurrentHashMap<Long, Pair<Int, Int>>()

        /** What to show while the picture settles, set before [start]. */
        private class Placeholder(val picture: ByteArray?, val icon: ByteArray?, val connecting: String)

        private val placeholderOf = ConcurrentHashMap<Long, Placeholder>()

        /** The source said the window's video is now [width]×[height]. */
        fun videoSize(id: Long, width: Int, height: Int) {
            sizeOf[id] = width to height
            open[id]?.let { activity -> activity.runOnUiThread { activity.onSizeMessage(width, height) } }
        }

        /**
         * The window's last picture here (or the source's thumbnail), its app
         * icon, and the words for a long wait, for the placeholder.
         */
        fun placeholder(id: Long, picture: ByteArray?, icon: ByteArray?, connecting: String) {
            val placeholder = Placeholder(picture, icon, connecting)
            placeholderOf[id] = placeholder
            open[id]?.let { activity -> activity.runOnUiThread { activity.showPlaceholder(placeholder) } }
        }

        /**
         * The stream ended on Whisper's side: the window goes away, from
         * recents too (even when Android already destroyed its activity).
         */
        fun finish(context: Context, id: Long) {
            mutedOf.remove(id)
            sizeOf.remove(id)
            placeholderOf.remove(id)
            open.remove(id)?.let { activity ->
                activity.closingFromWhisper = true
                activity.finishAndRemoveTask()
            }
            val uri = Uri.parse("whisper-window://$id")
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return
            for (task in manager.appTasks) {
                val intent = try {
                    task.taskInfo.baseIntent
                } catch (_: IllegalArgumentException) {
                    continue
                }
                if (intent.data == uri) {
                    task.finishAndRemoveTask()
                }
            }
        }
    }

    private var id = -1L

    // ------------------------------------------------------------ settle
    // Until the picture settles: a placeholder (the last picture, else the
    // app icon) and a spinner over black; then it fades out over the video.
    private val settle = WindowStreamSettle(SystemClock.uptimeMillis())
    private lateinit var loading: FrameLayout
    private lateinit var loadingPicture: ImageView
    private lateinit var loadingIcon: ImageView
    private lateinit var loadingText: TextView
    private var connectingText = ""
    private var shownStable = false

    @Volatile
    private var watchingFrames = true
    private val settleCheck = Runnable { settle.check(SystemClock.uptimeMillis()); afterSettle() }
    private lateinit var root: FrameLayout
    private lateinit var video: SurfaceView
    private lateinit var chrome: LinearLayout
    private lateinit var grabber: View
    private lateinit var keyboard: KeyboardSink
    private lateinit var composition: TextView
    private var ruler: View? = null
    private lateinit var soundButton: ImageButton
    private val handler = Handler(Looper.getMainLooper())
    private val hideChrome = Runnable { setChromeVisible(false) }
    private var videoWidth = 16
    private var videoHeight = 10
    private var keyboardShown = false
    private var reported = 0 to 0
    private var textScale = 0.75
    private var closingFromWhisper = false

    private val plugin get() = WindowStreamReceiverPlugin.instance

    private fun dp(value: Float) =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics)

    private fun emit(type: String, args: Map<String, Any> = emptyMap()) {
        plugin?.emitActivity(id, type, args)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        id = intent.getLongExtra(EXTRA_ID, -1)
        val decoder = plugin?.decoder(id)
        if (id < 0 || decoder == null) {
            finishAndRemoveTask()
            return
        }
        open[id] = this
        // Upright on phones unless turned before (tablets on their side).
        requestedOrientation =
            if (intent.getBooleanExtra(EXTRA_LANDSCAPE, false)) {
                ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            } else {
                ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            }
        textScale = intent.getDoubleExtra(EXTRA_SCALE, 0.75)
        @Suppress("DEPRECATION")
        setTaskDescription(ActivityManager.TaskDescription(intent.getStringExtra(EXTRA_TITLE)))
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        buildViews()
        hideSystemBars()
        decoder.videoSize()?.let { (w, h) -> videoWidth = w; videoHeight = h }
        decoder.onFrame = {
            onPicture()
            if (watchingFrames) {
                val size = plugin?.decoder(id)?.videoSize()
                if (size != null) runOnUiThread { onDecodedFrame(size.first, size.second) }
            }
        }
        decoder.onSize = { w, h ->
            runOnUiThread {
                videoWidth = w
                videoHeight = h
                layoutVideo()
            }
        }
        placeholderOf[id]?.let { showPlaceholder(it) }
        sizeOf[id]?.let { (w, h) -> settle.sizeMessage(w, h, SystemClock.uptimeMillis()) }
        if (decoder.videoSize() != null) {
            // Frames already came (opened again from its card, or recreated):
            // it settled before; only a late first new frame shows a spinner.
            settle.alreadySettled()
            settle.resumed(SystemClock.uptimeMillis())
            shownStable = true
            loading.alpha = 0f
            loading.visibility = View.GONE
        }
        afterSettle()
        flashChrome()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        flashChrome()
    }

    override fun onStart() {
        super.onStart()
        emit("shown")
        if (::loading.isInitialized && settle.stable) {
            settle.resumed(SystemClock.uptimeMillis())
            afterSettle()
        }
    }

    override fun onPause() {
        // While still on screen: the picture as it looks here, for this
        // window's card in recents (a phone's recents show apps that way).
        captureFrame()
        super.onPause()
    }

    override fun onStop() {
        super.onStop()
        if (!isFinishing) {
            emit("hidden")
        }
    }

    private fun captureFrame() {
        val w = video.width / 2
        val h = video.height / 2
        if (w <= 0 || h <= 0 || !video.holder.surface.isValid) return
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        try {
            PixelCopy.request(video, bitmap, { result ->
                if (result == PixelCopy.SUCCESS) {
                    val out = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 72, out)
                    emit("snapshot", mapOf("jpeg" to out.toByteArray()))
                }
                bitmap.recycle()
            }, handler)
        } catch (_: IllegalArgumentException) {
            bitmap.recycle()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            hideSystemBars()
            // A text field already had focus over there when this opened:
            // once the window has settled, the keyboard comes up.
            handler.postDelayed({
                if (textFocusOf[id] == true) followTextFocus(true)
            }, 200)
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        plugin?.decoder(id)?.onSize = null
        plugin?.decoder(id)?.onFrame = null
        if (id >= 0) {
            open.remove(id)
            if (isFinishing) textFocusOf.remove(id)
            if (isFinishing && !closingFromWhisper) {
                emit("closed")
            }
        }
        super.onDestroy()
    }

    // ------------------------------------------------------------ surface

    override fun surfaceCreated(holder: SurfaceHolder) {
        plugin?.decoder(id)?.attachSurface(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        plugin?.decoder(id)?.detachSurface()
    }

    // ------------------------------------------------------------ views

    private fun buildViews() {
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        video = SurfaceView(this).apply {
            holder.addCallback(this@WindowStreamActivity)
            setOnTouchListener(StreamGestures())
        }
        root.addView(video, FrameLayout.LayoutParams(1, 1, Gravity.CENTER))
        buildLoading()
        keyboard = KeyboardSink(this)
        root.addView(keyboard, FrameLayout.LayoutParams(1, 1))
        // What the input method is still composing (pinyin, a word being
        // predicted): shown underlined like marked text on the Mac, until
        // it is committed and sent.
        composition = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            val h = dp(14f).toInt()
            val v = dp(7f).toInt()
            setPadding(h, v, h, v)
            background = GradientDrawable().apply {
                cornerRadius = dp(999f)
                setColor(Color.argb(224, 28, 28, 30))
            }
            visibility = View.GONE
        }
        // At the top: landscape keyboards often float over the bottom.
        root.addView(
            composition,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL,
            ).apply { topMargin = dp(12f).toInt() },
        )

        chrome = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            val pad = dp(4f).toInt()
            setPadding(pad * 2, pad, pad * 2, pad)
            background = GradientDrawable().apply {
                cornerRadius = dp(999f)
                setColor(Color.argb(150, 18, 18, 20))
                setStroke(dp(0.6f).toInt(), Color.argb(50, 255, 255, 255))
            }
            elevation = dp(8f)
        }
        chrome.addView(chromeButton(R.drawable.ic_ws_apps, R.string.window_stream_back_to_whisper) {
            startActivity(
                Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        })
        // The window's sound: shown once it plays (soundStarted).
        soundButton = chromeButton(R.drawable.ic_ws_sound, R.string.window_stream_mute) { toggleSound() }
        soundButton.visibility = if (plugin?.hasSound(id) == true) View.VISIBLE else View.GONE
        chrome.addView(soundButton)
        updateSoundButton()
        chrome.addView(chromeButton(R.drawable.ic_ws_text_size, R.string.window_stream_text_size) {
            toggleRuler()
        })
        chrome.addView(chromeButton(R.drawable.ic_ws_keyboard, R.string.window_stream_keyboard) {
            toggleKeyboard()
        })
        chrome.addView(chromeButton(R.drawable.ic_ws_rotate, R.string.window_stream_rotate) {
            val landscape =
                resources.configuration.orientation != android.content.res.Configuration.ORIENTATION_LANDSCAPE
            requestedOrientation =
                if (landscape) {
                    ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                } else {
                    ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
                }
            emit("orientation", mapOf("landscape" to landscape))
        })
        chrome.addView(chromeButton(R.drawable.ic_ws_close, R.string.window_stream_close) {
            finishAndRemoveTask()
        })
        root.addView(
            chrome,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
            ).apply { bottomMargin = dp(14f).toInt() },
        )

        // While the controls are hidden, a small handle shows where they are.
        grabber = View(this).apply {
            background = GradientDrawable().apply {
                cornerRadius = dp(3f)
                setColor(Color.argb(140, 255, 255, 255))
            }
            alpha = 0f
        }
        val grabberHit = FrameLayout(this).apply {
            addView(grabber, FrameLayout.LayoutParams(dp(44f).toInt(), dp(5f).toInt(), Gravity.CENTER))
            setOnClickListener { flashChrome() }
        }
        root.addView(
            grabberHit,
            FrameLayout.LayoutParams(dp(120f).toInt(), dp(28f).toInt(), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL),
        )
        chrome.bringToFront()

        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> layoutVideo() }
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            keyboardShown = insets.isVisible(WindowInsetsCompat.Type.ime())
            if (!keyboardShown) showComposing("")
            insets
        }
        setContentView(root)
    }

    private fun toggleSound() {
        val muted = mutedOf[id] != true
        mutedOf[id] = muted
        plugin?.setAudioMuted(id, muted)
        updateSoundButton()
    }

    private fun updateSoundButton() {
        val muted = mutedOf[id] == true
        soundButton.setImageResource(if (muted) R.drawable.ic_ws_sound_off else R.drawable.ic_ws_sound)
        val label = getString(if (muted) R.string.window_stream_unmute else R.string.window_stream_mute)
        soundButton.contentDescription = label
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            soundButton.tooltipText = label
        }
    }

    private fun buildLoading() {
        loading = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        loadingPicture = ImageView(this).apply {
            scaleType = ImageView.ScaleType.FIT_CENTER
            setColorFilter(Color.argb(89, 0, 0, 0))
            visibility = View.GONE
        }
        loading.addView(loadingPicture, FrameLayout.LayoutParams(-1, -1))
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        loadingIcon = ImageView(this).apply { visibility = View.GONE }
        column.addView(
            loadingIcon,
            LinearLayout.LayoutParams(dp(64f).toInt(), dp(64f).toInt()).apply { bottomMargin = dp(22f).toInt() },
        )
        val spinner = ProgressBar(this).apply {
            isIndeterminate = true
            indeterminateTintList = android.content.res.ColorStateList.valueOf(Color.WHITE)
        }
        column.addView(spinner, LinearLayout.LayoutParams(dp(36f).toInt(), dp(36f).toInt()))
        loadingText = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            gravity = Gravity.CENTER
            visibility = View.GONE
        }
        column.addView(
            loadingText,
            LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(14f).toInt() },
        )
        loading.addView(column, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))
        root.addView(loading, FrameLayout.LayoutParams(-1, -1))
    }

    private fun showPlaceholder(placeholder: Placeholder) {
        if (!::loading.isInitialized) return
        connectingText = placeholder.connecting
        if (settle.stable) return
        val picture = placeholder.picture?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
        if (picture != null) {
            loadingPicture.setImageBitmap(picture)
            loadingPicture.visibility = View.VISIBLE
            return
        }
        val icon = placeholder.icon?.let { BitmapFactory.decodeByteArray(it, 0, it.size) } ?: return
        loadingIcon.setImageBitmap(icon)
        loadingIcon.visibility = View.VISIBLE
    }

    private fun onSizeMessage(width: Int, height: Int) {
        if (!::loading.isInitialized) return
        settle.sizeMessage(width, height, SystemClock.uptimeMillis())
        afterSettle()
    }

    private fun onDecodedFrame(width: Int, height: Int) {
        if (!::loading.isInitialized) return
        settle.frame(width, height, SystemClock.uptimeMillis())
        afterSettle()
    }

    /** After anything the settle rule hears: show, hide, fade, re-check. */
    private fun afterSettle() {
        val now = SystemClock.uptimeMillis()
        watchingFrames = settle.watching
        handler.removeCallbacks(settleCheck)
        val next = settle.nextCheck(now)
        if (next > 0) handler.postDelayed(settleCheck, next)
        val stable = settle.stable
        if (!shownStable && stable) {
            shownStable = true
            // The crossfade: the stage fades away over the live picture.
            val duration = if (ValueAnimator.areAnimatorsEnabled()) 180L else 0L
            loading.animate().cancel()
            loading.animate().alpha(0f).setDuration(duration).withEndAction {
                if (settle.stable && !settle.loading(SystemClock.uptimeMillis())) {
                    loading.visibility = View.GONE
                }
            }.start()
            return
        }
        if (stable) {
            // After a resume: a dim and the spinner over the last picture only
            // while the first new frame is late.
            val stalled = settle.loading(now)
            if (stalled) {
                loading.setBackgroundColor(Color.argb(89, 0, 0, 0))
                loadingPicture.visibility = View.GONE
                loadingIcon.visibility = View.GONE
                loading.visibility = View.VISIBLE
                loading.animate().cancel()
                loading.alpha = 1f
            } else if (loading.visibility == View.VISIBLE && loading.alpha == 1f) {
                loading.animate().alpha(0f).setDuration(
                    if (ValueAnimator.areAnimatorsEnabled()) 180L else 0L,
                ).withEndAction { loading.visibility = View.GONE }.start()
            }
        }
        val slow = settle.slow(now) && connectingText.isNotEmpty()
        loadingText.text = connectingText
        loadingText.visibility = if (slow) View.VISIBLE else View.GONE
    }

    private fun chromeButton(icon: Int, label: Int, onClick: () -> Unit): ImageButton {
        val size = dp(44f).toInt()
        return ImageButton(this).apply {
            setImageResource(icon)
            setColorFilter(Color.WHITE)
            contentDescription = getString(label)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                tooltipText = getString(label)
            }
            val ripple = TypedValue()
            context.theme.resolveAttribute(android.R.attr.selectableItemBackgroundBorderless, ripple, true)
            setBackgroundResource(ripple.resourceId)
            setPadding(dp(11f).toInt(), dp(11f).toInt(), dp(11f).toInt(), dp(11f).toInt())
            layoutParams = LinearLayout.LayoutParams(size, size)
            setOnClickListener {
                it.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                onClick()
                flashChrome()
            }
        }
    }

    private fun hideSystemBars() {
        WindowCompat.getInsetsController(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    /** The picture fits the screen with its own shape, centred. */
    /** The screen's height without the keyboard. */
    private var fullHeight = 0

    private fun layoutVideo() {
        val width = root.width
        val height = root.height
        if (width <= 0 || height <= 0) return
        if (!keyboardShown) fullHeight = height
        // The keyboard neither shrinks nor moves the picture: it covers its
        // bottom, and the window over there is told how much, so it stops
        // above the keys like any app here (its text field just over them).
        val room = if (keyboardShown && fullHeight > height) fullHeight else height
        val scale = min(width.toFloat() / videoWidth, room.toFloat() / videoHeight)
        val params = video.layoutParams as FrameLayout.LayoutParams
        val w = (videoWidth * scale).toInt()
        val h = (videoHeight * scale).toInt()
        val top = (room - h) / 2
        if (params.width != w || params.height != h || params.topMargin != top ||
            params.gravity != (Gravity.TOP or Gravity.CENTER_HORIZONTAL)
        ) {
            params.width = w
            params.height = h
            params.topMargin = top
            params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            video.layoutParams = params
        }
        val covered = if (keyboardShown && h > 0) {
            ((top + h - height).toFloat() / h).coerceIn(0f, 0.8f)
        } else {
            0f
        }
        if (abs(covered - reportedInset) > 0.01f) {
            reportedInset = covered
            handler.removeCallbacks(reportInset)
            handler.postDelayed(reportInset, 60)
        }
        // The other device sizes the window for this screen; not while the
        // keyboard takes half of it.
        if (!keyboardShown) {
            val density = resources.displayMetrics.density
            val viewport = (width / density).toInt() to (height / density).toInt()
            if (viewport != reported) {
                reported = viewport
                handler.removeCallbacks(reportViewport)
                handler.postDelayed(reportViewport, 250)
            }
        }
    }

    private var reportedInset = 0f

    private val reportInset = Runnable {
        emit("keyboard", mapOf("inset" to reportedInset.toDouble()))
    }

    private val reportViewport = Runnable {
        emit("viewport", mapOf("width" to reported.first, "height" to reported.second))
    }

    private fun flashChrome() {
        setChromeVisible(true)
        handler.removeCallbacks(hideChrome)
        handler.postDelayed(hideChrome, 3500)
    }

    private fun setChromeVisible(visible: Boolean) {
        if (!visible && (ruler != null || keyboardShown)) return
        chrome.animate().cancel()
        chrome.animate()
            .alpha(if (visible) 1f else 0f)
            .translationY(if (visible) 0f else dp(80f))
            .setDuration(if (visible) 260 else 200)
            .start()
        chrome.isEnabled = visible
        grabber.animate().alpha(if (visible) 0f else 1f).setDuration(200).start()
    }

    // ------------------------------------------------------------ text size

    private fun toggleRuler() {
        ruler?.let {
            root.removeView(it)
            ruler = null
            return
        }
        val index = STEPS.indices.minByOrNull { abs(STEPS[it] - textScale) } ?: 1
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(18f).toInt(), dp(10f).toInt(), dp(18f).toInt(), dp(10f).toInt())
            background = GradientDrawable().apply {
                cornerRadius = dp(999f)
                setColor(Color.argb(150, 18, 18, 20))
            }
            elevation = dp(8f)
        }
        fun letter(sizeSp: Float) = TextView(this).apply {
            text = "A"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
        }
        panel.addView(letter(13f))
        val seek = SeekBar(this).apply {
            max = STEPS.size - 1
            progress = index
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar, value: Int, fromUser: Boolean) {
                    if (fromUser) bar.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                }

                override fun onStartTrackingTouch(bar: SeekBar) {}

                override fun onStopTrackingTouch(bar: SeekBar) {
                    textScale = STEPS[bar.progress]
                    emit("textScale", mapOf("scale" to textScale))
                }
            })
        }
        panel.addView(seek, LinearLayout.LayoutParams(dp(180f).toInt(), LinearLayout.LayoutParams.WRAP_CONTENT))
        panel.addView(letter(20f))
        root.addView(
            panel,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
            ).apply { bottomMargin = dp(76f).toInt() },
        )
        ruler = panel
    }

    // ------------------------------------------------------------ keyboard

    /** The keyboard is up because focus went to a text field, not by hand. */
    private var keyboardFollowsFocus = false

    private fun toggleKeyboard() {
        keyboardFollowsFocus = false
        setKeyboard(!keyboardShown)
    }

    private fun setKeyboard(show: Boolean) {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        val insets = WindowCompat.getInsetsController(window, keyboard)
        if (show) {
            keyboard.requestFocus()
            // Asked through the window as well: a plain request without a
            // tap first (focus moving on the other device) can be ignored.
            insets.show(WindowInsetsCompat.Type.ime())
            imm.showSoftInput(keyboard, InputMethodManager.SHOW_IMPLICIT)
        } else {
            insets.hide(WindowInsetsCompat.Type.ime())
            imm.hideSoftInputFromWindow(keyboard.windowToken, 0)
        }
    }

    /** Text field focused on the other device: keyboard up; left: down. */
    fun followTextFocus(typing: Boolean) {
        if (typing && !keyboardShown) {
            keyboardFollowsFocus = true
            setKeyboard(true)
        } else if (!typing && keyboardShown && keyboardFollowsFocus) {
            keyboardFollowsFocus = false
            setKeyboard(false)
        }
    }

    private fun showComposing(text: CharSequence) {
        if (text.isEmpty()) {
            composition.visibility = View.GONE
            return
        }
        composition.text = SpannableString(text).apply {
            setSpan(UnderlineSpan(), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        composition.visibility = View.VISIBLE
        composition.bringToFront()
    }

    /** When the last key or text went out, until a picture follows it. */
    private val typedAt = java.util.concurrent.atomic.AtomicLong(0)
    private var typedLoggedAt = 0L

    private fun noteTyped() {
        typedAt.compareAndSet(0, SystemClock.uptimeMillis())
    }

    private val typedSamples = ArrayList<Long>()

    /** Codec thread: the first picture after a key, summed up every 3 s. */
    private fun onPicture() {
        val at = typedAt.getAndSet(0)
        if (at == 0L) return
        val now = SystemClock.uptimeMillis()
        val ms = now - at
        // Over 1 s: the key changed nothing on screen.
        if (ms > 1000) return
        val summary: Pair<Long, Long>
        val count: Int
        synchronized(typedSamples) {
            typedSamples.add(ms)
            if (now - typedLoggedAt < 3000) return
            typedLoggedAt = now
            val sorted = typedSamples.sorted()
            summary = sorted[sorted.size / 2] to sorted.last()
            count = sorted.size
            typedSamples.clear()
        }
        runOnUiThread {
            emit("latency", mapOf("ms" to summary.first, "max" to summary.second, "keys" to count))
        }
    }

    private fun sendKey(macKeyCode: Int) {
        noteTyped()
        emit("input", mapOf("type" to "key", "down" to true, "code" to macKeyCode))
        emit("input", mapOf("type" to "key", "down" to false, "code" to macKeyCode))
    }

    /**
     * The soft keyboard's target. Input methods compose first (pinyin,
     * handwriting); only what they commit is sent, and what they are still
     * composing shows above the keyboard meanwhile.
     */
    private inner class KeyboardSink(context: Context) : View(context) {
        init {
            isFocusable = true
            isFocusableInTouchMode = true
        }

        override fun onCheckIsTextEditor() = true

        override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
            // No suggestions: Latin letters go out as typed instead of
            // waiting in a predicted word; pinyin still composes.
            outAttrs.inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            // Landscape keyboards otherwise take the whole screen.
            outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or
                EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_ACTION_NONE
            return object : BaseInputConnection(this, false) {
                private var composing: CharSequence = ""

                override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                    setComposing("")
                    send(text)
                    return true
                }

                override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
                    setComposing(text ?: "")
                    return true
                }

                // Ending a composition keeps what was composed, as in any
                // text field (closing the keyboard mid-word, say).
                override fun finishComposingText(): Boolean {
                    val kept = composing
                    setComposing("")
                    send(kept)
                    return true
                }

                private fun setComposing(text: CharSequence) {
                    composing = text
                    showComposing(text)
                }

                private fun send(text: CharSequence?) {
                    if (text.isNullOrEmpty()) return
                    noteTyped()
                    if (text.toString() == "\n") sendKey(36)
                    else emit("input", mapOf("type" to "text", "text" to text.toString()))
                }

                override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                    if (composing.isEmpty()) {
                        repeat(maxOf(1, beforeLength)) { sendKey(51) }
                    }
                    return true
                }

                override fun sendKeyEvent(event: KeyEvent): Boolean {
                    if (event.action != KeyEvent.ACTION_DOWN) return true
                    when (event.keyCode) {
                        KeyEvent.KEYCODE_DEL -> sendKey(51)
                        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> sendKey(36)
                        KeyEvent.KEYCODE_TAB -> sendKey(48)
                        KeyEvent.KEYCODE_DPAD_LEFT -> sendKey(123)
                        KeyEvent.KEYCODE_DPAD_RIGHT -> sendKey(124)
                        KeyEvent.KEYCODE_DPAD_DOWN -> sendKey(125)
                        KeyEvent.KEYCODE_DPAD_UP -> sendKey(126)
                        else -> {
                            val char = event.unicodeChar
                            if (char != 0) {
                                emit("input", mapOf("type" to "text", "text" to String(Character.toChars(char))))
                            }
                        }
                    }
                    return true
                }

                override fun performEditorAction(actionCode: Int): Boolean {
                    sendKey(36)
                    return true
                }
            }
        }
    }

    // ------------------------------------------------------------ touch

    private inner class StreamGestures : View.OnTouchListener {
        private val slop = ViewConfiguration.get(this@WindowStreamActivity).scaledTouchSlop
        private var downX = 0f
        private var downY = 0f
        private var lastX = 0f
        private var lastY = 0f
        private var mode = Mode.NONE
        private var twoFinger = false
        private var downAt = 0L
        private var velocity: VelocityTracker? = null
        private var fling: Choreographer.FrameCallback? = null
        private val longPress = Runnable {
            if (mode == Mode.PENDING && !twoFinger) {
                mode = Mode.HELD
                video.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            }
        }

        private fun x(value: Float) = (value / video.width).coerceIn(0f, 1f).toDouble()
        private fun y(value: Float) = (value / video.height).coerceIn(0f, 1f).toDouble()

        private fun pointer(action: String, px: Float, py: Float, button: String = "primary") {
            emit("input", mapOf("type" to "pointer", "action" to action, "x" to x(px), "y" to y(py), "button" to button))
        }

        private fun scroll(phase: String, dx: Float = 0f, dy: Float = 0f) {
            emit(
                "input",
                mapOf(
                    "type" to "scroll", "phase" to phase, "x" to x(downX), "y" to y(downY),
                    "dx" to (dx / video.width).toDouble(), "dy" to (dy / video.height).toDouble(),
                ),
            )
        }

        private fun click(px: Float, py: Float, button: String) {
            pointer("down", px, py, button)
            pointer("up", px, py, button)
        }

        override fun onTouch(view: View, event: MotionEvent): Boolean {
            // Not at the stretched early frames: touches count once the
            // picture has settled.
            if (!settle.stable && event.actionMasked == MotionEvent.ACTION_DOWN) return true
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    stopFling()
                    downX = event.x
                    downY = event.y
                    lastX = event.x
                    lastY = event.y
                    downAt = event.eventTime
                    twoFinger = false
                    mode = Mode.PENDING
                    velocity?.recycle()
                    velocity = VelocityTracker.obtain().also { it.addMovement(event) }
                    handler.postDelayed(longPress, 450)
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    if (mode == Mode.PENDING || mode == Mode.HELD) {
                        twoFinger = true
                        handler.removeCallbacks(longPress)
                    }
                }
                MotionEvent.ACTION_MOVE -> {
                    velocity?.addMovement(event)
                    val moved = hypot(event.x - downX, event.y - downY) > slop
                    when (mode) {
                        Mode.PENDING -> if (moved && !twoFinger) {
                            handler.removeCallbacks(longPress)
                            mode = Mode.SCROLL
                            scroll("began")
                            scroll("changed", event.x - lastX, event.y - lastY)
                        }
                        Mode.HELD -> if (moved) {
                            mode = Mode.DRAG
                            pointer("down", downX, downY)
                            pointer("move", event.x, event.y)
                        }
                        Mode.SCROLL -> scroll("changed", event.x - lastX, event.y - lastY)
                        Mode.DRAG -> pointer("move", event.x, event.y)
                        Mode.NONE -> {}
                    }
                    lastX = event.x
                    lastY = event.y
                }
                MotionEvent.ACTION_UP -> {
                    handler.removeCallbacks(longPress)
                    when {
                        twoFinger && event.eventTime - downAt < 400 -> click(downX, downY, "secondary")
                        mode == Mode.PENDING -> click(downX, downY, "primary")
                        mode == Mode.HELD -> click(downX, downY, "secondary")
                        mode == Mode.DRAG -> pointer("up", event.x, event.y)
                        mode == Mode.SCROLL -> {
                            velocity?.computeCurrentVelocity(1000)
                            startFling(velocity?.xVelocity ?: 0f, velocity?.yVelocity ?: 0f)
                        }
                        else -> {}
                    }
                    if (mode != Mode.SCROLL) mode = Mode.NONE
                    velocity?.recycle()
                    velocity = null
                }
                MotionEvent.ACTION_CANCEL -> {
                    handler.removeCallbacks(longPress)
                    when (mode) {
                        Mode.SCROLL -> scroll("ended")
                        Mode.DRAG -> pointer("up", lastX, lastY)
                        else -> {}
                    }
                    mode = Mode.NONE
                }
            }
            return true
        }

        /** Injected scrolls get no momentum on the other side: make it here. */
        private fun startFling(vx: Float, vy: Float) {
            val minimum = dp(150f)
            if (hypot(vx, vy) < minimum) {
                scroll("ended")
                mode = Mode.NONE
                return
            }
            var speedX = vx
            var speedY = vy
            var last = 0L
            val callback = object : Choreographer.FrameCallback {
                override fun doFrame(frameTimeNanos: Long) {
                    if (last != 0L) {
                        val seconds = (frameTimeNanos - last) / 1_000_000_000f
                        val decay = Math.pow(0.96, (seconds * 60).toDouble()).toFloat()
                        speedX *= decay
                        speedY *= decay
                        scroll("changed", speedX * seconds, speedY * seconds)
                    }
                    last = frameTimeNanos
                    if (hypot(speedX, speedY) < dp(18f)) {
                        fling = null
                        scroll("ended")
                        mode = Mode.NONE
                        return
                    }
                    Choreographer.getInstance().postFrameCallback(this)
                }
            }
            fling = callback
            Choreographer.getInstance().postFrameCallback(callback)
        }

        private fun stopFling() {
            fling?.let {
                Choreographer.getInstance().removeFrameCallback(it)
                fling = null
                scroll("ended")
            }
        }
    }

    private enum class Mode { NONE, PENDING, HELD, SCROLL, DRAG }
}
