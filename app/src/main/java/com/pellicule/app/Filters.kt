package com.pellicule.app

import android.graphics.ColorMatrix

/**
 * Un filtre = une matrice de couleur (appliquée en direct par le GPU sur l'aperçu,
 * puis à l'identique sur la photo) + un vignettage intégré optionnel.
 */
class Filter(val name: String, val matrix: ColorMatrix, val vignette: Float = 0f)

private fun cm(vararg v: Float) = ColorMatrix(v)

/** Petites briques de base, combinées avec [chain]. Valeurs sur l'échelle 0–255. */
private object Ops {
    fun saturation(s: Float) = ColorMatrix().apply { setSaturation(s) }

    fun contrast(c: Float, brightness: Float = 0f): ColorMatrix {
        val t = (1f - c) * 128f + brightness
        return cm(
            c, 0f, 0f, 0f, t,
            0f, c, 0f, 0f, t,
            0f, 0f, c, 0f, t,
            0f, 0f, 0f, 1f, 0f,
        )
    }

    fun channels(r: Float, g: Float, b: Float, dr: Float = 0f, dg: Float = 0f, db: Float = 0f) = cm(
        r, 0f, 0f, 0f, dr,
        0f, g, 0f, 0f, dg,
        0f, 0f, b, 0f, db,
        0f, 0f, 0f, 1f, 0f,
    )

    /** t > 0 réchauffe, t < 0 refroidit. */
    fun warmth(t: Float) = channels(1f + t, 1f + t * 0.3f, 1f - t)

    /** Remonte les noirs (rendu « délavé » façon tirage argentique). */
    fun fade(lift: Float): ColorMatrix {
        val k = (255f - lift) / 255f
        return channels(k, k, k, lift, lift, lift)
    }

    fun mono(rw: Float = 0.30f, gw: Float = 0.59f, bw: Float = 0.11f) = cm(
        rw, gw, bw, 0f, 0f,
        rw, gw, bw, 0f, 0f,
        rw, gw, bw, 0f, 0f,
        0f, 0f, 0f, 1f, 0f,
    )

    fun sepia() = cm(
        0.393f, 0.769f, 0.189f, 0f, 0f,
        0.349f, 0.686f, 0.168f, 0f, 0f,
        0.272f, 0.534f, 0.131f, 0f, 0f,
        0f, 0f, 0f, 1f, 0f,
    )

    fun instant() = cm(
        1.438f, -0.062f, -0.062f, 0f, -7.65f,
        -0.122f, 1.378f, -0.122f, 0f, 12.75f,
        -0.016f, -0.016f, 1.483f, 0f, -5.1f,
        0f, 0f, 0f, 1f, 0f,
    )

    /** Applique les étapes dans l'ordre donné. */
    fun chain(vararg steps: ColorMatrix) = ColorMatrix().apply { steps.forEach { postConcat(it) } }
}

val FILTERS: List<Filter> = with(Ops) {
    listOf(
        Filter("Naturel", ColorMatrix()),
        Filter("Doré", chain(warmth(0.12f), saturation(1.15f), contrast(1.06f))),
        Filter("Brume", chain(saturation(0.7f), fade(38f), channels(1.03f, 0.98f, 1f, 6f, 0f, 4f))),
        Filter("Pêche", chain(warmth(0.08f), channels(1.04f, 0.97f, 0.98f, 10f, 4f, 6f), saturation(1.05f))),
        Filter("Givre", chain(warmth(-0.12f), saturation(0.85f), contrast(1.05f, 6f))),
        Filter("Menthe", chain(channels(0.92f, 1.05f, 1f, 0f, 8f, 6f), saturation(0.9f), fade(18f))),
        Filter("Éclat", chain(saturation(1.45f), contrast(1.18f))),
        Filter("Lomo", chain(saturation(1.3f), contrast(1.28f), channels(1.05f, 1f, 0.92f)), vignette = 0.8f),
        Filter("Cinéma", chain(channels(1.08f, 0.98f, 0.9f, 0f, 2f, 18f), contrast(1.12f), saturation(0.9f))),
        Filter("Rétro 70", chain(warmth(0.1f), saturation(0.8f), fade(30f), channels(1f, 0.95f, 0.88f, 8f, 4f, 0f))),
        Filter("Lavande", chain(saturation(0.75f), channels(1.02f, 0.94f, 1.06f, 8f, 0f, 14f), fade(22f))),
        Filter("Nuit", chain(channels(0.85f, 0.9f, 1.1f, 0f, 0f, 10f), contrast(1.15f, -10f), saturation(0.9f)), vignette = 0.6f),
        Filter("Instant", chain(instant(), saturation(0.9f), fade(12f))),
        Filter("Sépia", chain(sepia(), fade(14f))),
        Filter("Cyano", chain(mono(), channels(0.75f, 0.92f, 1.12f, 0f, 6f, 20f))),
        Filter("Argent", chain(mono(), fade(28f), contrast(0.96f))),
        Filter("Charbon", chain(mono(0.35f, 0.55f, 0.10f), contrast(1.4f)), vignette = 0.5f),
    )
}
