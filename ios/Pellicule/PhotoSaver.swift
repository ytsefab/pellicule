import Photos
import UIKit

enum PhotoSaver {
    /// Ajoute la photo à la galerie (accès « ajout seulement » : Pellicule ne lit pas tes photos).
    static func save(_ jpeg: Data, completion: @escaping (Bool) -> Void) {
        let write = {
            PHPhotoLibrary.shared().performChanges({
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "Pellicule_\(Int(Date().timeIntervalSince1970)).jpg"
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: options)
            }, completionHandler: { ok, _ in
                DispatchQueue.main.async { completion(ok) }
            })
        }
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            write()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited {
                    write()
                } else {
                    DispatchQueue.main.async { completion(false) }
                }
            }
        default:
            completion(false)
        }
    }

    /// Feuille de partage pour la photo (fichier JPEG temporaire, pour garder la qualité d'origine).
    static func share(_ jpeg: Data, from controller: UIViewController, source: UIView) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pellicule.jpg")
        do {
            try jpeg.write(to: url, options: .atomic)
        } catch {
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = source
        sheet.popoverPresentationController?.sourceRect = source.bounds
        controller.present(sheet, animated: true)
    }
}

/// Dernière photo en plein écran, avec partage.
final class PhotoViewController: UIViewController {
    private let jpeg: Data
    private let imageView = UIImageView()
    private let shareButton = UIButton(type: .system)

    init(jpeg: Data) {
        self.jpeg = jpeg
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        imageView.image = UIImage(data: jpeg)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Dernière photo"

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        close.tintColor = Palette.ink
        close.accessibilityLabel = "Fermer"
        close.addTarget(self, action: #selector(dismissSelf), for: .touchUpInside)

        shareButton.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        shareButton.setTitle("  Partager", for: .normal)
        shareButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        shareButton.tintColor = Palette.bg
        shareButton.backgroundColor = Palette.accent
        shareButton.layer.cornerRadius = 22
        shareButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        shareButton.addTarget(self, action: #selector(share), for: .touchUpInside)

        for v in [imageView, close, shareButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            close.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            shareButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -20),
            shareButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shareButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(dismissSelf))
        swipe.direction = .down
        view.addGestureRecognizer(swipe)
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }

    @objc private func share() {
        PhotoSaver.share(jpeg, from: self, source: shareButton)
    }
}
