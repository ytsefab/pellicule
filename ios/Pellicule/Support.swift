import CoreMotion
import ImageIO
import UIKit

/// Noir chaud de chambre noire, blanc papier, or de boîte de pellicule.
enum Palette {
    static let bg = UIColor(hex: 0x0F0E0D)
    static let surface = UIColor(hex: 0x1D1B19)
    static let ink = UIColor(hex: 0xF4EFE7)
    static let inkDim = UIColor(hex: 0x9E988F)
    static let accent = UIColor(hex: 0xE8C07A)
    static let flash = UIColor(hex: 0xFFF8EE)
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension UIFont {
    static func serifItalic(_ size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size)
        guard let serif = base.fontDescriptor.withDesign(.serif),
              let italic = serif.withSymbolicTraits(.traitItalic) else { return base }
        return UIFont(descriptor: italic, size: size)
    }

    static func serif(_ size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: serif, size: size)
    }
}

/// Réglages de rendu lus par le fil de l'aperçu pendant que l'interface les modifie.
final class SharedLook {
    private let lock = NSLock()
    private var value = LookSettings()

    func get() -> LookSettings {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ new: LookSettings) {
        lock.lock()
        value = new
        lock.unlock()
    }
}

/// Animation image par image d'une valeur qui n'est pas une propriété de vue.
final class Tween {
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var step: ((CGFloat) -> Void)?

    func run(duration: CFTimeInterval, step: @escaping (CGFloat) -> Void) {
        cancel()
        self.duration = duration
        self.step = step
        start = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        step(0)
    }

    func cancel() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let t = min(1, CGFloat((CACurrentMediaTime() - start) / duration))
        step?(t)
        if t >= 1 { cancel() }
    }
}

/// Courbe « décélération » d'Android : rapide au début, douce à la fin.
func decelerate(_ x: CGFloat, _ factor: CGFloat) -> CGFloat {
    1 - pow(1 - min(max(x, 0), 1), 2 * factor)
}

/**
 Sens dans lequel le téléphone est tenu (l'interface reste en portrait) : sert à redresser
 une photo prise en paysage. Fonctionne même avec le verrouillage de rotation.
 */
final class OrientationTracker {
    private let motion = CMMotionManager()
    private(set) var orientation: CGImagePropertyOrientation = .up

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.2
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            // a = direction de la pesanteur dans le repère du téléphone (y vers le haut de l'écran).
            if abs(a.x) > 0.55, abs(a.x) > abs(a.y) + 0.15 {
                self.orientation = a.x > 0 ? .right : .left
            } else if abs(a.y) > 0.55, abs(a.y) > abs(a.x) + 0.15 {
                self.orientation = a.y > 0 ? .down : .up
            }
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
    }
}
