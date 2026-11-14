package com.pellicule.app

/**
 * Formats d'image. [ratio] = largeur / hauteur en portrait ; null = plein écran (format de l'écran).
 * La caméra filme toujours en 4:3 : l'aperçu et la photo en sont recadrés au centre, à l'identique.
 */
class PhotoFormat(val label: String, val title: String, val ratio: Float?)

val FORMATS = listOf(
    PhotoFormat("4:3", "4:3", 3f / 4f),
    PhotoFormat("16:9", "16:9", 9f / 16f),
    PhotoFormat("Plein", "Plein écran", null),
    PhotoFormat("1:1", "Carré 1:1", 1f),
    PhotoFormat("3:2", "3:2 · 35 mm", 2f / 3f),
)
