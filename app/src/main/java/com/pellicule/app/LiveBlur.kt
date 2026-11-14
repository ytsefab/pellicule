package com.pellicule.app

import android.graphics.BlendMode
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.RenderEffect
import android.graphics.Shader
import android.os.Build
import android.view.Surface
import androidx.annotation.RequiresApi
import kotlin.math.max
import kotlin.math.min

/**
 * Filtre et flou artistique de l'aperçu, entièrement calculés par le processeur graphique
 * (Android 12 et plus) : l'image floue suit la caméra sans retard et sans charger le processeur.
 *
 * Mêmes réglages que [Blur] : zone nette, flou léger puis flou marqué, tailles relatives à l'image.
 */
@RequiresApi(Build.VERSION_CODES.S)
object LiveBlur {

    fun effect(
        w: Float,
        h: Float,
        matrix: ColorMatrix,
        mode: Int,
        focusX: Float,
        focusY: Float,
        intensity: Float,
        spread: Float,
    ): RenderEffect {
        val color = RenderEffect.createColorFilterEffect(ColorMatrixColorFilter(matrix))
        if (mode == Blur.OFF || w <= 0f || h <= 0f) return color

        val short = min(w, h)
        val stops = Blur.stops(mode)
        val light = masked(
            Blur.lightSigmaFraction(intensity) * short,
            Blur.mask(mode, w, h, focusX, focusY, Surface.ROTATION_0, stops[0] * spread, stops[1] * spread),
        )
        val strong = masked(
            Blur.strongSigmaFraction(intensity) * short,
            Blur.mask(mode, w, h, focusX, focusY, Surface.ROTATION_0, stops[1] * spread, stops[2] * spread),
        )
        val sharp = RenderEffect.createOffsetEffect(0f, 0f)
        val withLight = RenderEffect.createBlendModeEffect(sharp, light, BlendMode.SRC_OVER)
        val withStrong = RenderEffect.createBlendModeEffect(withLight, strong, BlendMode.SRC_OVER)
        return RenderEffect.createChainEffect(color, withStrong)
    }

    /** Image floue, gardée seulement là où le masque est opaque (loin du point net). */
    private fun masked(sigma: Float, mask: Shader): RenderEffect {
        // Le « rayon » d'Android est converti en écart type par sigma = 0,57735 × rayon + 0,5.
        val radius = max(0.5f, (sigma - 0.5f) / 0.57735f)
        val blur = RenderEffect.createBlurEffect(radius, radius, Shader.TileMode.CLAMP)
        return RenderEffect.createBlendModeEffect(blur, RenderEffect.createShaderEffect(mask), BlendMode.DST_IN)
    }
}
