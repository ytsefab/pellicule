import CoreImage
import Vision

/**
 Détourage du sujet par l'IA du téléphone (Vision, sur la puce Neural Engine, sans Internet) :
 d'abord les personnes, sinon (iOS 17 et plus) n'importe quel sujet au premier plan — animal, objet…
 */
enum SubjectMask {
    /// Masque du sujet (blanc = sujet) à la taille de `image`, ou nil si aucun sujet n'est trouvé.
    static func compute(for image: CIImage, accurate: Bool) -> CIImage? {
        let e = image.extent
        guard e.width >= 2, e.height >= 2 else { return nil }
        let handler = VNImageRequestHandler(ciImage: image, options: [:])

        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = accurate ? .accurate : .balanced
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        if (try? handler.perform([person])) != nil,
           let buffer = person.results?.first?.pixelBuffer,
           coverage(buffer) > 0.01 {
            return fitted(CIImage(cvPixelBuffer: buffer), to: e)
        }

        if #available(iOS 17.0, macOS 14.0, *) {
            let foreground = VNGenerateForegroundInstanceMaskRequest()
            if (try? handler.perform([foreground])) != nil,
               let observation = foreground.results?.first,
               !observation.allInstances.isEmpty,
               let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) {
                return fitted(CIImage(cvPixelBuffer: buffer), to: e)
            }
        }
        return nil
    }

    /// Part de l'image occupée par le sujet (masque 8 bits).
    private static func coverage(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        for y in stride(from: 0, to: h, by: 2) {
            let line = bytes + y * row
            for x in stride(from: 0, to: w, by: 2) { sum += Int(line[x]) }
        }
        let count = ((h + 1) / 2) * ((w + 1) / 2)
        return count == 0 ? 0 : Double(sum) / Double(count * 255)
    }

    private static func fitted(_ mask: CIImage, to e: CGRect) -> CIImage {
        let m = mask.extent
        return mask.transformed(by: CGAffineTransform(translationX: -m.minX, y: -m.minY)
            .concatenating(CGAffineTransform(scaleX: e.width / m.width, y: e.height / m.height))
            .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
    }
}

/// Calcule le masque du sujet en continu pour l'aperçu, sans jamais bloquer l'image de la caméra.
final class SubjectTracker {
    private let queue = DispatchQueue(label: "pellicule.ai.subject", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var mask: CIImage?

    func latest() -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return mask
    }

    func clear() {
        lock.lock()
        mask = nil
        lock.unlock()
    }

    /// Propose une image de l'aperçu ; ignorée si le calcul précédent n'est pas fini.
    func submit(_ image: CIImage) {
        lock.lock()
        if busy {
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()
        queue.async {
            let result = SubjectMask.compute(for: image, accurate: false)
            self.lock.lock()
            self.mask = result
            self.busy = false
            self.lock.unlock()
        }
    }
}
