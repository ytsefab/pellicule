import AVFoundation
import CoreImage

/// Session caméra : flux d'aperçu (redressé en portrait) et prise de photo.
final class Camera: NSObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pellicule.session")
    private let videoQueue = DispatchQueue(label: "pellicule.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var pending: [Int64: PhotoDelegate] = [:]

    /// Chaque image de l'aperçu, en portrait (et en miroir pour la caméra frontale). Appelé hors du fil principal.
    var onFrame: ((CIImage) -> Void)?

    var device: AVCaptureDevice? { input?.device }
    var isFront: Bool { device?.position == .front }

    /// Démarre la caméra. `completion` (fil principal) reçoit false si aucune caméra n'a pu s'ouvrir.
    func start(position: AVCaptureDevice.Position, completion: @escaping (Bool) -> Void) {
        sessionQueue.async {
            let ok = self.configure(position: position)
            if ok, !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func pause() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func resume() {
        sessionQueue.async {
            if self.input != nil, !self.session.isRunning { self.session.startRunning() }
        }
    }

    func switchCamera(completion: @escaping (Bool) -> Void) {
        sessionQueue.async {
            let next: AVCaptureDevice.Position = self.device?.position == .front ? .back : .front
            let ok = self.configure(position: next)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private func configure(position: AVCaptureDevice.Position) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }

        let previous = input
        if let previous { session.removeInput(previous) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video),
              let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else {
            if let previous, session.canAddInput(previous) { session.addInput(previous) }
            return previous != nil
        }
        session.addInput(newInput)
        input = newInput

        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            // En mode photo, iOS livre de lui-même des images de la taille de l'écran (aperçu fluide).
            session.addOutput(videoOutput)
        }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        let mirror = device.position == .front
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
            setPortrait(connection)
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirror
            }
        }

        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        }
        return true
    }

    private func setPortrait(_ connection: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    // MARK: - Réglages pendant la prise de vue

    var zoom: CGFloat { device?.videoZoomFactor ?? 1 }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            let upper = min(device.maxAvailableVideoZoomFactor, 10)
            device.videoZoomFactor = min(max(factor, device.minAvailableVideoZoomFactor), upper)
            device.unlockForConfiguration()
        }
    }

    /// Mise au point et exposition sur un point de l'aperçu (0–1, origine en haut à gauche).
    func focus(atPreviewPoint p: CGPoint) {
        sessionQueue.async {
            guard let device = self.device else { return }
            // Repère du capteur : paysage, bouton latéral à droite. L'aperçu de la caméra frontale est en miroir.
            let point = device.position == .front ? CGPoint(x: p.y, y: p.x) : CGPoint(x: p.y, y: 1 - p.x)
            self.setFocus(device, point: point, mode: .autoFocus)
        }
    }

    /// Revient à la mise au point automatique au centre (quand la scène change).
    func resetFocus() {
        sessionQueue.async {
            guard let device = self.device else { return }
            self.setFocus(device, point: CGPoint(x: 0.5, y: 0.5), mode: .continuousAutoFocus)
        }
    }

    private func setFocus(_ device: AVCaptureDevice, point: CGPoint, mode: AVCaptureDevice.FocusMode) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(mode) {
            device.focusPointOfInterest = point
            device.focusMode = mode
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposurePointOfInterest = point
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()
    }

    // MARK: - Prise de vue

    /// Prend une photo. `completion` reçoit les données de l'image (ou nil), hors du fil principal.
    func capture(flash: AVCaptureDevice.FlashMode, completion: @escaping (Data?) -> Void) {
        sessionQueue.async {
            guard self.session.isRunning, self.photoOutput.connection(with: .video) != nil else {
                completion(nil)
                return
            }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            if self.photoOutput.supportedFlashModes.contains(flash) { settings.flashMode = flash }
            settings.photoQualityPrioritization = .balanced
            let id = settings.uniqueID
            let delegate = PhotoDelegate { data in
                self.sessionQueue.async { self.pending[id] = nil }
                completion(data)
            }
            self.pending[id] = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(CIImage(cvPixelBuffer: buffer))
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Data?) -> Void
    private var data: Data?

    init(completion: @escaping (Data?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error == nil { data = photo.fileDataRepresentation() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        completion(data)
    }
}
