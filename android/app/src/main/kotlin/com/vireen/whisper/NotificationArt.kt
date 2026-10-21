package com.vireen.whisper

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Build

/** 通知上用的图:对方设备的头像。 */
object NotificationArt {
    private const val BRAND_BLUE = 0xFF2563EB.toInt()

    /**
     * HyperOS 的超级岛把实时更新的短文字放在挖孔右边那一格;别家的状态栏
     * 胶囊挨着挖孔,文字会被挡住(7 月改成只放图标),那里不给短文字。
     */
    fun islandShowsShortText(): Boolean =
        Build.MANUFACTURER.lowercase() in setOf("xiaomi", "redmi", "poco")

    /** 对方设备:蓝色圆底上的手机或电脑。 */
    fun device(platform: String): Bitmap {
        val bitmap = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = BRAND_BLUE
            style = Paint.Style.FILL
        }
        canvas.drawCircle(64f, 64f, 60f, paint)
        paint.apply {
            color = Color.WHITE
            style = Paint.Style.STROKE
            strokeWidth = 8f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }

        when (platform.lowercase()) {
            "android", "ios" -> {
                canvas.drawRoundRect(RectF(43f, 25f, 85f, 103f), 8f, 8f, paint)
                canvas.drawCircle(64f, 91f, 2f, paint)
            }
            "macos", "windows", "linux" -> {
                canvas.drawRoundRect(RectF(27f, 31f, 101f, 82f), 7f, 7f, paint)
                canvas.drawLine(22f, 96f, 106f, 96f, paint)
            }
            else -> {
                paint.apply {
                    style = Paint.Style.FILL
                    textAlign = Paint.Align.CENTER
                    textSize = 54f
                    typeface = Typeface.DEFAULT_BOLD
                }
                canvas.drawText("W", 64f, 83f, paint)
            }
        }
        return bitmap
    }
}
