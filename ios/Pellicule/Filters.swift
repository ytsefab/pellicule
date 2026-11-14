import CoreImage

/**
 Matrice de couleur 4 × 5, au même format que sur Android : chaque ligne donne une couleur de sortie
 (R, G, B, A) à partir de R, G, B, A, plus un décalage sur l'échelle 0–255. Elle est appliquée sur les
 valeurs sRGB (non linéaires), comme sur Android, pour que les filtres aient exactement le même rendu.
 */
struct ColorMatrix {
    var m: [CGFloat]

    static let identity = ColorMatrix(m: [
        1, 0, 0, 0, 0,
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 1, 0,
    ])

    var isIdentity: Bool { m == ColorMatrix.identity.m }

    /// Applique `self`, puis `next`.
    func then(_ next: ColorMatrix) -> ColorMatrix {
        let a = next.m
        let b = m
        var r = [CGFloat](repeating: 0, count: 20)
        for i in 0..<4 {
            for j in 0..<5 {
                var v: CGFloat = 0
                for k in 0..<4 { v += a[i * 5 + k] * b[k * 5 + j] }
                if j == 4 { v += a[i * 5 + 4] }
                r[i * 5 + j] = v
            }
        }
        return ColorMatrix(m: r)
    }

    func apply(to image: CIImage) -> CIImage {
        if isIdentity { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: m[3]),
            "inputGVector": CIVector(x: m[5], y: m[6], z: m[7], w: m[8]),
            "inputBVector": CIVector(x: m[10], y: m[11], z: m[12], w: m[13]),
            "inputAVector": CIVector(x: m[15], y: m[16], z: m[17], w: m[18]),
            "inputBiasVector": CIVector(x: m[4] / 255, y: m[9] / 255, z: m[14] / 255, w: m[19] / 255),
        ]).applyingFilter("CIColorClamp")
    }
}

/// Un filtre = une matrice de couleur + un vignettage intégré optionnel.
struct Filter {
    let name: String
    let matrix: ColorMatrix
    var vignette: CGFloat = 0
}

/// Petites briques de base, combinées avec `chain`. Valeurs sur l'échelle 0–255.
private enum Ops {
    static func saturation(_ s: CGFloat) -> ColorMatrix {
        let inv = 1 - s
        let r = 0.213 * inv
        let g = 0.715 * inv
        let b = 0.072 * inv
        return ColorMatrix(m: [
            r + s, g, b, 0, 0,
            r, g + s, b, 0, 0,
            r, g, b + s, 0, 0,
            0, 0, 0, 1, 0,
        ])
    }

    static func contrast(_ c: CGFloat, _ brightness: CGFloat = 0) -> ColorMatrix {
        let t = (1 - c) * 128 + brightness
        return ColorMatrix(m: [
            c, 0, 0, 0, t,
            0, c, 0, 0, t,
            0, 0, c, 0, t,
            0, 0, 0, 1, 0,
        ])
    }

    static func channels(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat,
                         _ dr: CGFloat = 0, _ dg: CGFloat = 0, _ db: CGFloat = 0) -> ColorMatrix {
        ColorMatrix(m: [
            r, 0, 0, 0, dr,
            0, g, 0, 0, dg,
            0, 0, b, 0, db,
            0, 0, 0, 1, 0,
        ])
    }

    /// t > 0 réchauffe, t < 0 refroidit.
    static func warmth(_ t: CGFloat) -> ColorMatrix { channels(1 + t, 1 + t * 0.3, 1 - t) }

    /// Remonte les noirs (rendu « délavé » façon tirage argentique).
    static func fade(_ lift: CGFloat) -> ColorMatrix {
        let k = (255 - lift) / 255
        return channels(k, k, k, lift, lift, lift)
    }

    static func mono(_ rw: CGFloat = 0.30, _ gw: CGFloat = 0.59, _ bw: CGFloat = 0.11) -> ColorMatrix {
        ColorMatrix(m: [
            rw, gw, bw, 0, 0,
            rw, gw, bw, 0, 0,
            rw, gw, bw, 0, 0,
            0, 0, 0, 1, 0,
        ])
    }

    static func sepia() -> ColorMatrix {
        ColorMatrix(m: [
            0.393, 0.769, 0.189, 0, 0,
            0.349, 0.686, 0.168, 0, 0,
            0.272, 0.534, 0.131, 0, 0,
            0, 0, 0, 1, 0,
        ])
    }

    static func instant() -> ColorMatrix {
        ColorMatrix(m: [
            1.438, -0.062, -0.062, 0, -7.65,
            -0.122, 1.378, -0.122, 0, 12.75,
            -0.016, -0.016, 1.483, 0, -5.1,
            0, 0, 0, 1, 0,
        ])
    }

    /// Applique les étapes dans l'ordre donné.
    static func chain(_ steps: ColorMatrix...) -> ColorMatrix {
        steps.reduce(ColorMatrix.identity) { $0.then($1) }
    }
}

let FILTERS: [Filter] = {
    typealias O = Ops
    return [
        Filter(name: "Naturel", matrix: .identity),
        Filter(name: "Doré", matrix: O.chain(O.warmth(0.12), O.saturation(1.15), O.contrast(1.06))),
        Filter(name: "Brume", matrix: O.chain(O.saturation(0.7), O.fade(38), O.channels(1.03, 0.98, 1, 6, 0, 4))),
        Filter(name: "Pêche", matrix: O.chain(O.warmth(0.08), O.channels(1.04, 0.97, 0.98, 10, 4, 6), O.saturation(1.05))),
        Filter(name: "Givre", matrix: O.chain(O.warmth(-0.12), O.saturation(0.85), O.contrast(1.05, 6))),
        Filter(name: "Menthe", matrix: O.chain(O.channels(0.92, 1.05, 1, 0, 8, 6), O.saturation(0.9), O.fade(18))),
        Filter(name: "Éclat", matrix: O.chain(O.saturation(1.45), O.contrast(1.18))),
        Filter(name: "Lomo", matrix: O.chain(O.saturation(1.3), O.contrast(1.28), O.channels(1.05, 1, 0.92)), vignette: 0.8),
        Filter(name: "Cinéma", matrix: O.chain(O.channels(1.08, 0.98, 0.9, 0, 2, 18), O.contrast(1.12), O.saturation(0.9))),
        Filter(name: "Rétro 70", matrix: O.chain(O.warmth(0.1), O.saturation(0.8), O.fade(30), O.channels(1, 0.95, 0.88, 8, 4, 0))),
        Filter(name: "Lavande", matrix: O.chain(O.saturation(0.75), O.channels(1.02, 0.94, 1.06, 8, 0, 14), O.fade(22))),
        Filter(name: "Nuit", matrix: O.chain(O.channels(0.85, 0.9, 1.1, 0, 0, 10), O.contrast(1.15, -10), O.saturation(0.9)), vignette: 0.6),
        Filter(name: "Instant", matrix: O.chain(O.instant(), O.saturation(0.9), O.fade(12))),
        Filter(name: "Sépia", matrix: O.chain(O.sepia(), O.fade(14))),
        Filter(name: "Cyano", matrix: O.chain(O.mono(), O.channels(0.75, 0.92, 1.12, 0, 6, 20))),
        Filter(name: "Argent", matrix: O.chain(O.mono(), O.fade(28), O.contrast(0.96))),
        Filter(name: "Charbon", matrix: O.chain(O.mono(0.35, 0.55, 0.10), O.contrast(1.4)), vignette: 0.5),
    ]
}()
