// Dessine l'icône 1024 × 1024 (même dessin que l'icône Android) : swift tools/make_icon.swift <sortie.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, 1])!
}

// Le dessin Android fait 108 unités, dont les 72 centrales sont visibles : on garde ce cadrage.
let k = Double(size) / 72
func p(_ v: Double) -> Double { Double(size) / 2 + (v - 54) * k }
func disc(_ x: Double, _ y: Double, _ r: Double, _ hex: UInt32) {
    ctx.setFillColor(color(hex))
    // Repère CoreGraphics : origine en bas à gauche.
    ctx.fillEllipse(in: CGRect(x: p(x) - r * k, y: Double(size) - p(y) - r * k, width: 2 * r * k, height: 2 * r * k))
}

ctx.setFillColor(color(0x2A231E))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
disc(54, 54, 27, 0xF4EFE7)
disc(54, 54, 20, 0x1D1B19)
disc(54, 54, 12, 0xE8C07A)
disc(48.5, 49, 3.5, 0xFFF8E8)

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
