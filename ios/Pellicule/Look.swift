import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

enum BlurMode: Int {
    case off = 0
    case radial = 1
    case band = 2
}

/// Tout ce qui définit le rendu d'une image : partagé entre l'aperçu en direct et la photo finale.
struct LookSettings {
    var matrix: ColorMatrix = .identity
    var vignette: CGFloat = 0
    var grain = false
    var blur: BlurMode = .off
    var blurIntensity: CGFloat = Look.defaultBlurIntensity
    /// Point net, en coordonnées 0–1 de l'aperçu (origine en haut à gauche).
    var focus = CGPoint(x: 0.5, y: 0.5)
    /// < 1 resserre la zone nette (animation de mise au point).
    var spread: CGFloat = 1
    /// Format de l'image : largeur / hauteur en portrait (0,75 pour 4:3).
    var aspect: CGFloat = 0.75
}

/// Formats d'image. `ratio` = largeur / hauteur en portrait ; nil = plein écran (format de l'écran).
/// La caméra filme toujours en 4:3 : l'aperçu et la photo en sont recadrés au centre, à l'identique.
struct PhotoFormat {
    let label: String
    let title: String
    let ratio: CGFloat?
}

let FORMATS: [PhotoFormat] = [
    PhotoFormat(label: "4:3", title: "4:3", ratio: 3.0 / 4.0),
    PhotoFormat(label: "16:9", title: "16:9", ratio: 9.0 / 16.0),
    PhotoFormat(label: "Plein", title: "Plein écran", ratio: nil),
    PhotoFormat(label: "1:1", title: "Carré 1:1", ratio: 1),
    PhotoFormat(label: "3:2", title: "3:2 · 35 mm", ratio: 2.0 / 3.0),
]

/**
 Rendu Pellicule avec Core Image : filtre, flou artistique, vignettage, grain.
 Toutes les tailles sont relatives à l'image : l'aperçu et la photo en pleine résolution ont le même rendu.
 */
enum Look {
    /// Intensité du flou par défaut (0 = léger, 1 = fort).
    static let defaultBlurIntensity: CGFloat = 0.35

    /// Espace de travail : sRGB non linéaire, comme sur Android (les matrices de couleur y ont été réglées).
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    static let outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // Distances au point net (en part du petit côté pour le rond, de la hauteur pour la bande) :
    // net jusqu'à [0], flou léger complet à [1], flou marqué complet à [2].
    private static let radialStops: [CGFloat] = [0.26, 0.5, 0.95]
    private static let bandStops: [CGFloat] = [0.12, 0.26, 0.5]

    /// Taille du grain : le petit côté de l'image contient environ 640 « grains ».
    private static let grainCells: CGFloat = 640

    /// Applique le rendu à une image dont l'origine est (0, 0). `grainOffset` est entre 0 et 1.
    static func render(_ input: CIImage, _ s: LookSettings, grainOffset: CGPoint) -> CIImage {
        let extent = input.extent
        var img = s.matrix.apply(to: input)
        if s.blur != .off { img = blur(img, s, extent) }
        if s.vignette > 0.001 { img = vignette(img, extent, s.vignette) }
        if s.grain { img = grain(img, extent, grainOffset) }
        return img.cropped(to: extent)
    }

    /// Recadre au centre au format `aspect` (largeur / hauteur) et ramène l'origine en (0, 0).
    static func crop(_ image: CIImage, aspect: CGFloat) -> CIImage {
        let e = image.extent
        var w = e.width
        var h = e.height
        if w / h > aspect { w = max(1, (h * aspect).rounded()) } else { h = max(1, (w / aspect).rounded()) }
        let x = (e.minX + (e.width - w) / 2).rounded()
        let y = (e.minY + (e.height - h) / 2).rounded()
        return image.cropped(to: CGRect(x: x, y: y, width: w, height: h))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
    }

    // MARK: - Flou artistique

    /// Écart type du flou marqué, en part du petit côté. Interpolation logarithmique :
    /// chaque cran du curseur change le flou dans la même proportion.
    private static func strongSigma(_ intensity: CGFloat) -> CGFloat {
        let t = min(max(intensity, 0), 1)
        return 0.0078 * pow(480.0 / 130.0, t)
    }

    /**
     Flou façon mise au point d'objectif : la zone touchée reste nette, puis l'image devient
     progressivement plus douce en s'en éloignant (flou léger, puis flou plus marqué).
     */
    private static func blur(_ img: CIImage, _ s: LookSettings, _ e: CGRect) -> CIImage {
        let short = min(e.width, e.height)
        let sigma = strongSigma(s.blurIntensity) * short
        let light = gaussian(img, sigma: sigma * 0.38, e)
        let strong = gaussian(img, sigma: sigma, e)
        let stops = s.blur == .radial ? radialStops : bandStops
        let k = s.spread
        var out = blend(light, over: img, mask: mask(s, e, stops[0] * k, stops[1] * k))
        out = blend(strong, over: out, mask: mask(s, e, stops[1] * k, stops[2] * k))
        return out
    }

    private static func gaussian(_ img: CIImage, sigma: CGFloat, _ e: CGRect) -> CIImage {
        img.clampedToExtent().applyingGaussianBlur(sigma: Double(max(0.5, sigma))).cropped(to: e)
    }

    private static func blend(_ top: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        top.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask,
        ])
    }

    /// Masque : noir (net) jusqu'à `start`, blanc (flou) à partir de `end` (distance au point net).
    private static func mask(_ s: LookSettings, _ e: CGRect, _ start: CGFloat, _ end: CGFloat) -> CIImage {
        let w = e.width
        let h = e.height
        let cx = e.minX + s.focus.x * w
        let cy = e.minY + (1 - s.focus.y) * h   // Core Image : origine en bas à gauche.
        if s.blur == .radial {
            let side = min(w, h)
            let outer = max(1, end * side)
            let inner = min(max(0, start * side), outer - 0.5)
            return radial(CIVector(x: cx, y: cy), inner, outer, gray(0), gray(1)).cropped(to: e)
        }
        let outer = max(1, end * h)
        let inner = min(max(0, start * h), outer - 0.5)
        let above = linear(from: cy + inner, to: cy + outer)
        let below = linear(from: cy - inner, to: cy - outer)
        return above.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: below])
            .cropped(to: e)
    }

    // MARK: - Vignette et grain

    private static func vignette(_ img: CIImage, _ e: CGRect, _ strength: CGFloat) -> CIImage {
        // Comme sur Android : transparent jusqu'à 45 % du rayon, moitié de l'opacité à 75 %, opacité pleine au bord.
        let edge = min(max(strength, 0), 1) * 220 / 255
        let c = CIVector(x: e.midX, y: e.midY)
        let r = hypot(e.width, e.height) / 2
        let first = radial(c, 0.45 * r, 0.75 * r, gray(0), gray(edge / 2))
        let second = radial(c, 0.75 * r, r, gray(0), gray(edge / 2))
        let dark = first.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: second])
            .cropped(to: e)
        return blend(CIImage(color: gray(0)).cropped(to: e), over: img, mask: dark)
    }

    /// Tuile de bruit : points noirs ou blancs semi-transparents, pour que la moyenne reste neutre.
    private static let noise: CIImage = {
        let size = 256
        var px = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let a = Int.random(in: 0..<36)
            let v = Bool.random() ? a : 0   // valeurs prémultipliées
            px[i * 4] = UInt8(v)
            px[i * 4 + 1] = UInt8(v)
            px[i * 4 + 2] = UInt8(v)
            px[i * 4 + 3] = UInt8(a)
        }
        return CIImage(bitmapData: Data(px), bytesPerRow: size * 4, size: CGSize(width: size, height: size),
                       format: .RGBA8, colorSpace: outputSpace)
    }()

    private static func grain(_ img: CIImage, _ e: CGRect, _ offset: CGPoint) -> CIImage {
        let scale = max(1, min(e.width, e.height) / grainCells)
        let t = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: e.minX + offset.x * 256 * scale,
                                             y: e.minY + offset.y * 256 * scale))
        let tile = CIFilter.affineTile()
        tile.inputImage = noise
        tile.transform = t
        guard let tiled = tile.outputImage else { return img }
        return tiled.cropped(to: e).composited(over: img)
    }

    // MARK: - Outils

    private static func gray(_ v: CGFloat) -> CIColor {
        CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: workingSpace) ?? CIColor(red: v, green: v, blue: v)
    }

    private static func radial(_ center: CIVector, _ r0: CGFloat, _ r1: CGFloat, _ c0: CIColor, _ c1: CIColor) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center,
            "inputRadius0": r0,
            "inputRadius1": r1,
            "inputColor0": c0,
            "inputColor1": c1,
        ])!.outputImage!
    }

    private static func linear(from y0: CGFloat, to y1: CGFloat) -> CIImage {
        CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: y0),
            "inputPoint1": CIVector(x: 0, y: y1),
            "inputColor0": gray(0),
            "inputColor1": gray(1),
        ])!.outputImage!
    }

    /// Petite scène dessinée, affichée dans les vignettes de filtres avant que la caméra démarre.
    static func sampleScene(width: Int = 120, height: Int = 160) -> CGImage? {
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width)
        let h = CGFloat(height)
        // Repère en haut à gauche, comme le dessin Android.
        c.translateBy(x: 0, y: h)
        c.scaleBy(x: 1, y: -1)
        func color(_ hex: UInt32) -> CGColor {
            CGColor(colorSpace: outputSpace, components: [CGFloat((hex >> 16) & 0xFF) / 255,
                                                          CGFloat((hex >> 8) & 0xFF) / 255,
                                                          CGFloat(hex & 0xFF) / 255, 1])!
        }
        let horizon = h * 0.62
        if let sky = CGGradient(colorsSpace: outputSpace, colors: [color(0x5E93B8), color(0xF3C9A1)] as CFArray, locations: [0, 1]) {
            c.saveGState()
            c.clip(to: CGRect(x: 0, y: 0, width: w, height: horizon))
            c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: horizon), options: [])
            c.restoreGState()
        }
        c.setFillColor(color(0xFFE6B0))
        let sun = w * 0.13
        c.fillEllipse(in: CGRect(x: w * 0.66 - sun, y: horizon - h * 0.16 - sun, width: 2 * sun, height: 2 * sun))

        c.setFillColor(color(0x4F6B57))
        c.move(to: CGPoint(x: 0, y: horizon))
        c.addQuadCurve(to: CGPoint(x: w * 0.5, y: horizon - h * 0.02), control: CGPoint(x: w * 0.25, y: horizon - h * 0.12))
        c.addQuadCurve(to: CGPoint(x: w, y: horizon - h * 0.03), control: CGPoint(x: w * 0.78, y: horizon - h * 0.10))
        c.addLine(to: CGPoint(x: w, y: h))
        c.addLine(to: CGPoint(x: 0, y: h))
        c.closePath()
        c.fillPath()

        c.setFillColor(color(0x2E3A33))
        c.fill(CGRect(x: 0, y: h * 0.8, width: w, height: h * 0.2))
        c.setFillColor(color(0xC9785A))
        c.fill(CGRect(x: w * 0.16, y: h * 0.70, width: w * 0.14, height: h * 0.12))
        return c.makeImage()
    }
}
