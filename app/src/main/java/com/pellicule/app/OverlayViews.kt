package com.pellicule.app

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Shader
import android.util.AttributeSet
import android.view.View
import android.view.animation.DecelerateInterpolator
import android.view.animation.LinearInterpolator
import java.util.Random
import kotlin.math.min

/** Assombrit les bords de l'aperçu, avec le même dégradé que celui appliqué à la photo. */
class VignetteView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    var strength = 0f
        set(value) {
            if (field != value) {
                field = value
                invalidate()
            }
        }

    override fun onDraw(canvas: Canvas) {
        Effects.drawVignette(canvas, width.toFloat(), height.toFloat(), strength)
    }
}

/**
 * Flou artistique en direct : flous (mis à jour à chaque trame) masqués autour du point net.
 * Quand on touche l'image, la mise au point « se refait » : l'image se brouille un instant,
 * puis la nouvelle zone devient nette, comme un objectif qui fait le point.
 */
class BlurView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    var mode = Blur.OFF
        set(value) {
            field = value
            if (value == Blur.OFF) layers = null
            invalidate()
        }

    var layers: BlurLayers? = null
        set(value) {
            field = value
            invalidate()
        }

    var filter: ColorFilter? = null
        set(value) {
            field = value
            invalidate()
        }

    /** Point net visé (utilisé pour la photo). */
    var focusX = 0.5f
        private set
    var focusY = 0.5f
        private set

    // Valeurs affichées, qui suivent l'animation de mise au point.
    var drawX = 0.5f
        private set
    var drawY = 0.5f
        private set
    var spread = 1f
        private set
    private var focusAnim: ValueAnimator? = null

    /** Appelé à chaque étape de l'animation (flou calculé par le processeur graphique). */
    var onFrame: (() -> Unit)? = null

    fun setFocus(x: Float, y: Float) {
        val nx = x.coerceIn(0f, 1f)
        val ny = y.coerceIn(0f, 1f)
        focusX = nx
        focusY = ny
        focusAnim?.cancel()
        if (mode == Blur.OFF) {
            drawX = nx
            drawY = ny
            spread = 1f
            onFrame?.invoke()
            return
        }
        val fromX = drawX
        val fromY = drawY
        val move = DecelerateInterpolator(2f)
        val settle = DecelerateInterpolator(1.6f)
        focusAnim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 560
            interpolator = LinearInterpolator()
            addUpdateListener {
                val t = it.animatedValue as Float
                val p = move.getInterpolation(min(1f, t / 0.45f))
                drawX = fromX + (nx - fromX) * p
                drawY = fromY + (ny - fromY) * p
                spread = if (t < 0.3f) {
                    1f - 0.75f * (t / 0.3f)
                } else {
                    0.25f + 0.75f * settle.getInterpolation((t - 0.3f) / 0.7f)
                }
                invalidate()
                onFrame?.invoke()
            }
            start()
        }
    }

    override fun onDraw(canvas: Canvas) {
        val l = layers ?: return
        if (mode == Blur.OFF) return
        Blur.draw(canvas, l, width.toFloat(), height.toFloat(), mode, drawX, drawY, filter, spread = spread)
    }
}

/** Grain de film animé (environ 12 images par seconde) par-dessus l'aperçu. */
class GrainView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    private val tile = BitmapShader(Effects.noise, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT)
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG).also { it.shader = tile }
    private val transform = Matrix()
    private val rnd = Random()

    override fun onDraw(canvas: Canvas) {
        val scale = Effects.grainScale(min(width, height))
        transform.setScale(scale, scale)
        transform.postTranslate(rnd.nextFloat() * 256f * scale, rnd.nextFloat() * 256f * scale)
        tile.setLocalMatrix(transform)
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
        if (isShown) postInvalidateDelayed(80)
    }
}
