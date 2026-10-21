package com.vireen.whisper

import android.animation.TimeInterpolator
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityOptions
import android.app.Application
import android.app.KeyguardManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.TextPaint
import android.text.TextUtils
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 后台灵动岛:Whisper 不在前台时,把要你知道、要你处理的事画在其他应用上面,
 * 状态栏下方正中的一个黑色小胶囊——传输进度、这台手机正被流转;别的设备
 * 请求连接、想浏览文件、送来窗口时,它一到就展开成卡片,按钮直接回答。
 * 同时有两件事时旁边分出一个小圆。点胶囊展开,点外面收回,往上划收起。
 * 回到 Whisper 就收起:应用里自己会显示。
 *
 * 需要"显示在其他应用上层"。系统能把实时更新显示成自己的岛时(Android 16
 * promoted 通知:超级岛、流体云、原子岛)交给系统,不重复画;锁屏和状态栏
 * 被藏起来(全屏视频)时也不画,那时靠通知。窗口只有岛那么大,别处的触摸
 * 照常给下面的应用。
 */
object IslandOverlay {
    enum class Phase { LIVE, WAITING, DONE, FAILED }

    enum class Direction { OUT, IN, BOTH }

    enum class Glyph { SEND, RECEIVE, BOTH, PHONE, COMPUTER, FOLDER, FLOW }

    enum class Role { NEUTRAL, PRIMARY, DECLINE, ACCEPT }

    class Button(val label: String, val role: Role, val run: () -> Unit)

    /**
     * 岛上的一件事。[figure] 是胶囊右边那一小段(百分比、配对码);[progress]
     * 有值时画进度环和进度条;[urgent] 的一来就展开,回答了或过期才走。
     */
    data class Item(
        val id: String,
        val glyph: Glyph,
        val title: String,
        val text: String,
        val figure: String = "",
        val phase: Phase = Phase.LIVE,
        val progress: Float? = null,
        val buttons: List<Button> = emptyList(),
        val urgent: Boolean = false,
        val rank: Int = 0,
        val onOpen: (() -> Unit)? = null,
        val since: Long = SystemClock.elapsedRealtime(),
    )

    private const val TRANSFER = "transfer"
    private const val DONE_LINGERS_MS = 2600L
    private const val FAILED_LINGERS_MS = 6000L

    /** 传输卡片上的"停止":停下这一轮的全部传输。 */
    var onStop: (() -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    private var context: Context? = null
    private var watching = false

    /** 本应用已启动(看得见)的 Activity 数。 */
    private var started = 0
    private val items = LinkedHashMap<String, Item>()
    private val expiries = HashMap<String, Runnable>()

    /** 往上划掉的:这一件不再出现,直到它结束。 */
    private val putAway = HashSet<String>()

    /** 刚来、要展开给人看的那件。 */
    private var focus: String? = null
    private var view: IslandOverlayView? = null

    /** 跟着本应用的 Activity 判断前后台;只需一次。 */
    fun watch(application: Application) {
        context = application.applicationContext
        if (watching) {
            return
        }
        watching = true
        application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                started++
                refresh()
            }

            override fun onActivityStopped(activity: Activity) {
                started = max(0, started - 1)
                refresh()
            }

            override fun onActivityCreated(activity: Activity, state: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    /** 系统自己会把这些显示成岛时(实时更新),这里就不需要。 */
    fun needed(context: Context): Boolean =
        !UnifiedForegroundNotification.supportsLiveUpdates(context)

    fun allowed(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)

    /**
     * 现在放上岛的东西会被看见:在后台、允许、需要、没锁屏。这时请求的通知
     * 就不必再弹横幅(只留在通知栏和锁屏上)。
     */
    fun presents(context: Context): Boolean {
        val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        return started == 0 && allowed(context) && needed(context) && !keyguard.isKeyguardLocked
    }

    fun put(context: Context, item: Item, expiresInMs: Long? = null) {
        this.context = this.context ?: context.applicationContext
        val fresh = !items.containsKey(item.id)
        items[item.id] = item
        expiries.remove(item.id)?.let(main::removeCallbacks)
        if (expiresInMs != null) {
            val expire = Runnable { remove(item.id) }
            expiries[item.id] = expire
            main.postDelayed(expire, expiresInMs)
        }
        if (fresh && item.urgent) {
            focus = item.id
        }
        refresh()
    }

    fun remove(id: String) {
        expiries.remove(id)?.let(main::removeCallbacks)
        putAway.remove(id)
        if (items.remove(id) != null) {
            if (focus == id) {
                focus = null
            }
            refresh()
        }
    }

    // ----------------------------------------------------- transfers

    fun progress(
        context: Context,
        title: String,
        text: String,
        progress: Int,
        permille: Int,
        direction: Direction,
        stopLabel: String,
        openLabel: String,
    ) {
        val percent = progress.coerceIn(0, 100)
        put(
            context,
            Item(
                id = TRANSFER,
                glyph = when (direction) {
                    Direction.IN -> Glyph.RECEIVE
                    Direction.BOTH -> Glyph.BOTH
                    Direction.OUT -> Glyph.SEND
                },
                title = title,
                text = text,
                figure = "$percent%",
                progress = permille.coerceIn(0, 1000) / 1000f,
                buttons = listOf(
                    Button(stopLabel, Role.NEUTRAL) { onStop?.invoke() },
                    Button(openLabel, Role.PRIMARY) { open(context) },
                ),
                rank = 60,
                since = items[TRANSFER]?.since ?: SystemClock.elapsedRealtime(),
            ),
        )
    }

    /** 全都停住了(断线、暂停):进度留着,等它继续。 */
    fun waiting(context: Context, title: String, text: String) {
        val last = items[TRANSFER] ?: return
        put(
            context,
            last.copy(phase = Phase.WAITING, title = title.ifBlank { last.title }, text = text, figure = ""),
        )
    }

    fun finish(context: Context, title: String, text: String, success: Boolean) {
        val last = items[TRANSFER] ?: return
        put(
            context,
            last.copy(
                phase = if (success) Phase.DONE else Phase.FAILED,
                title = title.ifBlank { last.title },
                text = text,
                figure = "",
                progress = if (success) 1f else last.progress,
                buttons = last.buttons.filter { it.role == Role.PRIMARY },
                rank = if (success) 55 else 85,
            ),
            if (success) DONE_LINGERS_MS else FAILED_LINGERS_MS,
        )
    }

    fun clear() = remove(TRANSFER)

    // --------------------------------------------------------- view

    private fun refresh() {
        val context = context ?: return
        val shown = items.values
            .filter { it.id !in putAway }
            .sortedWith(compareByDescending<Item> { it.rank }.thenByDescending { it.since })
        if (shown.isEmpty() || started > 0 || !allowed(context) || !needed(context)) {
            view?.leave()
            return
        }
        val current = view ?: attach(context) ?: return
        val wanted = focus?.takeIf { id -> shown.any { it.id == id } }
        focus = null
        current.show(shown, wanted)
    }

    /**
     * 按钮发出通知上同一个 PendingIntent。从岛上点的是用户本人,允许它把
     * Whisper 带到前台(Android 14 起要明说)。
     */
    fun fire(context: Context, intent: PendingIntent) {
        val options = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ActivityOptions.makeBasic()
                .setPendingIntentBackgroundActivityStartMode(
                    ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
                )
                .toBundle()
        } else {
            null
        }
        try {
            intent.send(context, 0, null, null, null, null, options)
        } catch (_: PendingIntent.CanceledException) {
        }
    }

    internal fun open(context: Context) {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        launch.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP,
        )
        try {
            context.startActivity(launch)
        } catch (_: Exception) {
        }
    }

    /** 往上划:不急的先收起来,要回答的留着。 */
    internal fun putAway(ids: Collection<String>) {
        for (id in ids) {
            if (items[id]?.urgent == false) {
                putAway.add(id)
            }
        }
        refresh()
    }

    private fun attach(context: Context): IslandOverlayView? {
        val manager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val overlay = IslandOverlayView(context, manager) { gone ->
            // 收完了:窗口也拿掉,不留一块看不见的东西在最上面。
            try {
                manager.removeView(gone)
            } catch (_: Exception) {
            }
            if (view === gone) {
                view = null
            }
        }
        val params = WindowManager.LayoutParams(
            1,
            1,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = overlay.windowTop
            setTitle("Whisper island")
        }
        return try {
            manager.addView(overlay, params)
            view = overlay
            overlay
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * 弹簧:阻尼比 [damping],[response] 秒走完一个来回;时间按 [seconds]
 * 换算。和苹果的岛一样,展开时略微冲过头再回来,收起时干脆。
 */
private class Spring(
    private val damping: Float,
    private val response: Float,
    private val seconds: Float,
) : TimeInterpolator {
    override fun getInterpolation(input: Float): Float {
        val t = input * seconds
        val omega = (2 * Math.PI / response).toFloat()
        if (damping >= 1f) {
            return 1f - exp(-omega * t) * (1f + omega * t)
        }
        val decay = damping * omega
        val damped = omega * sqrt(1f - damping * damping)
        return 1f - exp(-decay * t) * (cos(damped * t) + decay / damped * sin(damped * t))
    }
}

/**
 * 岛本身:胶囊、旁边的小圆和展开后的卡片,一个形状里变来变去。和应用内的岛
 * 同一套样子:纯黑,圆环随进度填满,文字白色和六成白。
 */
@SuppressLint("ViewConstructor")
private class IslandOverlayView(
    context: Context,
    private val manager: WindowManager,
    private val onGone: (IslandOverlayView) -> Unit,
) : View(context) {
    companion object {
        private val BLUE = Color.rgb(0x0A, 0x84, 0xFF)
        private val GREEN = Color.rgb(0x30, 0xD1, 0x58)
        private val ORANGE = Color.rgb(0xFF, 0x9F, 0x0A)
        private val RED = Color.rgb(0xFF, 0x45, 0x3A)
        private val INDIGO = Color.rgb(0x5E, 0x5C, 0xE6)
        private val TILE = Color.rgb(0x2C, 0x2C, 0x2E)
        private const val COLLAPSE_AFTER_MS = 6000L
    }

    private val density = resources.displayMetrics.density
    private fun dp(value: Float) = value * density

    private val statusBar: Int = run {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        val height = if (id > 0) resources.getDimensionPixelSize(id) else 0
        if (height > 0) height else dp(24f).toInt()
    }

    /** 阴影的余量:窗口比岛大这么一圈。 */
    private val margin = dp(14f)

    /** 岛的上沿在状态栏下面一点,不和时钟、图标叠在一起。 */
    val windowTop: Int = statusBar + dp(6f).toInt() - margin.toInt()

    private val pillHeight = dp(32f)
    private val glyphSize = dp(22f)
    private val bubbleGap = dp(6f)
    private val cardWidth =
        min(resources.displayMetrics.widthPixels - dp(20f), dp(400f))
    private val cardRadius = dp(32f)

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        setShadowLayer(dp(14f), 0f, dp(4f), Color.argb(70, 0, 0, 0))
    }
    private val rim = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(0.8f)
        color = Color.argb(28, 255, 255, 255)
    }
    private val tile = Paint(Paint.ANTI_ALIAS_FLAG)
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val medium: Typeface =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            Typeface.create(Typeface.DEFAULT, 600, false)
        } else {
            Typeface.DEFAULT_BOLD
        }
    private val figurePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = dp(13f)
        typeface = medium
        fontFeatureSettings = "tnum"
    }
    private val bigFigurePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = dp(17f)
        typeface = medium
        fontFeatureSettings = "tnum"
    }
    private val titlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = dp(16f)
        typeface = medium
    }
    private val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = dp(13f)
    }
    private val buttonPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = dp(15f)
        typeface = medium
        textAlign = Paint.Align.CENTER
    }

    private var items: List<IslandOverlay.Item> = emptyList()
    private var featuredId: String? = null
    private var expanded = false
    private var leaving = false
    private var entered = false
    private var statusBarShown = true
    private var pressed: Int? = null
    private var downX = 0f
    private var downY = 0f

    // 动起来的量:appear 进场,expansion 胶囊→卡片,pill/cardHeight 尺寸,
    // bubble 小圆,fade 换内容,shownProgress 进度。
    private var appear = 0f
    private var expansion = 0f
    private var pillWidth = 0f
    private var cardHeight = 0f
    private var bubble = 0f
    private var fade = 1f
    private var previous: IslandOverlay.Item? = null
    private var shownProgress = 0f
    private var progressOf: String? = null
    private var progressTarget = 0f
    private var progressAt = 0L

    private val animators = HashMap<String, ValueAnimator>()
    private val collapseLater = Runnable { collapse() }

    init {
        visibility = INVISIBLE
        setOnApplyWindowInsetsListener { _, insets ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                statusBarShown = insets.isVisible(WindowInsets.Type.statusBars())
                applyVisibility()
            }
            insets
        }
    }

    private val featured: IslandOverlay.Item?
        get() = items.firstOrNull { it.id == featuredId } ?: items.firstOrNull()

    private val secondary: IslandOverlay.Item?
        get() {
            val main = featured ?: return null
            return items.firstOrNull { it.id != main.id }
        }

    // -------------------------------------------------------- state

    fun show(next: List<IslandOverlay.Item>, focus: String?) {
        val before = featured
        items = next
        val keep = featuredId?.takeIf { id -> next.any { it.id == id } && expanded }
        featuredId = focus ?: keep ?: next.first().id
        val now = featured!!
        contentDescription = "${now.title}, ${now.text}"
        if (leaving) {
            leaving = false
            entered = false
        }
        if (before != null && before.id != now.id) {
            previous = before
            animate("fade", 0f, 1f, Spring(1f, 0.32f, 0.4f), 400) { fade = it }
        }
        moveProgress(now)
        if (!entered) {
            entered = true
            pillWidth = targetPillWidth()
            bubble = if (secondary != null) 1f else 0f
            cardHeight = targetCardHeight()
            sizeWindow()
            animate("appear", 0f, 1f, Spring(0.62f, 0.5f, 0.75f), 750) { appear = it }
        } else {
            if (before?.phase != now.phase && now.phase == IslandOverlay.Phase.DONE) {
                performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            }
            reshape()
        }
        if (focus != null) {
            haptic(strong = true)
            expand(stay = now.urgent)
        } else if (expanded && before != null && next.none { it.id == before.id }) {
            // 回答了、过期了:卡片收回去。
            collapse()
        } else if (expanded && !now.urgent) {
            restartCollapseTimer()
        }
        applyVisibility()
        invalidate()
    }

    /**
     * 同一件事往前走:匀速走到新的位置,用的时间是离上次更新多久——下一次
     * 更新差不多那时到,一段接一段就是连续的,不会每次弹一下停住。换了一件
     * 事、往回退、结束时用弹簧。
     */
    private fun moveProgress(now: IslandOverlay.Item) {
        val target = now.progress ?: 0f
        if (now.id == progressOf && abs(target - progressTarget) < 0.0001f) {
            return
        }
        val at = SystemClock.uptimeMillis()
        if (now.id == progressOf && target > progressTarget && now.phase == IslandOverlay.Phase.LIVE) {
            val gap = (at - progressAt).coerceIn(120L, 800L)
            animate("progress", shownProgress, target, LinearInterpolator(), gap) { shownProgress = it }
        } else {
            animate("progress", shownProgress, target, Spring(1f, 0.5f, 0.5f), 420) { shownProgress = it }
        }
        progressOf = now.id
        progressTarget = target
        progressAt = at
    }

    /** 缩成一个点再消失,然后交给 [onGone]。 */
    fun leave() {
        if (leaving) {
            return
        }
        leaving = true
        removeCallbacks(collapseLater)
        if (visibility != VISIBLE || !entered) {
            onGone(this)
            return
        }
        animate("appear", appear, 0f, Spring(1f, 0.3f, 0.32f), 320, onEnd = {
            if (leaving) {
                visibility = INVISIBLE
                onGone(this)
            }
        }) { appear = it }
    }

    private fun applyVisibility() {
        // 看不见的根视图连同窗口一起藏起,不挡任何触摸。
        visibility = if (statusBarShown && !leaving) VISIBLE else INVISIBLE
    }

    private fun expand(stay: Boolean) {
        removeCallbacks(collapseLater)
        if (!expanded) {
            expanded = true
            cardHeight = targetCardHeight()
            sizeWindow()
            animate("expansion", expansion, 1f, Spring(0.74f, 0.46f, 0.7f), 700, onEnd = ::sizeWindow) {
                expansion = it
            }
        } else {
            reshape()
        }
        if (!stay) {
            restartCollapseTimer()
        }
    }

    private fun collapse() {
        removeCallbacks(collapseLater)
        if (!expanded) {
            return
        }
        expanded = false
        pressed = null
        // 收回到最要紧的那件。
        featuredId = items.firstOrNull()?.id
        animate("expansion", expansion, 0f, Spring(0.9f, 0.38f, 0.5f), 500, onEnd = ::sizeWindow) {
            expansion = it
        }
        reshape()
    }

    private fun restartCollapseTimer() {
        removeCallbacks(collapseLater)
        postDelayed(collapseLater, COLLAPSE_AFTER_MS)
    }

    /** 尺寸跟着内容变:胶囊宽、卡片高、小圆有无。 */
    private fun reshape() {
        animate("pill", pillWidth, targetPillWidth(), Spring(0.8f, 0.4f, 0.55f), 550, onEnd = ::sizeWindow) {
            pillWidth = it
        }
        animate("card", cardHeight, targetCardHeight(), Spring(0.8f, 0.4f, 0.55f), 550, onEnd = ::sizeWindow) {
            cardHeight = it
        }
        val wantBubble = if (secondary != null && !expanded) 1f else 0f
        animate("bubble", bubble, wantBubble, Spring(0.7f, 0.42f, 0.6f), 600, onEnd = ::sizeWindow) {
            bubble = it
        }
        sizeWindow()
    }

    private fun animate(
        key: String,
        from: Float,
        to: Float,
        curve: TimeInterpolator,
        duration: Long,
        onEnd: (() -> Unit)? = null,
        set: (Float) -> Unit,
    ) {
        animators.remove(key)?.let {
            it.removeAllUpdateListeners()
            it.removeAllListeners()
            it.cancel()
        }
        if (abs(from - to) < 0.001f) {
            set(to)
            onEnd?.invoke()
            invalidate()
            return
        }
        val animator = ValueAnimator.ofFloat(0f, 1f).apply {
            this.duration = duration
            interpolator = curve
            addUpdateListener {
                set(from + (to - from) * (it.animatedValue as Float))
                invalidate()
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    if (animators[key] === animation) {
                        animators.remove(key)
                    }
                    onEnd?.invoke()
                }
            })
        }
        animators[key] = animator
        animator.start()
    }

    // ------------------------------------------------------ geometry

    private fun figureWidth(item: IslandOverlay.Item?): Float {
        val figure = item?.figure.orEmpty()
        return if (figure.isEmpty()) 0f else min(figurePaint.measureText(figure), dp(112f))
    }

    private fun targetPillWidth(): Float {
        val item = featured
        val figure = figureWidth(item)
        return if (figure == 0f) {
            pillHeight * 1.7f
        } else {
            dp(6f) + glyphSize + dp(8f) + figure + dp(12f)
        }
    }

    private fun targetCardHeight(): Float {
        val item = featured ?: return dp(120f)
        var height = dp(18f) + dp(46f) + dp(18f)
        if (item.progress != null) {
            height += dp(6f) + dp(18f)
        }
        if (item.buttons.isNotEmpty()) {
            height += dp(44f) + dp(16f)
        } else {
            height -= dp(2f)
        }
        return height
    }

    private val bubbleSize get() = pillHeight

    /** 窗口要盖住岛现在和将要的样子,外加阴影的余量。 */
    private fun sizeWindow() {
        val params = layoutParams as? WindowManager.LayoutParams ?: return
        val compact = max(pillWidth, targetPillWidth()) +
            (if (max(bubble, if (secondary != null && !expanded) 1f else 0f) > 0.01f) bubbleGap + bubbleSize else 0f)
        val wide = expanded || expansion > 0.01f
        val width = if (wide) max(compact, cardWidth) else compact
        val height = if (wide) max(cardHeight, targetCardHeight()) else pillHeight
        val w = (width + margin * 2).toInt()
        val h = (height + margin * 2).toInt()
        if (params.width == w && params.height == h) {
            return
        }
        params.width = w
        params.height = h
        try {
            manager.updateViewLayout(this, params)
        } catch (_: Exception) {
        }
    }

    // --------------------------------------------------------- touch

    private val pillRect = RectF()
    private val bubbleRect = RectF()

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_OUTSIDE -> if (featured?.urgent != true) collapse()
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                removeCallbacks(collapseLater)
                pressed = if (expanded) buttonAt(event.x, event.y) else null
                invalidate()
            }
            MotionEvent.ACTION_MOVE -> {
                if (downY - event.y > dp(24f) && pressed != -2) {
                    pressed = -2
                    if (expanded) {
                        collapse()
                    } else {
                        IslandOverlay.putAway(items.map { it.id })
                    }
                }
            }
            MotionEvent.ACTION_UP -> {
                val swiped = pressed == -2
                val tap = !swiped && abs(event.x - downX) < dp(12f) && abs(event.y - downY) < dp(12f)
                val button = pressed
                pressed = null
                invalidate()
                if (tap && !leaving) {
                    tapped(event.x, event.y, button)
                } else if (expanded && featured?.urgent != true) {
                    restartCollapseTimer()
                }
            }
            MotionEvent.ACTION_CANCEL -> {
                pressed = null
                invalidate()
            }
        }
        return true
    }

    private fun tapped(x: Float, y: Float, button: Int?) {
        val item = featured ?: return
        if (!expanded) {
            if (bubble > 0.5f && bubbleRect.contains(x, y)) {
                featuredId = secondary?.id
            }
            haptic(strong = false)
            expand(stay = featured?.urgent == true)
            return
        }
        if (button != null && button >= 0) {
            haptic(strong = false)
            item.buttons.getOrNull(button)?.run?.invoke()
            if (!item.urgent) {
                collapse()
            }
            return
        }
        (item.onOpen ?: { IslandOverlay.open(context) }).invoke()
    }

    private fun haptic(strong: Boolean) {
        val constant = if (strong && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            HapticFeedbackConstants.CONFIRM
        } else {
            HapticFeedbackConstants.VIRTUAL_KEY
        }
        performHapticFeedback(constant)
    }

    private fun buttonRects(item: IslandOverlay.Item, left: Float, top: Float, width: Float, height: Float): List<RectF> {
        val count = item.buttons.size
        if (count == 0) {
            return emptyList()
        }
        val pad = dp(16f)
        val size = dp(44f)
        val y = top + height - pad - size
        val gap = dp(10f)
        val each = (width - pad * 2 - gap * (count - 1)) / count
        return List(count) { i ->
            val x = left + pad + i * (each + gap)
            RectF(x, y, x + each, y + size)
        }
    }

    private var cardLeft = 0f
    private var cardTop = 0f

    private fun buttonAt(x: Float, y: Float): Int? {
        val item = featured ?: return null
        return buttonRects(item, cardLeft, cardTop, cardWidth, cardHeight)
            .indexOfFirst { it.contains(x, y) }
            .takeIf { it >= 0 }
    }

    // --------------------------------------------------------- paint

    private val box = RectF()
    private val arc = RectF()
    private val path = Path()

    private fun lerp(a: Float, b: Float, t: Float) = a + (b - a) * t

    override fun onDraw(canvas: Canvas) {
        val item = featured ?: return
        if (appear <= 0.01f) {
            return
        }
        val a = appear
        val e = expansion
        val cx = width / 2f
        val top = margin

        // 胶囊和小圆一起居中;卡片居中。
        val bubbleSpace = bubble.coerceIn(0f, 1f) * (bubbleGap + bubbleSize)
        val groupWidth = pillWidth + bubbleSpace
        val pillLeft = cx - groupWidth / 2f
        val grown = lerp(pillHeight, pillWidth, a.coerceIn(0f, 1.15f))
        val compactLeft = pillLeft + (pillWidth - grown) / 2f
        pillRect.set(compactLeft, top, compactLeft + grown, top + pillHeight)
        cardLeft = cx - cardWidth / 2f
        cardTop = top
        box.set(
            lerp(pillRect.left, cardLeft, e),
            top,
            lerp(pillRect.right, cardLeft + cardWidth, e),
            top + lerp(pillHeight, cardHeight, e),
        )
        val radius = lerp(pillHeight / 2f, cardRadius, e.coerceIn(0f, 1f))
        fill.alpha = (255 * a.coerceIn(0f, 1f)).toInt()
        canvas.drawRoundRect(box, radius, radius, fill)
        rim.alpha = (28 * a.coerceIn(0f, 1f)).toInt()
        canvas.drawRoundRect(box, radius, radius, rim)

        // 旁边的小圆:从胶囊右边分出来。
        val b = (bubble * a).coerceIn(0f, 1.1f) * (1f - e).coerceIn(0f, 1f)
        val second = secondary
        if (b > 0.01f && second != null) {
            val size = bubbleSize * b.coerceAtMost(1.05f)
            val left = pillRect.right + bubbleGap * b
            bubbleRect.set(left, top + (pillHeight - size) / 2f, left + size, top + (pillHeight + size) / 2f)
            fill.alpha = (255 * b.coerceIn(0f, 1f)).toInt()
            canvas.drawOval(bubbleRect, fill)
            val g = glyphSize * 0.82f * b.coerceAtMost(1f)
            drawGlyph(
                canvas,
                second,
                bubbleRect.centerX() - g / 2f,
                bubbleRect.centerY() - g / 2f,
                g,
                (255 * b.coerceIn(0f, 1f)).toInt(),
                second.progress ?: 0f,
            )
        } else {
            bubbleRect.setEmpty()
        }

        canvas.save()
        canvas.clipRect(box)
        val shown = ((a - 0.45f) / 0.55f).coerceIn(0f, 1f)
        val compactAlpha = ((1f - e * 3f).coerceIn(0f, 1f) * shown * 255).toInt()
        if (compactAlpha > 2) {
            val old = previous
            if (old != null && fade < 1f) {
                drawCompact(canvas, old, box.left, top, (compactAlpha * (1f - fade)).toInt())
            }
            drawCompact(canvas, item, box.left, top, (compactAlpha * fade.coerceIn(0f, 1f)).toInt())
        }
        val cardAlpha = (((e - 0.4f) / 0.6f).coerceIn(0f, 1f) * 255).toInt()
        if (cardAlpha > 2) {
            // 内容稍晚一点、从略小处浮出来。
            val lift = (1f - cardAlpha / 255f) * dp(8f)
            val scale = 0.96f + 0.04f * (cardAlpha / 255f)
            canvas.save()
            canvas.translate(0f, lift)
            canvas.scale(scale, scale, cx, top)
            drawCard(canvas, item, cardLeft, top, cardAlpha)
            canvas.restore()
        }
        canvas.restore()
    }

    private fun drawCompact(canvas: Canvas, item: IslandOverlay.Item, left: Float, top: Float, alpha: Int) {
        if (alpha <= 2) {
            return
        }
        val y = top + (pillHeight - glyphSize) / 2f
        val figure = item.figure
        val glyphLeft = if (figure.isEmpty()) {
            left + (pillWidth - glyphSize) / 2f
        } else {
            left + dp(6f)
        }
        val fraction = if (item.id == featured?.id) shownProgress else item.progress ?: 0f
        drawGlyph(canvas, item, glyphLeft, y, glyphSize, alpha, fraction)
        if (figure.isNotEmpty()) {
            figurePaint.alpha = alpha
            val room = figureWidth(item)
            val text = TextUtils.ellipsize(figure, figurePaint, room, TextUtils.TruncateAt.END)
            val baseline = top + pillHeight / 2f - (figurePaint.descent() + figurePaint.ascent()) / 2f
            canvas.drawText(text, 0, text.length, glyphLeft + glyphSize + dp(8f), baseline, figurePaint)
        }
    }

    private fun drawCard(canvas: Canvas, item: IslandOverlay.Item, left: Float, top: Float, alpha: Int) {
        val pad = dp(18f)
        val icon = dp(46f)
        drawGlyph(canvas, item, left + pad, top + pad, icon, alpha, shownProgress)

        val figure = if (item.progress != null) item.figure else ""
        bigFigurePaint.alpha = alpha
        val figureWidth = if (figure.isEmpty()) 0f else bigFigurePaint.measureText(figure)
        val textLeft = left + pad + icon + dp(14f)
        val textRight = left + cardWidth - pad - (if (figure.isEmpty()) 0f else figureWidth + dp(10f))
        titlePaint.alpha = alpha
        textPaint.color = Color.WHITE
        textPaint.alpha = (alpha * 150) / 255
        val titleBaseline = top + pad + dp(19f)
        val title = TextUtils.ellipsize(item.title, titlePaint, textRight - textLeft, TextUtils.TruncateAt.MIDDLE)
        canvas.drawText(title, 0, title.length, textLeft, titleBaseline, titlePaint)
        val text = TextUtils.ellipsize(item.text, textPaint, textRight - textLeft, TextUtils.TruncateAt.END)
        canvas.drawText(text, 0, text.length, textLeft, titleBaseline + dp(21f), textPaint)
        if (figure.isNotEmpty()) {
            canvas.drawText(figure, left + cardWidth - pad - figureWidth, titleBaseline + dp(10f), bigFigurePaint)
        }

        val progress = item.progress
        if (progress != null) {
            val barTop = top + pad + icon + dp(16f)
            val barHeight = dp(6f)
            tile.color = Color.WHITE
            tile.alpha = (alpha * 36) / 255
            arc.set(left + pad, barTop, left + cardWidth - pad, barTop + barHeight)
            canvas.drawRoundRect(arc, barHeight / 2f, barHeight / 2f, tile)
            val fraction = when (item.phase) {
                IslandOverlay.Phase.DONE, IslandOverlay.Phase.FAILED -> 1f
                else -> shownProgress.coerceIn(0f, 1f)
            }
            if (fraction > 0f) {
                tile.color = tint(item)
                tile.alpha = alpha
                arc.set(
                    left + pad,
                    barTop,
                    left + pad + max(barHeight, (cardWidth - pad * 2) * fraction),
                    barTop + barHeight,
                )
                canvas.drawRoundRect(arc, barHeight / 2f, barHeight / 2f, tile)
            }
        }

        val rects = buttonRects(item, left, top, cardWidth, cardHeight)
        rects.forEachIndexed { index, rect ->
            val button = item.buttons[index]
            tile.color = when (button.role) {
                IslandOverlay.Role.PRIMARY -> BLUE
                IslandOverlay.Role.ACCEPT -> GREEN
                IslandOverlay.Role.DECLINE -> RED
                IslandOverlay.Role.NEUTRAL -> TILE
            }
            tile.alpha = if (pressed == index) (alpha * 160) / 255 else alpha
            canvas.drawRoundRect(rect, rect.height() / 2f, rect.height() / 2f, tile)
            buttonPaint.alpha = alpha
            val label = TextUtils.ellipsize(button.label, buttonPaint, rect.width() - dp(16f), TextUtils.TruncateAt.END)
            val baseline = rect.centerY() - (buttonPaint.descent() + buttonPaint.ascent()) / 2f
            canvas.drawText(label, 0, label.length, rect.centerX(), baseline, buttonPaint)
        }
    }

    private fun tint(item: IslandOverlay.Item): Int = when (item.phase) {
        IslandOverlay.Phase.LIVE -> when (item.glyph) {
            IslandOverlay.Glyph.FLOW -> INDIGO
            else -> BLUE
        }
        IslandOverlay.Phase.WAITING -> ORANGE
        IslandOverlay.Phase.DONE -> GREEN
        IslandOverlay.Phase.FAILED -> RED
    }

    /**
     * 左边的图形:有进度的是圆环(里面方向箭头、对勾、暂停或叹号);其余是
     * 一个有颜色的圆,里面是设备、文件夹、窗口或投送的线条画。
     */
    private fun drawGlyph(
        canvas: Canvas,
        item: IslandOverlay.Item,
        left: Float,
        top: Float,
        size: Float,
        alpha: Int,
        fraction: Float,
    ) {
        val cx = left + size / 2f
        val cy = top + size / 2f
        val tint = tint(item)
        glyph.alpha = alpha
        if (item.progress != null) {
            val stroke = size * 0.12f
            arc.set(left + stroke / 2f, top + stroke / 2f, left + size - stroke / 2f, top + size - stroke / 2f)
            ring.strokeWidth = stroke
            ring.color = Color.WHITE
            ring.alpha = (alpha * 36) / 255
            canvas.drawArc(arc, 0f, 360f, false, ring)
            val sweep = when (item.phase) {
                IslandOverlay.Phase.DONE, IslandOverlay.Phase.FAILED -> 360f
                else -> 360f * fraction.coerceIn(0f, 1f)
            }
            if (sweep > 0f) {
                ring.color = tint
                ring.alpha = alpha
                canvas.drawArc(arc, -90f, sweep, false, ring)
            }
            glyph.color = if (item.phase == IslandOverlay.Phase.LIVE) Color.WHITE else tint
            glyph.alpha = alpha
            glyph.strokeWidth = size * 0.1f
            val r = size * 0.22f
            path.reset()
            when (item.phase) {
                IslandOverlay.Phase.DONE -> {
                    path.moveTo(cx - r, cy + r * 0.05f)
                    path.lineTo(cx - r * 0.3f, cy + r * 0.7f)
                    path.lineTo(cx + r, cy - r * 0.6f)
                }
                IslandOverlay.Phase.FAILED -> {
                    path.moveTo(cx, cy - r)
                    path.lineTo(cx, cy + r * 0.25f)
                    canvas.drawPath(path, glyph)
                    path.reset()
                    glyph.style = Paint.Style.FILL
                    canvas.drawCircle(cx, cy + r * 0.85f, glyph.strokeWidth * 0.6f, glyph)
                    glyph.style = Paint.Style.STROKE
                }
                IslandOverlay.Phase.WAITING -> {
                    path.moveTo(cx - r * 0.45f, cy - r * 0.8f)
                    path.lineTo(cx - r * 0.45f, cy + r * 0.8f)
                    path.moveTo(cx + r * 0.45f, cy - r * 0.8f)
                    path.lineTo(cx + r * 0.45f, cy + r * 0.8f)
                }
                IslandOverlay.Phase.LIVE -> arrows(item.glyph, cx, cy, r)
            }
            canvas.drawPath(path, glyph)
            return
        }

        tile.color = tint
        tile.alpha = alpha
        canvas.drawCircle(cx, cy, size / 2f, tile)
        glyph.color = Color.WHITE
        glyph.alpha = alpha
        glyph.strokeWidth = size * 0.075f
        val u = size / 24f
        path.reset()
        when (item.glyph) {
            IslandOverlay.Glyph.PHONE -> {
                arc.set(cx - 4.2f * u, cy - 7f * u, cx + 4.2f * u, cy + 7f * u)
                path.addRoundRect(arc, 1.6f * u, 1.6f * u, Path.Direction.CW)
                path.moveTo(cx - 1.2f * u, cy + 4.6f * u)
                path.lineTo(cx + 1.2f * u, cy + 4.6f * u)
            }
            IslandOverlay.Glyph.COMPUTER -> {
                arc.set(cx - 6.5f * u, cy - 5f * u, cx + 6.5f * u, cy + 3.2f * u)
                path.addRoundRect(arc, 1.2f * u, 1.2f * u, Path.Direction.CW)
                path.moveTo(cx - 8f * u, cy + 6f * u)
                path.lineTo(cx + 8f * u, cy + 6f * u)
            }
            IslandOverlay.Glyph.FOLDER -> {
                path.moveTo(cx - 7f * u, cy - 4.5f * u)
                path.lineTo(cx - 2.6f * u, cy - 4.5f * u)
                path.lineTo(cx - 1f * u, cy - 2.8f * u)
                path.lineTo(cx + 7f * u, cy - 2.8f * u)
                path.lineTo(cx + 7f * u, cy + 5.2f * u)
                path.lineTo(cx - 7f * u, cy + 5.2f * u)
                path.close()
            }
            IslandOverlay.Glyph.FLOW -> {
                // 一叠卡片,和应用里流转的图标一样。
                arc.set(cx - 7.5f * u, cy - 1.2f * u, cx + 7.5f * u, cy + 6.2f * u)
                path.addRoundRect(arc, 1.8f * u, 1.8f * u, Path.Direction.CW)
                path.moveTo(cx - 6.1f * u, cy - 3.9f * u)
                path.lineTo(cx + 6.1f * u, cy - 3.9f * u)
                path.moveTo(cx - 4.5f * u, cy - 6.5f * u)
                path.lineTo(cx + 4.5f * u, cy - 6.5f * u)
            }
            else -> arrows(item.glyph, cx, cy, size * 0.22f)
        }
        canvas.drawPath(path, glyph)
    }

    private fun arrows(kind: IslandOverlay.Glyph, cx: Float, cy: Float, r: Float) {
        fun one(x: Float, up: Boolean, scale: Float) {
            val s = if (up) -1f else 1f
            val h = r * scale
            path.moveTo(x, cy - s * h)
            path.lineTo(x, cy + s * h)
            path.moveTo(x - h * 0.62f, cy + s * h * 0.38f)
            path.lineTo(x, cy + s * h)
            path.lineTo(x + h * 0.62f, cy + s * h * 0.38f)
        }
        when (kind) {
            IslandOverlay.Glyph.RECEIVE -> one(cx, up = false, scale = 1f)
            IslandOverlay.Glyph.BOTH -> {
                one(cx - r * 0.45f, up = true, scale = 0.8f)
                one(cx + r * 0.45f, up = false, scale = 0.8f)
            }
            else -> one(cx, up = true, scale = 1f)
        }
    }
}
