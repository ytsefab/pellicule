import CoreImage
import Vision

/// Ce que l'IA a reconnu, et le filtre qu'elle propose.
struct SceneGuess {
    let title: String
    let filterIndex: Int
}

/**
 Filtre IA : l'IA du téléphone (Vision, sur la puce Neural Engine) reconnaît la scène parmi
 plus de 1 300 catégories, et Pellicule choisit le filtre qui lui va le mieux.
 */
enum SceneAI {
    // Le poids fait passer les scènes précises (coucher de soleil, mer…) avant les plus générales (ciel).
    private static let rules: [(title: String, filter: String, labels: [String], weight: Float)] = [
        ("Coucher de soleil", "Doré", ["sunset_sunrise"], 1),
        ("Portrait", "Pêche", ["people", "adult", "child", "baby"], 1),
        ("Cuisine", "Doré", ["food", "dessert", "frozen_dessert", "seafood", "drink", "coffee"], 1),
        ("Neige", "Givre", ["snow", "ice", "iceberg", "winter_sport"], 1),
        ("Mer", "Éclat", ["beach", "ocean", "water_body", "lake", "waterfall", "underwater", "island"], 1),
        ("Nature", "Menthe", ["plant", "flower", "forest", "grass", "foliage", "garden", "decorative_plant", "flower_arrangement"], 1),
        ("Nuit", "Nuit", ["night_sky", "nightclub", "fireworks", "concert"], 1),
        ("Ville", "Cinéma", ["cityscape", "building", "skyscraper", "street"], 0.9),
        ("Animal", "Instant", ["animal", "dog", "cat", "adult_cat", "bird"], 1),
        ("Intérieur", "Rétro 70", ["interior_room", "furniture", "bedroom", "dining_room"], 0.8),
        ("Ciel", "Lavande", ["sky", "blue_sky", "cloudy"], 0.7),
        ("Montagne", "Brume", ["mountain", "cliff", "hill"], 0.9),
        ("Document", "Charbon", ["document"], 1),
    ]

    static func guess(_ image: CIImage, context: CIContext) -> SceneGuess {
        var scores: [String: Float] = [:]
        let request = VNClassifyImageRequest()
        if (try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])) != nil {
            for o in request.results ?? [] where o.confidence > 0.05 { scores[o.identifier] = o.confidence }
        }
        var best: (title: String, filter: String, score: Float)?
        for rule in rules {
            let score = (rule.labels.compactMap { scores[$0] }.max() ?? 0) * rule.weight
            if score >= 0.18, score > (best?.score ?? 0) { best = (rule.title, rule.filter, score) }
        }
        let luma = brightness(image, context: context)
        if luma < 0.14, best?.title != "Coucher de soleil", best?.title != "Nuit" {
            best = ("Faible lumière", "Nuit", 1)
        }
        let chosen = best ?? ("Scène", luma < 0.3 ? "Nuit" : "Cinéma", 0)
        let index = FILTERS.firstIndex { $0.name == chosen.filter } ?? 0
        return SceneGuess(title: chosen.title, filterIndex: index)
    }

    /// Luminosité moyenne (0–1).
    private static func brightness(_ image: CIImage, context: CIContext) -> CGFloat {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: Look.outputSpace)
        return (0.299 * CGFloat(px[0]) + 0.587 * CGFloat(px[1]) + 0.114 * CGFloat(px[2])) / 255
    }
}
