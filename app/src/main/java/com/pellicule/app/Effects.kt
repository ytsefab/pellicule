package com.pellicule.app

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.Shader
import java.util.Random
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Rendu partagé entre l'aperçu en direct et la photo finale, pour qu'ils se ressemblent. */
object Effects {

    /** Taille du grain : le petit côté de l'image contient environ 640 « grains ». */
    private const val GRAIN_CELLS = 640f

    /** Tuile de bruit : points noirs ou blancs semi-transparents, pour que la moyenne reste neutre. */
    val noise: Bitmap by lazy {
        val size = 256
        val rnd = Random(7)
        val px = IntArray(size * size) {
            val v = if (rnd.nextBoolean()) 255 else 0
            Color.argb(rnd.nextInt(36), v, v, v)
        }
        Bitmap.createBitmap(px, size, size, Bitmap.Config.ARGB_8888)
    }

    fun grainScale(shortSide: Int): Float = (shortSide / GRAIN_CELLS).coerceAtLeast(1f)

    fun drawVignette(canvas: Canvas, w: Float, h: Float, strength: Float) {
        if (strength <= 0.001f || w <= 0f || h <= 0f) return
        val edge = (strength.coerceIn(0f, 1f) * 220f).toInt()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.shader = RadialGradient(
            w / 2f, h / 2f, hypot(w, h) / 2f,
            intArrayOf(Color.TRANSPARENT, Color.TRANSPARENT, Color.argb(edge / 2, 0, 0, 0), Color.argb(edge, 0, 0, 0)),
            floatArrayOf(0f, 0.45f, 0.75f, 1f),
            Shader.TileMode.CLAMP,
        )
        canvas.drawRect(0f, 0f, w, h, paint)
    }

    fun drawGrain(canvas: Canvas, w: Float, h: Float, scale: Float, dx: Float, dy: Float) {
        val tile = BitmapShader(noise, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT)
        tile.setLocalMatrix(Matrix().apply { setScale(scale, scale); postTranslate(dx, dy) })
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        paint.shader = tile
        canvas.drawRect(0f, 0f, w, h, paint)
    }

    /**
     * Oriente la photo, la recadre au format choisi, applique le filtre, le flou, le vignettage et le grain.
     * [shortRatio] : petit côté / grand côté du format (0,75 pour 4:3, 1 pour carré…). Libère [source].
     */
    fun render(
        source: Bitmap,
        rotation: Int,
        mirror: Boolean,
        matrix: ColorMatrix,
        vignette: Float,
        grain: Boolean,
        blur: BlurSpec?,
        shortRatio: Float,
    ): Bitmap {
        val transform = Matrix()
        if (rotation != 0) transform.postRotate(rotation.toFloat())
        if (mirror) transform.postScale(-1f, 1f)

        val oriented = if (transform.isIdentity) {
            source
        } else {
            Bitmap.createBitmap(source, 0, 0, source.width, source.height, transform, true)
                .also { if (it !== source) source.recycle() }
        }

        // Recadrage au centre, dans le sens de la photo (portrait ou paysage).
        val ow = oriented.width
        val oh = oriented.height
        val portrait = ow <= oh
        var shortSide = min(ow, oh)
        var longSide = max(ow, oh)
        val r = shortRatio.coerceIn(0.2f, 1f)
        if (shortSide.toFloat() / longSide > r) {
            shortSide = max(1, (longSide * r).roundToInt())
        } else {
            longSide = max(1, (shortSide / r).roundToInt())
        }
        val cw = if (portrait) shortSide else longSide
        val ch = if (portrait) longSide else shortSide

        val out = Bitmap.createBitmap(cw, ch, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        paint.colorFilter = ColorMatrixColorFilter(matrix)
        canvas.drawBitmap(oriented, -((ow - cw) / 2).toFloat(), -((oh - ch) / 2).toFloat(), paint)
        oriented.recycle()

        val w = out.width.toFloat()
        val h = out.height.toFloat()
        if (blur != null && blur.mode != Blur.OFF) {
            val layers = Blur.fromPhoto(out, blur.intensity)
            Blur.draw(canvas, layers, w, h, blur.mode, blur.focusX, blur.focusY, null, blur.surfaceRotation)
            layers.recycle()
        }
        drawVignette(canvas, w, h, vignette)
        if (grain) {
            val scale = grainScale(min(out.width, out.height))
            val rnd = Random()
            drawGrain(canvas, w, h, scale, rnd.nextFloat() * 256f * scale, rnd.nextFloat() * 256f * scale)
        }
        return out
    }

    /** Petite scène dessinée, affichée dans les vignettes de filtres avant que la caméra démarre. */
    fun sampleScene(w: Int = 96, h: Int = 128): Bitmap {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val wf = w.toFloat()
        val hf = h.toFloat()
        val horizon = hf * 0.62f
        val p = Paint(Paint.ANTI_ALIAS_FLAG)

        p.shader = LinearGradient(0f, 0f, 0f, horizon, 0xFF5E93B8.toInt(), 0xFFF3C9A1.toInt(), Shader.TileMode.CLAMP)
        c.drawRect(0f, 0f, wf, horizon, p)
        p.shader = null

        p.color = 0xFFFFE6B0.toInt()
        c.drawCircle(wf * 0.66f, horizon - hf * 0.16f, wf * 0.13f, p)

        p.color = 0xFF4F6B57.toInt()
        val hills = Path().apply {
            moveTo(0f, horizon)
            quadTo(wf * 0.25f, horizon - hf * 0.12f, wf * 0.5f, horizon - hf * 0.02f)
            quadTo(wf * 0.78f, horizon - hf * 0.10f, wf, horizon - hf * 0.03f)
            lineTo(wf, hf)
            lineTo(0f, hf)
            close()
        }
        c.drawPath(hills, p)

        p.color = 0xFF2E3A33.toInt()
        c.drawRect(0f, hf * 0.8f, wf, hf, p)

        p.color = 0xFFC9785A.toInt()
        c.drawRect(wf * 0.16f, hf * 0.70f, wf * 0.30f, hf * 0.82f, p)
        return bmp
    }
}
