package com.pellicule.app

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.ComposeShader
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.RadialGradient
import android.graphics.Shader
import android.view.Surface
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Réglages du flou au moment de la prise de vue. Le point net est en coordonnées 0–1 de l'aperçu. */
class BlurSpec(
    val mode: Int,
    val focusX: Float,
    val focusY: Float,
    val surfaceRotation: Int,
    val intensity: Float,
)

/** Deux niveaux de flou : léger (près de la zone nette) et plus marqué (loin). */
class BlurLayers(val light: Bitmap, val strong: Bitmap) {
    fun recycle() {
        light.recycle()
        strong.recycle()
    }
}

/**
 * Flou artistique façon mise au point d'objectif : la zone touchée reste nette, puis l'image
 * devient progressivement plus douce en s'en éloignant (flou léger, puis flou plus marqué).
 *
 * Les flous sont calculés sur une version réduite de l'image dont la taille dépend de l'intensité
 * (plus elle est petite, plus le flou est fort), toujours relative à l'image : l'aperçu et la photo
 * finale ont donc le même rendu, quelle que soit la résolution.
 */
object Blur {
    const val OFF = 0
    const val RADIAL = 1
    const val BAND = 2

    /** Intensité par défaut (0 = léger, 1 = fort). */
    const val DEFAULT_INTENSITY = 0.35f

    // Petit côté de l'image réduite : 480 px = flou très léger, 130 px = flou fort.
    private const val BASE_LIGHTEST = 480f
    private const val BASE_STRONGEST = 130f

    /** Interpolation logarithmique : chaque cran du curseur change le flou dans la même proportion. */
    /** Écart type du flou marqué (et du léger), en part du petit côté : le même rendu partout. */
    fun strongSigmaFraction(intensity: Float): Float = 3.74f / baseSide(intensity)
    fun lightSigmaFraction(intensity: Float): Float = 1.41f / baseSide(intensity)

    private fun baseSide(intensity: Float): Int {
        val t = intensity.coerceIn(0f, 1f)
        return exp(ln(BASE_LIGHTEST) + (ln(BASE_STRONGEST) - ln(BASE_LIGHTEST)) * t).roundToInt()
    }

    // Distances (en part du petit côté pour le rond, de la hauteur pour la bande) :
    // net jusqu'à [0], flou léger complet à [1], flou marqué complet à [2].
    private val RADIAL_STOPS = floatArrayOf(0.26f, 0.5f, 0.95f)
    private val BAND_STOPS = floatArrayOf(0.12f, 0.26f, 0.5f)

    fun stops(mode: Int): FloatArray = if (mode == RADIAL) RADIAL_STOPS else BAND_STOPS

    /**
     * Trame d'analyse caméra -> flous redressés comme l'aperçu (rotation, miroir, cadrage).
     * [ratio] : largeur / hauteur de l'aperçu (portrait).
     */
    fun fromFrame(frame: Bitmap, rotationDegrees: Int, mirror: Boolean, intensity: Float, ratio: Float): BlurLayers {
        val base = baseSide(intensity)
        val sideways = rotationDegrees % 180 != 0
        val uprightW = if (sideways) frame.height else frame.width
        val uprightH = if (sideways) frame.width else frame.height
        var cropW = uprightW
        var cropH = uprightH
        if (uprightW.toFloat() / uprightH > ratio) {
            cropW = max(1, (uprightH * ratio).roundToInt())
        } else {
            cropH = max(1, (uprightW / ratio).roundToInt())
        }
        val srcW = if (sideways) cropH else cropW
        val srcH = if (sideways) cropW else cropH
        val x = (frame.width - srcW) / 2
        val y = (frame.height - srcH) / 2

        // Réduction d'au plus moitié ici (au-delà, le lissage bilinéaire crée des marches d'escalier) ;
        // shrink() termine par moitiés successives.
        val k = min(1f, max(0.5f, base * 2f / min(srcW, srcH)))
        val m = Matrix().apply {
            postScale(k, k)
            if (rotationDegrees != 0) postRotate(rotationDegrees.toFloat())
            if (mirror) postScale(-1f, 1f)
        }
        val upright = Bitmap.createBitmap(frame, x, y, srcW, srcH, m, true)
        val layers = layersFrom(upright, base)
        if (upright !== frame) upright.recycle()
        return layers
    }

    /** Photo déjà filtrée -> flous à la même échelle relative que l'aperçu. */
    fun fromPhoto(photo: Bitmap, intensity: Float): BlurLayers = layersFrom(photo, baseSide(intensity))

    private fun layersFrom(src: Bitmap, baseSide: Int): BlurLayers {
        val base = shrink(src, baseSide)
        // À l'intensité par défaut (base ≈ 300 px) : léger ≈ 0,5 % du petit côté, marqué ≈ 1,2 %.
        // Le flou marqué reste à la même résolution que le léger : pas d'effet « pixelisé » une fois agrandi.
        val light = blurPixels(base, radius = 1, passes = 3)
        if (base !== src) base.recycle()
        val strong = blurPixels(light, radius = 3, passes = 3)
        return BlurLayers(light, strong)
    }

    /**
     * Dessine les deux flous par-dessus l'image nette, masqués autour du point net.
     * [spread] < 1 resserre la zone nette (utilisé pendant l'animation de mise au point).
     * [surfaceRotation] : orientation du téléphone à la prise de vue, pour placer le masque
     * au bon endroit sur une photo prise en paysage.
     */
    fun draw(
        canvas: Canvas,
        layers: BlurLayers,
        w: Float,
        h: Float,
        mode: Int,
        focusX: Float,
        focusY: Float,
        filter: ColorFilter?,
        surfaceRotation: Int = Surface.ROTATION_0,
        spread: Float = 1f,
    ) {
        if (mode == OFF || w <= 0f || h <= 0f) return
        val stops = if (mode == RADIAL) RADIAL_STOPS else BAND_STOPS
        drawLayer(canvas, layers.light, w, h, mode, focusX, focusY, filter, surfaceRotation, stops[0] * spread, stops[1] * spread)
        drawLayer(canvas, layers.strong, w, h, mode, focusX, focusY, filter, surfaceRotation, stops[1] * spread, stops[2] * spread)
    }

    private fun drawLayer(
        canvas: Canvas,
        blurred: Bitmap,
        w: Float,
        h: Float,
        mode: Int,
        fx: Float,
        fy: Float,
        filter: ColorFilter?,
        surfaceRotation: Int,
        start: Float,
        end: Float,
    ) {
        val image = BitmapShader(blurred, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        image.setLocalMatrix(Matrix().apply { setScale(w / blurred.width, h / blurred.height) })
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        paint.shader = ComposeShader(image, mask(mode, w, h, fx, fy, surfaceRotation, start, end), PorterDuff.Mode.DST_IN)
        paint.colorFilter = filter
        canvas.drawRect(0f, 0f, w, h, paint)
    }

    /**
     * Masque : transparent jusqu'à [start], opaque à partir de [end] (distance au point net).
     * Construit dans le repère de l'aperçu (portrait), puis tourné vers celui de la photo.
     */
    fun mask(
        mode: Int,
        w: Float,
        h: Float,
        fx: Float,
        fy: Float,
        surfaceRotation: Int,
        start: Float,
        end: Float,
    ): Shader {
        val sideways = surfaceRotation == Surface.ROTATION_90 || surfaceRotation == Surface.ROTATION_270
        val pw = if (sideways) h else w
        val ph = if (sideways) w else h

        val shader: Shader = if (mode == RADIAL) {
            val s = min(pw, ph)
            val outer = max(1f, end * s)
            val inner = (start * s).coerceIn(0f, outer)
            RadialGradient(
                fx * pw, fy * ph, outer,
                intArrayOf(Color.TRANSPARENT, Color.TRANSPARENT, Color.BLACK),
                floatArrayOf(0f, inner / outer, 1f),
                Shader.TileMode.CLAMP,
            )
        } else {
            val outer = max(1f, end * ph)
            val inner = (start * ph).coerceIn(0f, outer)
            val cy = fy * ph
            val a = (outer - inner) / (2f * outer)
            LinearGradient(
                0f, cy - outer, 0f, cy + outer,
                intArrayOf(Color.BLACK, Color.TRANSPARENT, Color.TRANSPARENT, Color.BLACK),
                floatArrayOf(0f, a, 1f - a, 1f),
                Shader.TileMode.CLAMP,
            )
        }

        val m = Matrix()
        when (surfaceRotation) {
            Surface.ROTATION_90 -> { m.setRotate(-90f); m.postTranslate(0f, pw) }
            Surface.ROTATION_180 -> { m.setRotate(180f); m.postTranslate(pw, ph) }
            Surface.ROTATION_270 -> { m.setRotate(90f); m.postTranslate(ph, 0f) }
        }
        if (!m.isIdentity) shader.setLocalMatrix(m)
        return shader
    }

    /** Réduit par moitiés successives (moyenne propre des pixels), puis à la taille exacte. */
    private fun shrink(src: Bitmap, targetShort: Int): Bitmap {
        var cur = src
        while (min(cur.width, cur.height) / 2 >= targetShort) {
            val next = Bitmap.createScaledBitmap(cur, cur.width / 2, cur.height / 2, true)
            if (cur !== src) cur.recycle()
            cur = next
        }
        val k = targetShort.toFloat() / min(cur.width, cur.height)
        val tw = max(1, (cur.width * k).roundToInt())
        val th = max(1, (cur.height * k).roundToInt())
        if (tw == cur.width && th == cur.height) return cur
        val out = Bitmap.createScaledBitmap(cur, tw, th, true)
        if (cur !== src && cur !== out) cur.recycle()
        return out
    }

    /** Flou de boîte séparable répété (proche d'un flou gaussien). Renvoie une nouvelle image. */
    private fun blurPixels(src: Bitmap, radius: Int, passes: Int): Bitmap {
        val w = src.width
        val h = src.height
        val px = IntArray(w * h)
        src.getPixels(px, 0, w, 0, 0, w, h)
        val tmp = IntArray(w * h)
        repeat(passes) {
            pass(px, tmp, w, h, radius)
            pass(tmp, px, h, w, radius)
        }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    }

    /** Floute chaque ligne de [src] (w × h) et l'écrit transposée dans [dst] (h × w). */
    private fun pass(src: IntArray, dst: IntArray, w: Int, h: Int, r: Int) {
        val div = 2 * r + 1
        val last = w - 1
        for (y in 0 until h) {
            val row = y * w
            var sr = 0
            var sg = 0
            var sb = 0
            for (i in -r..r) {
                val c = src[row + i.coerceIn(0, last)]
                sr += (c shr 16) and 0xFF
                sg += (c shr 8) and 0xFF
                sb += c and 0xFF
            }
            for (x in 0 until w) {
                dst[x * h + y] = (0xFF shl 24) or ((sr / div) shl 16) or ((sg / div) shl 8) or (sb / div)
                val out = src[row + (x - r).coerceIn(0, last)]
                val inc = src[row + (x + r + 1).coerceIn(0, last)]
                sr += ((inc shr 16) and 0xFF) - ((out shr 16) and 0xFF)
                sg += ((inc shr 8) and 0xFF) - ((out shr 8) and 0xFF)
                sb += (inc and 0xFF) - (out and 0xFF)
            }
        }
    }
}
