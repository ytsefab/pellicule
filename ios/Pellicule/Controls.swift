import UIKit

/// Bouton de la barre du haut : icône + libellé, doré quand l'option est active.
final class ToolButton: UIControl {
    private let icon = UIImageView()
    private let label = UILabel()

    var isOn = false {
        didSet { refresh() }
    }

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 24),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        set(symbol: symbol, title: title)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String, title: String) {
        icon.image = UIImage(systemName: symbol)
        label.text = title
        accessibilityLabel = title
        refresh()
    }

    private func refresh() {
        icon.tintColor = isOn ? Palette.accent : Palette.ink
        label.textColor = isOn ? Palette.accent : Palette.inkDim
        accessibilityTraits = isOn ? [.button, .selected] : .button
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.45 : 1 }
    }
}

/// Vignette de filtre dans la bande du bas.
final class FilterChip: UIControl {
    let thumb = UIImageView()
    private let frameView = UIView()
    private let label = UILabel()

    var isChosen = false {
        didSet {
            frameView.layer.borderWidth = isChosen ? 2 : 0
            label.textColor = isChosen ? Palette.accent : Palette.inkDim
            accessibilityTraits = isChosen ? [.button, .selected] : .button
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        frameView.layer.cornerRadius = 11
        frameView.layer.borderColor = Palette.accent.cgColor
        frameView.isUserInteractionEnabled = false
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 8
        thumb.backgroundColor = Palette.surface
        thumb.tintColor = Palette.ink
        label.text = title
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = Palette.inkDim
        label.textAlignment = .center

        for v in [frameView, thumb, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
        }
        addSubview(frameView)
        frameView.addSubview(thumb)
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 68),
            frameView.topAnchor.constraint(equalTo: topAnchor),
            frameView.centerXAnchor.constraint(equalTo: centerXAnchor),
            frameView.widthAnchor.constraint(equalToConstant: 60),
            frameView.heightAnchor.constraint(equalToConstant: 78),
            thumb.topAnchor.constraint(equalTo: frameView.topAnchor, constant: 3),
            thumb.bottomAnchor.constraint(equalTo: frameView.bottomAnchor, constant: -3),
            thumb.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 3),
            thumb.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -3),
            label.topAnchor.constraint(equalTo: frameView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

/// Déclencheur : anneau blanc papier et disque plein, qui s'enfonce au toucher.
final class ShutterButton: UIControl {
    private let ring = CAShapeLayer()
    private let disc = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = Palette.ink.cgColor
        ring.lineWidth = 4
        disc.fillColor = Palette.ink.cgColor
        layer.addSublayer(ring)
        layer.addSublayer(disc)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Prendre la photo"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        disc.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).cgPath
        disc.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 8, dy: 8)).cgPath
    }

    /// Pendant le compte à rebours, le disque devient doré (toucher = annuler).
    var isArmed = false {
        didSet { disc.fillColor = (isArmed ? Palette.accent : Palette.ink).cgColor }
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: isHighlighted ? 0.09 : 0.14, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
            }
        }
    }
}

/// Bouton rond (miniature de la dernière photo, changement de caméra).
final class RoundButton: UIControl {
    let imageView = UIImageView()

    init(symbol: String, label: String, rounded: Bool) {
        super.init(frame: .zero)
        backgroundColor = Palette.surface
        layer.cornerRadius = rounded ? 26 : 12
        layer.borderWidth = 1.5
        layer.borderColor = Palette.ink.withAlphaComponent(0.35).cgColor
        clipsToBounds = true
        imageView.image = UIImage(systemName: symbol)
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        imageView.tintColor = Palette.ink
        imageView.contentMode = .center
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: 52),
            heightAnchor.constraint(equalToConstant: 52),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = label
    }

    required init?(coder: NSCoder) { fatalError() }

    func showPhoto(_ image: UIImage) {
        imageView.image = image
        imageView.contentMode = .scaleAspectFill
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

/// Vue dont le calque est une surface Metal : l'aperçu filtré y est dessiné directement.
final class PreviewView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        metalLayer.device = Renderer.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.colorspace = Look.outputSpace
        backgroundColor = Palette.surface
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 2 pixels par point suffisent pour un aperçu et laissent de la marge au processeur graphique.
        let scale: CGFloat = 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }
}

/// Fondu vers le noir, sous la bande de filtres et le déclencheur.
final class ScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let g = layer as! CAGradientLayer
        g.colors = [Palette.bg.withAlphaComponent(0).cgColor, Palette.bg.withAlphaComponent(0.7).cgColor, Palette.bg.cgColor]
        g.locations = [0, 0.35, 1]
    }

    required init?(coder: NSCoder) { fatalError() }
}
