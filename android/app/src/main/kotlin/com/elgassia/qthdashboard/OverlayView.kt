package com.elgassia.qthdashboard

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.View
import kotlin.math.cos
import kotlin.math.sin

/**
 * Compact always-on-top compass widget drawn natively (no second Flutter engine).
 *
 * Layout (≈ 172 × 64 dp):
 *   [ compass ]  087°
 *               <info line>
 *
 * All colours arrive as ARGB ints from Dart so the app's single colour palette
 * remains the source of truth; this view never hard-codes semantic colours.
 */
@SuppressLint("ViewConstructor")
class OverlayView(context: Context) : View(context) {

    private val d = resources.displayMetrics.density
    private fun dp(v: Float) = v * d

    // ── Data (set from the main thread, then invalidate) ───────────────────────
    @Volatile var heading = 0f
    @Volatile var headingValid = true
    @Volatile var windRose = false
    @Volatile var secondaryBearing = Float.NaN
    @Volatile var primaryColor = Color.WHITE
    @Volatile var secondaryColor = Color.GRAY
    @Volatile var northColor = Color.RED
    @Volatile var line1 = ""
    @Volatile var line2 = ""
    @Volatile var bgColor = 0xCC000000.toInt()
    @Volatile var textColor = Color.WHITE
    @Volatile var subColor = Color.LTGRAY

    fun applyData() = postInvalidate()

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.LEFT }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(dp(172f).toInt(), dp(64f).toInt())
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()

        // ── Background pill ───────────────────────────────────────────────────
        fill.style = Paint.Style.FILL
        fill.color = bgColor
        canvas.drawRoundRect(RectF(0f, 0f, w, h), dp(10f), dp(10f), fill)

        // ── Compass (left) ────────────────────────────────────────────────────
        val cx = dp(34f)
        val cy = h / 2f
        val r  = dp(24f)

        // Ring
        stroke.color = primaryColor
        stroke.alpha = 90
        stroke.strokeWidth = dp(1.5f)
        canvas.drawCircle(cx, cy, r, stroke)
        stroke.alpha = 255

        if (windRose) {
            // Heading-up frame: fixed cursor at top + rotating red North tick.
            // Heading cursor (fixed, points up)
            drawTriangle(canvas, cx, cy, r, 0f, primaryColor, dp(10f))
            // North tick (red), at screen angle = -heading
            drawTick(canvas, cx, cy, r, -heading, northColor, dp(3f), dp(11f))
            // Secondary marker
            if (!secondaryBearing.isNaN()) {
                drawDot(canvas, cx, cy, r, secondaryBearing - heading, secondaryColor, dp(3f))
            }
        } else {
            // North-up frame: arrow points to the heading direction.
            if (headingValid) {
                drawNeedle(canvas, cx, cy, r, heading, primaryColor)
            }
            // tiny North mark at top
            drawTick(canvas, cx, cy, r, 0f, northColor, dp(2f), dp(6f))
            // secondary (relative) marker dot at its absolute bearing
            if (!secondaryBearing.isNaN()) {
                drawDot(canvas, cx, cy, r, secondaryBearing, secondaryColor, dp(2.5f))
            }
        }

        // ── Numeric heading ───────────────────────────────────────────────────
        val textX = dp(64f)
        text.color = textColor
        text.isFakeBoldText = true
        text.textSize = dp(22f)
        val hStr = if (headingValid) "${Math.round(heading)}°" else "---"
        canvas.drawText(hStr, textX, cy - dp(2f), text)

        // ── Info line ─────────────────────────────────────────────────────────
        text.isFakeBoldText = false
        text.color = subColor
        text.textSize = dp(11f)
        val maxW = w - textX - dp(8f)
        canvas.drawText(ellipsize(line1, maxW), textX, cy + dp(15f), text)
        if (line2.isNotEmpty()) {
            text.textSize = dp(9.5f)
            canvas.drawText(ellipsize(line2, maxW), textX, cy + dp(27f), text)
        }
    }

    // ── Drawing helpers ────────────────────────────────────────────────────────

    private fun pt(cx: Float, cy: Float, r: Float, deg: Float): Pair<Float, Float> {
        val a = Math.toRadians(deg.toDouble())
        return Pair(cx + r * sin(a).toFloat(), cy - r * cos(a).toFloat())
    }

    private fun drawNeedle(c: Canvas, cx: Float, cy: Float, r: Float, deg: Float, color: Int) {
        val (tx, ty) = pt(cx, cy, r * 0.92f, deg)
        val (lx, ly) = pt(cx, cy, r * 0.42f, deg - 140)
        val (rx, ry) = pt(cx, cy, r * 0.42f, deg + 140)
        fill.style = Paint.Style.FILL
        fill.color = color
        val path = Path().apply {
            moveTo(tx, ty); lineTo(lx, ly); lineTo(cx, cy); lineTo(rx, ry); close()
        }
        c.drawPath(path, fill)
    }

    private fun drawTriangle(c: Canvas, cx: Float, cy: Float, r: Float, deg: Float,
                             color: Int, len: Float) {
        val (tx, ty) = pt(cx, cy, r - len, deg)     // tip inward
        val (lx, ly) = pt(cx, cy, r, deg - 6)
        val (rx, ry) = pt(cx, cy, r, deg + 6)
        fill.style = Paint.Style.FILL
        fill.color = color
        val path = Path().apply { moveTo(tx, ty); lineTo(lx, ly); lineTo(rx, ry); close() }
        c.drawPath(path, fill)
    }

    private fun drawTick(c: Canvas, cx: Float, cy: Float, r: Float, deg: Float,
                         color: Int, width: Float, len: Float) {
        val (ox, oy) = pt(cx, cy, r, deg)
        val (ix, iy) = pt(cx, cy, r - len, deg)
        stroke.color = color
        stroke.strokeWidth = width
        stroke.strokeCap = Paint.Cap.ROUND
        c.drawLine(ox, oy, ix, iy, stroke)
    }

    private fun drawDot(c: Canvas, cx: Float, cy: Float, r: Float, deg: Float, color: Int, rad: Float) {
        val (x, y) = pt(cx, cy, r, deg)
        fill.style = Paint.Style.FILL
        fill.color = color
        c.drawCircle(x, y, rad, fill)
    }

    private fun ellipsize(s: String, maxW: Float): String {
        if (text.measureText(s) <= maxW) return s
        var out = s
        while (out.isNotEmpty() && text.measureText("$out…") > maxW) {
            out = out.substring(0, out.length - 1)
        }
        return "$out…"
    }
}
