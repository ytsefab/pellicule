import AVFoundation
import AVKit
import UIKit

private enum FlashMode: Int {
    case off = 0
    case on = 1
    case auto = 2

    var title: String { ["Sans flash", "Flash", "Flash auto"][rawValue] }
    var symbol: String { ["bolt.slash.fill", "bolt.fill", "bolt.badge.a.fill"][rawValue] }
    var device: AVCaptureDevice.FlashMode { [AVCaptureDevice.FlashMode.off, .on, .auto][rawValue] }
}

final class CameraViewController: UIViewController, UIGestureRecognizerDelegate {
    private let camera = Camera()
    private let shared = SharedLook()
    private let tracker = OrientationTracker()
    private let defaults = UserDefaults.standard
    private let photoQueue = DispatchQueue(label: "pellicule.photo", qos: .userInitiated)
    private let thumbQueue = DispatchQueue(label: "pellicule.thumbs", qos: .utility)
    private let aiQueue = DispatchQueue(label: "pellicule.ai.scene", qos: .userInitiated)
    private let subjects = SubjectTracker()
    private let frameLock = NSLock()
    private var latestFrame: CIImage?
    private var aiBusy = false

    // Réglages (mémorisés)
    private var current = 0
    private var vignetteOn = false
    private var grainOn = false
    private var timerSeconds = 0
    private var flashMode = FlashMode.off
    private var blurMode = BlurMode.off
    private var blurIntensity = Look.defaultBlurIntensity
    private var format = 0

    // Affichage
    private var focusTarget = CGPoint(x: 0.5, y: 0.5)
    private var drawnFocus = CGPoint(x: 0.5, y: 0.5)
    private var spread: CGFloat = 1
    private var previewAspect: CGFloat = 0.75
    private var shownVignette: CGFloat = 0
    private let focusTween = Tween()
    private let vignetteTween = Tween()
    private var announceToken = 0
    private var didInitialScroll = false

    // Prise de vue
    private var cameraReady = false
    private var cameraStarting = false
    private var busy = false
    private var countdownLeft = 0
    private var countdownTimer: Timer?
    private var lastPhoto: Data?
    private var savedBrightness: CGFloat?
    private var pinchStart: CGFloat = 1
    private var pinched = false

    // Utilisés par le fil de l'aperçu
    private var metalLayer: CAMetalLayer!
    private var grainOffset = CGPoint.zero
    private var grainTime: CFTimeInterval = 0
    private var thumbTime: CFTimeInterval = 0

    // Vues
    private let topBar = UIStackView()
    private let flashButton = ToolButton(symbol: FlashMode.off.symbol, title: FlashMode.off.title)
    private let timerButton = ToolButton(symbol: "timer", title: "Minuteur")
    private let vignetteButton = ToolButton(symbol: "camera.aperture", title: "Vignette")
    private let grainButton = ToolButton(symbol: "aqi.medium", title: "Grain")
    private let blurButton = ToolButton(symbol: "scope", title: "Flou")
    private let formatButton = ToolButton(symbol: "aspectratio", title: "4:3")
    private let topScrim = GradientView(colors: [Palette.bg.withAlphaComponent(0.7), Palette.bg.withAlphaComponent(0)], locations: [0, 1])
    private let previewFrame = UIView()
    private let previewView = PreviewView()
    private let blinkView = UIView()
    private let focusRing = UIView()
    private let titleBox = UIStackView()
    private let titleLabel = UILabel()
    private let indexLabel = UILabel()
    private let countdownLabel = UILabel()
    private let permissionPanel = UIView()
    private let permissionButton = UIButton(type: .system)
    private let bottomPanel = PassThroughView()
    private let blurRow = UIStackView()
    private let blurSlider = UISlider()
    private let filterScroll = UIScrollView()
    private let filterStrip = UIStackView()
    private var chips: [FilterChip] = []
    private let galleryButton = RoundButton(symbol: "photo.on.rectangle",
                                            label: "Voir la dernière photo. Appui long pour partager.", rounded: false)
    private let switchButton = RoundButton(symbol: "arrow.triangle.2.circlepath", label: "Changer de caméra", rounded: true)
    private let shutter = ShutterButton()
    private let screenFlash = UIView()
    private let toastLabel = PaddedLabel()

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    // MARK: - Cycle de vie

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.bg
        restorePrefs()
        buildViews()
        buildFilterStrip()
        setupGestures()
        setupActions()

        metalLayer = previewView.metalLayer
        camera.onFrame = { [weak self] frame in self?.drawFrame(frame) }

        blurSlider.value = Float(blurIntensity)
        selectFilter(current, announce: false)
        updateFlashUi()
        updateTimerUi()
        updateGrainUi()
        updateBlurUi()
        updateFormatUi()
        updateVignette(animated: false)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(subjectAreaChanged), name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)

        // Boutons de volume = déclencheur (iOS 17.2 et plus).
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak self] event in
                if event.phase == .began { self?.onShutter() }
            }
            view.addInteraction(interaction)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        tracker.start()
        checkCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPreviewFrame()
        if !didInitialScroll, filterScroll.bounds.width > 0 {
            didInitialScroll = true
            filterScroll.layoutIfNeeded()
            scrollToChip(animated: false)
        }
    }

    @objc private func appDidEnterBackground() {
        cancelCountdown()
        camera.pause()
        tracker.stop()
    }

    @objc private func appWillEnterForeground() {
        tracker.start()
        if cameraReady { camera.resume() } else { checkCamera() }
    }

    @objc private func subjectAreaChanged() {
        camera.resetFocus()
    }

    // MARK: - Construction de l'écran

    private func buildViews() {
        topBar.axis = .horizontal
        topBar.distribution = .fillEqually
        for b in [flashButton, timerButton, vignetteButton, grainButton, blurButton, formatButton] { topBar.addArrangedSubview(b) }

        previewFrame.backgroundColor = Palette.surface
        previewFrame.clipsToBounds = true

        blinkView.backgroundColor = .black
        blinkView.alpha = 0
        blinkView.isUserInteractionEnabled = false

        focusRing.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        focusRing.layer.cornerRadius = 36
        focusRing.layer.borderWidth = 1.5
        focusRing.layer.borderColor = Palette.accent.cgColor
        focusRing.alpha = 0
        focusRing.isUserInteractionEnabled = false

        titleLabel.font = .serifItalic(40)
        titleLabel.textColor = Palette.ink
        indexLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        indexLabel.textColor = Palette.accent
        for l in [titleLabel, indexLabel] { shadow(l, radius: 7) }
        titleBox.axis = .vertical
        titleBox.alignment = .center
        titleBox.spacing = 2
        titleBox.addArrangedSubview(titleLabel)
        titleBox.addArrangedSubview(indexLabel)
        titleBox.alpha = 0
        titleBox.isUserInteractionEnabled = false

        countdownLabel.font = .serif(120)
        countdownLabel.textColor = Palette.ink
        countdownLabel.isHidden = true
        shadow(countdownLabel, radius: 10)

        buildPermissionPanel()

        for v in [previewView, blinkView, titleBox, countdownLabel, permissionPanel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            previewFrame.addSubview(v)
        }
        previewFrame.addSubview(focusRing)

        // Bas de l'écran : curseur du flou, bande de filtres, déclencheur.
        let scrim = ScrimView()
        scrim.isUserInteractionEnabled = false
        let content = UIStackView()
        content.axis = .vertical
        buildBlurRow()
        buildFilterScroll()
        let controls = buildControls()
        content.addArrangedSubview(blurRow)
        content.addArrangedSubview(filterScroll)
        content.addArrangedSubview(controls)

        screenFlash.backgroundColor = Palette.flash
        screenFlash.isHidden = true

        toastLabel.font = .systemFont(ofSize: 14, weight: .medium)
        toastLabel.textColor = Palette.ink
        toastLabel.backgroundColor = Palette.surface.withAlphaComponent(0.92)
        toastLabel.layer.cornerRadius = 16
        toastLabel.clipsToBounds = true
        toastLabel.numberOfLines = 0
        toastLabel.textAlignment = .center
        toastLabel.alpha = 0
        toastLabel.isUserInteractionEnabled = false

        for v in [scrim, content] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bottomPanel.addSubview(v)
        }
        // L'aperçu est placé à la main (selon le format) ; la barre du haut passe par-dessus.
        view.addSubview(previewFrame)
        topScrim.isUserInteractionEnabled = false
        for v in [topScrim, topBar, bottomPanel, toastLabel, screenFlash] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: safe.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            topBar.heightAnchor.constraint(equalToConstant: 58),

            topScrim.topAnchor.constraint(equalTo: view.topAnchor),
            topScrim.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            topScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            previewView.topAnchor.constraint(equalTo: previewFrame.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: previewFrame.bottomAnchor),
            previewView.leadingAnchor.constraint(equalTo: previewFrame.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: previewFrame.trailingAnchor),
            blinkView.topAnchor.constraint(equalTo: previewFrame.topAnchor),
            blinkView.bottomAnchor.constraint(equalTo: previewFrame.bottomAnchor),
            blinkView.leadingAnchor.constraint(equalTo: previewFrame.leadingAnchor),
            blinkView.trailingAnchor.constraint(equalTo: previewFrame.trailingAnchor),
            permissionPanel.topAnchor.constraint(equalTo: previewFrame.topAnchor),
            permissionPanel.bottomAnchor.constraint(equalTo: previewFrame.bottomAnchor),
            permissionPanel.leadingAnchor.constraint(equalTo: previewFrame.leadingAnchor),
            permissionPanel.trailingAnchor.constraint(equalTo: previewFrame.trailingAnchor),
            titleBox.centerXAnchor.constraint(equalTo: previewFrame.centerXAnchor),
            titleBox.centerYAnchor.constraint(equalTo: previewFrame.centerYAnchor),
            titleBox.widthAnchor.constraint(lessThanOrEqualTo: previewFrame.widthAnchor, constant: -32),
            countdownLabel.centerXAnchor.constraint(equalTo: previewFrame.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: previewFrame.centerYAnchor),

            bottomPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrim.topAnchor.constraint(equalTo: bottomPanel.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomPanel.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor),
            content.topAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: 22),
            content.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: safe.bottomAnchor),

            toastLabel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),

            screenFlash.topAnchor.constraint(equalTo: view.topAnchor),
            screenFlash.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            screenFlash.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            screenFlash.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func buildPermissionPanel() {
        permissionPanel.backgroundColor = Palette.surface
        permissionPanel.isHidden = true
        let message = UILabel()
        message.text = "Pellicule a besoin de la caméra pour prendre des photos."
        message.font = .systemFont(ofSize: 16)
        message.textColor = Palette.ink
        message.numberOfLines = 0
        message.textAlignment = .center
        permissionButton.setTitle("Autoriser la caméra", for: .normal)
        permissionButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        permissionButton.setTitleColor(Palette.bg, for: .normal)
        permissionButton.backgroundColor = Palette.accent
        permissionButton.layer.cornerRadius = 22
        permissionButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        let stack = UIStackView(arrangedSubviews: [message, permissionButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        permissionPanel.addSubview(stack)
        NSLayoutConstraint.activate([
            permissionButton.heightAnchor.constraint(equalToConstant: 44),
            stack.centerYAnchor.constraint(equalTo: permissionPanel.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: permissionPanel.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: permissionPanel.trailingAnchor, constant: -32),
        ])
    }

    private func buildBlurRow() {
        func sliderLabel(_ text: String) -> UILabel {
            let l = UILabel()
            l.text = text
            l.font = .systemFont(ofSize: 12, weight: .medium)
            l.textColor = Palette.inkDim
            l.isAccessibilityElement = false
            l.setContentHuggingPriority(.required, for: .horizontal)
            return l
        }
        blurSlider.minimumValue = 0
        blurSlider.maximumValue = 1
        blurSlider.minimumTrackTintColor = Palette.accent
        blurSlider.maximumTrackTintColor = Palette.inkDim
        blurSlider.thumbTintColor = Palette.accent
        blurSlider.accessibilityLabel = "Intensité du flou"
        blurRow.axis = .horizontal
        blurRow.alignment = .center
        blurRow.spacing = 12
        blurRow.isLayoutMarginsRelativeArrangement = true
        blurRow.layoutMargins = UIEdgeInsets(top: 0, left: 20, bottom: 6, right: 20)
        blurRow.addArrangedSubview(sliderLabel("Léger"))
        blurRow.addArrangedSubview(blurSlider)
        blurRow.addArrangedSubview(sliderLabel("Fort"))
        blurRow.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func buildFilterScroll() {
        filterScroll.showsHorizontalScrollIndicator = false
        filterScroll.alwaysBounceHorizontal = true
        filterStrip.axis = .horizontal
        filterStrip.isLayoutMarginsRelativeArrangement = true
        filterStrip.layoutMargins = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        filterStrip.translatesAutoresizingMaskIntoConstraints = false
        filterScroll.addSubview(filterStrip)
        NSLayoutConstraint.activate([
            filterScroll.heightAnchor.constraint(equalToConstant: 102),
            filterStrip.topAnchor.constraint(equalTo: filterScroll.contentLayoutGuide.topAnchor),
            filterStrip.bottomAnchor.constraint(equalTo: filterScroll.contentLayoutGuide.bottomAnchor),
            filterStrip.leadingAnchor.constraint(equalTo: filterScroll.contentLayoutGuide.leadingAnchor),
            filterStrip.trailingAnchor.constraint(equalTo: filterScroll.contentLayoutGuide.trailingAnchor),
            filterStrip.heightAnchor.constraint(equalTo: filterScroll.frameLayoutGuide.heightAnchor),
        ])
    }

    private func buildControls() -> UIView {
        let row = UIView()
        for v in [galleryButton, shutter, switchButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 100),
            galleryButton.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 40),
            galleryButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            shutter.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            shutter.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            shutter.widthAnchor.constraint(equalToConstant: 78),
            shutter.heightAnchor.constraint(equalToConstant: 78),
            switchButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -40),
            switchButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func buildFilterStrip() {
        let random = FilterChip(title: "Hasard")
        random.thumb.image = UIImage(systemName: "shuffle")
        random.thumb.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        random.thumb.contentMode = .center
        random.addTarget(self, action: #selector(pickRandomFilter), for: .touchUpInside)
        filterStrip.addArrangedSubview(random)

        let smart = FilterChip(title: "IA")
        smart.accessibilityLabel = "Filtre IA : choisit le filtre selon la scène"
        smart.thumb.image = UIImage(systemName: "sparkles")
        smart.thumb.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        smart.thumb.contentMode = .center
        smart.thumb.tintColor = Palette.accent
        smart.addTarget(self, action: #selector(onAIFilter), for: .touchUpInside)
        filterStrip.addArrangedSubview(smart)

        for (i, filter) in FILTERS.enumerated() {
            let chip = FilterChip(title: filter.name)
            chip.accessibilityLabel = "Filtre \(filter.name)"
            chip.tag = i
            chip.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            chips.append(chip)
            filterStrip.addArrangedSubview(chip)
        }

        // Vignettes de départ sur une petite scène dessinée, remplacées ensuite par l'image de la caméra.
        thumbQueue.async { [weak self] in
            guard let scene = Look.sampleScene() else { return }
            let thumbs = Renderer.shared.filterThumbs(from: CIImage(cgImage: scene))
            DispatchQueue.main.async { self?.setThumbs(thumbs, onlyIfEmpty: true) }
        }
    }

    private func setThumbs(_ thumbs: [CGImage?], onlyIfEmpty: Bool = false) {
        for (chip, thumb) in zip(chips, thumbs) {
            guard let thumb, !(onlyIfEmpty && chip.thumb.image != nil) else { continue }
            chip.thumb.image = UIImage(cgImage: thumb)
        }
    }

    private func shadow(_ view: UIView, radius: CGFloat) {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.6
        view.layer.shadowRadius = radius
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    // MARK: - Gestes et boutons

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        for g in [tap, doubleTap, pan, pinch] { previewFrame.addGestureRecognizer(g) }

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onGalleryLongPress(_:)))
        galleryButton.addGestureRecognizer(longPress)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    private func setupActions() {
        flashButton.addTarget(self, action: #selector(onFlash), for: .touchUpInside)
        timerButton.addTarget(self, action: #selector(onTimer), for: .touchUpInside)
        vignetteButton.addTarget(self, action: #selector(onVignette), for: .touchUpInside)
        grainButton.addTarget(self, action: #selector(onGrain), for: .touchUpInside)
        blurButton.addTarget(self, action: #selector(onBlur), for: .touchUpInside)
        formatButton.addTarget(self, action: #selector(onFormat), for: .touchUpInside)
        blurSlider.addTarget(self, action: #selector(onBlurSlider), for: .valueChanged)
        blurSlider.addTarget(self, action: #selector(savePrefs), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        shutter.addTarget(self, action: #selector(onShutter), for: .touchUpInside)
        switchButton.addTarget(self, action: #selector(switchCamera), for: .touchUpInside)
        galleryButton.addTarget(self, action: #selector(openLastPhoto), for: .touchUpInside)
        permissionButton.addTarget(self, action: #selector(onPermissionButton), for: .touchUpInside)
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard permissionPanel.isHidden else { return }
        focus(at: g.location(in: previewFrame))
    }

    @objc private func onDoubleTap() {
        guard permissionPanel.isHidden else { return }
        switchCamera()
    }

    /// Le glissement se juge à la distance parcourue : un geste lent change aussi de filtre.
    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            pinched = false
        case .ended:
            let t = g.translation(in: previewFrame)
            if !pinched, abs(t.x) > 56, abs(t.x) > abs(t.y) * 1.5 {
                selectFilter(current + (t.x < 0 ? 1 : -1))
            }
        default:
            break
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinched = true
            pinchStart = camera.zoom
        case .changed:
            camera.setZoom(pinchStart * g.scale)
        default:
            break
        }
    }

    @objc private func onFlash() {
        flashMode = FlashMode(rawValue: (flashMode.rawValue + 1) % 3) ?? .off
        updateFlashUi()
        savePrefs()
    }

    @objc private func onTimer() {
        timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
        updateTimerUi()
        savePrefs()
    }

    @objc private func onVignette() {
        vignetteOn.toggle()
        updateVignette(animated: true)
        savePrefs()
    }

    @objc private func onGrain() {
        grainOn.toggle()
        updateGrainUi()
        savePrefs()
    }

    @objc private func onBlur() {
        blurMode = BlurMode(rawValue: (blurMode.rawValue + 1) % 4) ?? .off
        UIView.animate(withDuration: 0.2) {
            self.updateBlurUi()
            self.view.layoutIfNeeded()
        }
        switch blurMode {
        case .radial: announce("Flou rond", "Touche l’image : zone nette", hold: 2.2)
        case .band: announce("Flou bande", "Touche l’image : zone nette", hold: 2.2)
        case .ai: announce("Flou IA", "Sujet net, fond flou", hold: 2.2)
        case .off: break
        }
        savePrefs()
    }

    @objc private func onFormat() {
        format = (format + 1) % FORMATS.count
        updateFormatUi()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
            self.layoutPreviewFrame()
        }
        announce(FORMATS[format].title, "FORMAT")
        savePrefs()
    }

    @objc private func onBlurSlider() {
        blurIntensity = CGFloat(blurSlider.value)
        pushLook()
    }

    @objc private func chipTapped(_ chip: FilterChip) {
        selectFilter(chip.tag)
    }

    /// Filtre IA : l'IA du téléphone reconnaît la scène et choisit le filtre.
    @objc private func onAIFilter() {
        frameLock.lock()
        let frame = latestFrame
        frameLock.unlock()
        guard let frame, !aiBusy else {
            if frame == nil { toast("La caméra n’est pas encore prête.") }
            return
        }
        aiBusy = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let k = 512 / max(frame.extent.width, frame.extent.height)
        let small = frame.transformed(by: CGAffineTransform(scaleX: k, y: k))
        aiQueue.async { [weak self] in
            let guess = SceneAI.guess(small, context: Renderer.shared.context)
            DispatchQueue.main.async {
                guard let self else { return }
                self.aiBusy = false
                self.selectFilter(guess.filterIndex, announce: false)
                self.announce(FILTERS[guess.filterIndex].name, "IA · " + guess.title.uppercased(), hold: 1.6)
            }
        }
    }

    @objc private func pickRandomFilter() {
        guard FILTERS.count > 1 else { return }
        var next = current
        while next == current { next = Int.random(in: 0..<FILTERS.count) }
        selectFilter(next)
    }

    // MARK: - Filtres et effets

    private func selectFilter(_ index: Int, announce shouldAnnounce: Bool = true) {
        let n = FILTERS.count
        current = ((index % n) + n) % n
        for (i, chip) in chips.enumerated() { chip.isChosen = i == current }
        if didInitialScroll { scrollToChip(animated: true) }
        updateVignette(animated: true)
        if shouldAnnounce {
            announce(FILTERS[current].name, String(format: "%02d / %02d", current + 1, n))
        }
        defaults.set(current, forKey: "filter")
    }

    private func scrollToChip(animated: Bool) {
        let chip = chips[current]
        let frame = chip.convert(chip.bounds, to: filterScroll)
        let maxX = max(0, filterScroll.contentSize.width - filterScroll.bounds.width)
        let x = min(max(0, frame.midX - filterScroll.bounds.width / 2), maxX)
        filterScroll.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    }

    /// Grand titre au centre de l'aperçu, qui s'efface tout seul.
    private func announce(_ title: String, _ subtitle: String, hold: TimeInterval = 0.7) {
        titleLabel.text = title
        indexLabel.attributedText = NSAttributedString(string: subtitle, attributes: [.kern: 2.4])
        announceToken += 1
        let token = announceToken
        titleBox.layer.removeAllAnimations()
        titleBox.alpha = 0
        titleBox.transform = CGAffineTransform(translationX: 0, y: 8)
        UIView.animate(withDuration: 0.16, delay: 0, options: [.allowUserInteraction], animations: {
            self.titleBox.alpha = 1
            self.titleBox.transform = .identity
        }, completion: { _ in
            guard token == self.announceToken else { return }
            UIView.animate(withDuration: 0.35, delay: hold, options: [.allowUserInteraction], animations: {
                self.titleBox.alpha = 0
            })
        })
        UIAccessibility.post(notification: .announcement, argument: title)
    }

    private var effectiveVignette: CGFloat {
        max(FILTERS[current].vignette, vignetteOn ? 0.75 : 0)
    }

    private func updateVignette(animated: Bool) {
        vignetteButton.isOn = vignetteOn
        let target = effectiveVignette
        vignetteTween.cancel()
        guard animated, abs(target - shownVignette) > 0.001 else {
            shownVignette = target
            pushLook()
            return
        }
        let from = shownVignette
        vignetteTween.run(duration: 0.22) { [weak self] t in
            self?.shownVignette = from + (target - from) * t
            self?.pushLook()
        }
    }

    private func updateGrainUi() {
        grainButton.isOn = grainOn
        pushLook()
    }

    private func updateBlurUi() {
        let titles = ["Flou", "Flou rond", "Flou bande", "Flou IA"]
        blurButton.set(symbol: blurMode == .ai ? "sparkles" : "scope", title: titles[blurMode.rawValue])
        if blurMode != .ai { subjects.clear() }
        blurButton.isOn = blurMode != .off
        blurRow.isHidden = blurMode == .off
        blurRow.alpha = blurMode == .off ? 0 : 1
        if blurMode == .off {
            focusTween.cancel()
            drawnFocus = focusTarget
            spread = 1
        }
        pushLook()
    }

    private func updateFormatUi() {
        let f = FORMATS[format]
        formatButton.set(symbol: "aspectratio", title: f.label)
        formatButton.accessibilityLabel = "Format de la photo : \(f.title)"
        formatButton.isOn = format != 0
    }

    /**
     Taille et place de l'aperçu selon le format : sous la barre du haut si la place suffit,
     sinon remonté jusqu'en haut de l'écran ; le plein écran occupe tout l'écran.
     */
    private func layoutPreviewFrame() {
        let b = view.bounds
        guard b.width > 0, b.height > 0 else { return }
        var frame = b
        if let ratio = FORMATS[format].ratio {
            var w = b.width
            var h = (w / ratio).rounded()
            let bar = topBar.frame.maxY
            var top = bar + h <= b.height ? bar : max(0, b.height - h)
            if h > b.height {
                h = b.height
                w = (h * ratio).rounded()
                top = 0
            }
            frame = CGRect(x: ((b.width - w) / 2).rounded(), y: top, width: w, height: h)
        }
        if previewFrame.frame != frame {
            previewFrame.frame = frame
            previewFrame.layoutIfNeeded()
        }
        let aspect = frame.width / frame.height
        if abs(aspect - previewAspect) > 0.0001 {
            previewAspect = aspect
            pushLook()
        }
    }

    private func updateFlashUi() {
        flashButton.set(symbol: flashMode.symbol, title: flashMode.title)
        flashButton.isOn = flashMode != .off
    }

    private func updateTimerUi() {
        timerButton.set(symbol: "timer", title: timerSeconds == 0 ? "Minuteur" : "\(timerSeconds) s")
        timerButton.isOn = timerSeconds > 0
    }

    /// Transmet les réglages affichés au fil de l'aperçu.
    private func pushLook() {
        var s = LookSettings()
        s.matrix = FILTERS[current].matrix
        s.vignette = shownVignette
        s.grain = grainOn
        s.blur = blurMode
        s.blurIntensity = blurIntensity
        s.focus = drawnFocus
        s.spread = spread
        s.aspect = previewAspect
        shared.set(s)
    }

    /// Réglages de la photo : les valeurs visées, sans les étapes d'animation.
    private func photoSettings() -> LookSettings {
        var s = shared.get()
        s.vignette = effectiveVignette
        s.focus = focusTarget
        s.spread = 1
        return s
    }

    // MARK: - Mise au point

    private func focus(at p: CGPoint) {
        let w = max(1, previewFrame.bounds.width)
        let h = max(1, previewFrame.bounds.height)
        let n = CGPoint(x: min(max(p.x / w, 0), 1), y: min(max(p.y / h, 0), 1))
        focusTarget = n
        if cameraReady {
            // L'aperçu est un recadrage centré de l'image 4:3 de la caméra.
            let cw = min(1, previewAspect / 0.75)
            let ch = min(1, 0.75 / previewAspect)
            camera.focus(atPreviewPoint: CGPoint(x: 0.5 + (n.x - 0.5) * cw, y: 0.5 + (n.y - 0.5) * ch))
        }

        // Le point touché devient aussi la zone nette du flou : la netteté se resserre puis s'ouvre.
        focusTween.cancel()
        if blurMode == .off {
            drawnFocus = n
            spread = 1
            pushLook()
        } else {
            let from = drawnFocus
            focusTween.run(duration: 0.56) { [weak self] t in
                guard let self else { return }
                let move = decelerate(t / 0.45, 2)
                self.drawnFocus = CGPoint(x: from.x + (n.x - from.x) * move, y: from.y + (n.y - from.y) * move)
                self.spread = t < 0.3 ? 1 - 0.75 * (t / 0.3) : 0.25 + 0.75 * decelerate((t - 0.3) / 0.7, 1.6)
                self.pushLook()
            }
        }

        focusRing.layer.removeAllAnimations()
        focusRing.center = p
        focusRing.alpha = 1
        focusRing.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
        UIView.animate(withDuration: 0.2, animations: {
            self.focusRing.transform = .identity
        }, completion: { done in
            guard done else { return }
            UIView.animate(withDuration: 0.3, delay: 0.7, options: [], animations: { self.focusRing.alpha = 0 })
        })
    }

    // MARK: - Aperçu en direct (fil de la caméra)

    private func drawFrame(_ frame: CIImage) {
        let size = metalLayer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        let base = Look.crop(frame, aspect: size.width / size.height)
        let k = max(size.width / base.extent.width, size.height / base.extent.height)
        var image = base.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let dx = ((image.extent.width - size.width) / 2).rounded()
        let dy = ((image.extent.height - size.height) / 2).rounded()
        image = image.cropped(to: CGRect(x: dx, y: dy, width: size.width, height: size.height))
            .transformed(by: CGAffineTransform(translationX: -dx, y: -dy))

        frameLock.lock()
        latestFrame = base
        frameLock.unlock()

        let now = CACurrentMediaTime()
        if now - grainTime >= 0.08 {
            grainTime = now
            grainOffset = CGPoint(x: CGFloat.random(in: 0..<1), y: CGFloat.random(in: 0..<1))
        }
        var settings = shared.get()
        if settings.blur == .ai {
            // L'IA détoure le sujet sur une petite image, en parallèle ; on applique le dernier masque connu.
            let k = 640 / max(base.extent.width, base.extent.height)
            subjects.submit(base.transformed(by: CGAffineTransform(scaleX: k, y: k)))
            settings.subjectMask = subjects.latest()
        }
        Renderer.shared.draw(Look.render(image, settings, grainOffset: grainOffset), in: metalLayer)

        // Toutes les 2 s, les vignettes de filtres reprennent l'image de la caméra.
        if now - thumbTime >= 2 {
            thumbTime = now
            let chip = Look.crop(frame, aspect: 0.75)
            let t = 120 / chip.extent.width
            let small = chip.transformed(by: CGAffineTransform(scaleX: t, y: t))
            thumbQueue.async { [weak self] in
                let thumbs = Renderer.shared.filterThumbs(from: small)
                DispatchQueue.main.async { self?.setThumbs(thumbs) }
            }
        }
    }

    // MARK: - Caméra

    private func checkCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionPanel.isHidden = true
            startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { self.checkCamera() }
            }
        default:
            permissionPanel.isHidden = false
        }
    }

    private func startCamera() {
        if cameraReady {
            camera.resume()
            return
        }
        guard !cameraStarting else { return }
        cameraStarting = true
        camera.start(position: .back) { [weak self] ok in
            guard let self else { return }
            self.cameraStarting = false
            self.cameraReady = ok
            if !ok { self.toast("Impossible d’ouvrir la caméra.") }
        }
    }

    @objc private func onPermissionButton() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            checkCamera()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    @objc private func switchCamera() {
        guard cameraReady, !busy else { return }
        UIView.animate(withDuration: 0.26) {
            self.switchButton.imageView.transform = self.switchButton.imageView.transform.rotated(by: .pi)
        }
        camera.switchCamera { _ in }
    }

    // MARK: - Prise de vue

    @objc private func onShutter() {
        if countdownTimer != nil {
            cancelCountdown()
            return
        }
        guard cameraReady, !busy else { return }
        if timerSeconds > 0 { startCountdown() } else { capture() }
    }

    private func startCountdown() {
        countdownLeft = timerSeconds
        shutter.isArmed = true
        countdownTick()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.countdownTick()
        }
    }

    private func countdownTick() {
        if countdownLeft <= 0 {
            cancelCountdown()
            capture()
            return
        }
        countdownLabel.text = "\(countdownLeft)"
        countdownLabel.isHidden = false
        countdownLabel.alpha = 0.3
        countdownLabel.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
        UIView.animate(withDuration: 0.3) {
            self.countdownLabel.alpha = 1
            self.countdownLabel.transform = .identity
        }
        countdownLeft -= 1
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownLeft = 0
        countdownLabel.isHidden = true
        shutter.isArmed = false
    }

    private func capture() {
        guard cameraReady, !busy else { return }
        busy = true
        let settings = photoSettings()
        let orientation = tracker.orientation
        let front = camera.isFront
        let screenFlashOn = front && flashMode != .off
        let flash: AVCaptureDevice.FlashMode = front ? .off : flashMode.device
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let take = { [weak self] in
            guard let self else { return }
            self.blink()
            self.camera.capture(flash: flash) { [weak self] data in
                DispatchQueue.main.async {
                    if screenFlashOn { self?.hideScreenFlash() }
                }
                guard let data else {
                    DispatchQueue.main.async {
                        self?.busy = false
                        self?.toast("La photo n’a pas pu être prise. Réessaie.")
                    }
                    return
                }
                self?.photoQueue.async {
                    let result = Renderer.shared.renderPhoto(data, settings, orientation: orientation)
                    DispatchQueue.main.async { self?.photoReady(result) }
                }
            }
        }
        if screenFlashOn {
            showScreenFlash()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: take)
        } else {
            take()
        }
    }

    private func photoReady(_ result: (jpeg: Data, thumb: CGImage?)?) {
        busy = false
        guard let result else {
            toast("La photo n’a pas pu être prise. Réessaie.")
            return
        }
        lastPhoto = result.jpeg
        if let thumb = result.thumb {
            galleryButton.showPhoto(UIImage(cgImage: thumb))
        }
        galleryButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.galleryButton.transform = .identity
        }
        PhotoSaver.save(result.jpeg) { [weak self] ok in
            if !ok { self?.toast("Impossible d’enregistrer la photo. Autorise l’ajout de photos dans Réglages › Pellicule.") }
        }
    }

    private func blink() {
        blinkView.layer.removeAllAnimations()
        blinkView.alpha = 0.9
        UIView.animate(withDuration: 0.26, delay: 0.04, options: [], animations: { self.blinkView.alpha = 0 })
    }

    private var screen: UIScreen { view.window?.windowScene?.screen ?? UIScreen.main }

    private func showScreenFlash() {
        screenFlash.layer.removeAllAnimations()
        screenFlash.alpha = 1
        screenFlash.isHidden = false
        if savedBrightness == nil { savedBrightness = screen.brightness }
        screen.brightness = 1
    }

    private func hideScreenFlash() {
        UIView.animate(withDuration: 0.2, animations: { self.screenFlash.alpha = 0 }, completion: { _ in
            self.screenFlash.isHidden = true
        })
        if let b = savedBrightness {
            screen.brightness = b
            savedBrightness = nil
        }
    }

    // MARK: - Galerie et partage

    @objc private func openLastPhoto() {
        if let jpeg = lastPhoto {
            present(PhotoViewController(jpeg: jpeg), animated: true)
        } else if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url) { [weak self] ok in
                if !ok { self?.toast("Prends d’abord une photo.") }
            }
        }
    }

    @objc private func onGalleryLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        guard let jpeg = lastPhoto else {
            toast("Prends d’abord une photo.")
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        PhotoSaver.share(jpeg, from: self, source: galleryButton)
    }

    private func toast(_ text: String) {
        toastLabel.text = text
        toastLabel.layer.removeAllAnimations()
        toastLabel.alpha = 0
        UIView.animate(withDuration: 0.2, animations: { self.toastLabel.alpha = 1 }, completion: { done in
            guard done else { return }
            UIView.animate(withDuration: 0.3, delay: 2.4, options: [], animations: { self.toastLabel.alpha = 0 })
        })
    }

    // MARK: - Réglages mémorisés

    private func restorePrefs() {
        current = min(max(defaults.integer(forKey: "filter"), 0), FILTERS.count - 1)
        vignetteOn = defaults.bool(forKey: "vignette")
        grainOn = defaults.bool(forKey: "grain")
        let t = defaults.integer(forKey: "timer")
        timerSeconds = [0, 3, 10].contains(t) ? t : 0
        flashMode = FlashMode(rawValue: defaults.integer(forKey: "flash")) ?? .off
        blurMode = BlurMode(rawValue: defaults.integer(forKey: "blur")) ?? .off
        format = min(max(defaults.integer(forKey: "format"), 0), FORMATS.count - 1)
        if let v = defaults.object(forKey: "blur_intensity") as? Double {
            blurIntensity = min(max(CGFloat(v), 0), 1)
        }
    }

    @objc private func savePrefs() {
        defaults.set(vignetteOn, forKey: "vignette")
        defaults.set(grainOn, forKey: "grain")
        defaults.set(timerSeconds, forKey: "timer")
        defaults.set(flashMode.rawValue, forKey: "flash")
        defaults.set(blurMode.rawValue, forKey: "blur")
        defaults.set(Double(blurIntensity), forKey: "blur_intensity")
        defaults.set(format, forKey: "format")
    }
}

/// Laisse passer les touchers qui tombent sur le fond (le dégradé au-dessus de l'aperçu).
final class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Étiquette avec marges intérieures (messages temporaires).
final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines n: Int) -> CGRect {
        let r = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: n)
        return r.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}

/// Dégradé vertical (fond de la barre du haut, lisible quand l'aperçu passe dessous).
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    init(colors: [UIColor], locations: [NSNumber]) {
        super.init(frame: .zero)
        let g = layer as! CAGradientLayer
        g.colors = colors.map(\.cgColor)
        g.locations = locations
    }

    required init?(coder: NSCoder) { fatalError() }
}
