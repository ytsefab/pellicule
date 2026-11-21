import CoreImage
import ImageIO
import Metal
import QuartzCore

/// Rendu GPU partagé : aperçu en direct, vignettes de filtres et photo finale.
final class Renderer {
    static let shared = Renderer()

    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    let context: CIContext

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        let options: [CIContextOption: Any] = [
            .workingColorSpace: Look.workingSpace,
            .outputColorSpace: Look.outputSpace,
            .cacheIntermediates: false,
            .name: "Pellicule",
        ]
        if let queue {
            context = CIContext(mtlCommandQueue: queue, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    /// Dessine une image (origine en (0, 0), déjà à la taille de la surface) dans un calque Metal.
    func draw(_ image: CIImage, in layer: CAMetalLayer) {
        guard let queue, let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let texture = drawable.texture
        let destination = CIRenderDestination(width: texture.width, height: texture.height,
                                              pixelFormat: texture.pixelFormat, commandBuffer: buffer,
                                              mtlTextureProvider: { texture })
        destination.colorSpace = Look.outputSpace
        _ = try? context.startTask(toRender: image, from: CGRect(x: 0, y: 0, width: texture.width, height: texture.height),
                                   to: destination, at: .zero)
        buffer.present(drawable)
        buffer.commit()
    }

    /// Une vignette par filtre, à partir d'une petite image.
    func filterThumbs(from image: CIImage) -> [CGImage?] {
        FILTERS.map { context.createCGImage($0.matrix.apply(to: image), from: image.extent, format: .RGBA8, colorSpace: Look.outputSpace) }
    }

    /**
     Photo de l'appareil -> photo Pellicule, prête à enregistrer (JPEG) + miniature.
     `orientation` redresse la photo selon la façon dont le téléphone était tenu.
     */
    func renderPhoto(_ data: Data, _ settings: LookSettings, orientation: CGImagePropertyOrientation) -> (jpeg: Data, thumb: CGImage?)? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        var image = Look.crop(source, aspect: settings.aspect)
        image = Look.render(image, settings, grainOffset: CGPoint(x: CGFloat.random(in: 0..<1), y: CGFloat.random(in: 0..<1)))
        image = image.oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: Look.outputSpace, options: [quality: 0.92]) else {
            return nil
        }
        let k = 200 / min(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let thumb = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: Look.outputSpace)
        return (jpeg, thumb)
    }
}
