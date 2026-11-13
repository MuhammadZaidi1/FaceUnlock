import CoreImage
import CoreML
import CryptoKit
import RecognitionCore
import Vision

private struct ModelAssetError: LocalizedError {
    let reason: String
    var errorDescription: String? { "Face model unavailable: " + reason }
}

public struct FaceQualityError: LocalizedError {
    let reason: String
    public var errorDescription: String? { reason }
}

public protocol FaceEmbeddingModel {
    func prepare() throws
    func embedding(from buffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float]
}

public extension FaceEmbeddingModel {
    func prepare() throws {}
}

/// SFace MobileFaceNet weights, not a generic Vision feature print.
/// Used serially on the capture queue; model compilation/inference never runs on the UI thread.
public final class SFaceModel: FaceEmbeddingModel {
    public init() {}
    public func prepare() throws { _ = try load() }
    private var model: MLModel?
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    private static let size = 112

    private func load() throws -> MLModel {
        if let model { return model }
        let directory = Bundle.main.resourceURL?.appendingPathComponent("Models")
        // A packaged app must use its own resources, never a developer's .build directory.
        let fallback = Bundle.main.bundleURL.pathExtension == "app" ? nil : Bundle.module.url(forResource: "Models", withExtension: nil)
        let root = [directory, fallback].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("SFace.mlpackage").path)
        }
        guard let root,
              let metadata = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              manifest["source_sha256"] as? String == ModelIdentity.sface.weightsSHA256,
              manifest["model"] as? String == ModelIdentity.sface.name,
              manifest["pipeline_version"] as? Int == ModelIdentity.sface.pipelineVersion else {
            throw ModelAssetError(reason: "missing assets or incompatible source/model/pipeline metadata.")
        }
        let url = root.appendingPathComponent("SFace.mlpackage").standardizedFileURL.resolvingSymlinksInPath()
        var hasher = SHA256()
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw ModelAssetError(reason: "cannot read model package.")
        }
        let files = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
        for file in files {
            let rootPath = (url.path as NSString).standardizingPath
            let filePath = (file.path as NSString).standardizingPath
            guard filePath.hasPrefix(rootPath + "/") else { throw ModelAssetError(reason: "invalid package asset path.") }
            let relative = String(filePath.dropFirst(rootPath.count + 1))
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file, options: .mappedIfSafe))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard manifest["coreml_sha256"] as? String == digest else { throw ModelAssetError(reason: "package checksum mismatch.") }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let loaded = try MLModel(contentsOf: MLModel.compileModel(at: url), configuration: configuration)
        guard loaded.modelDescription.inputDescriptionsByName["face"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 3, 112, 112],
              loaded.modelDescription.outputDescriptionsByName["embedding"] != nil else {
            throw ModelAssetError(reason: "unexpected input/output tensor contract.")
        }
        model = loaded
        return loaded
    }

    public func embedding(from buffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float] {
        let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let aligned = try align(image, face: face)
        var bytes = [UInt8](repeating: 0, count: 112 * 112 * 4)
        context.render(aligned, toBitmap: &bytes, rowBytes: 112 * 4,
                       bounds: CGRect(x: 0, y: 0, width: 112, height: 112),
                       format: .RGBA8, colorSpace: nil)
        // Core Image renders bitmap rows top-to-bottom; pass unscaled RGB byte values to SFace.
        var rgb = [Float](repeating: 0, count: 3 * 112 * 112)
        var gray = [Double](repeating: 0, count: 112 * 112)
        for y in 0..<112 {
            for x in 0..<112 {
                let p = (y * 112 + x) * 4
                let i = y * 112 + x
                for c in 0..<3 { rgb[c * 112 * 112 + i] = Float(bytes[p + c]) }
                gray[i] = 0.299 * Double(bytes[p]) + 0.587 * Double(bytes[p + 1]) + 0.114 * Double(bytes[p + 2])
            }
        }
        let mean = gray.reduce(0, +) / Double(gray.count)
        let clipped = gray.filter { $0 < 15 || $0 > 240 }.count
        guard (45...210).contains(mean), Double(clipped) / Double(gray.count) < 0.3 else {
            throw FaceQualityError(reason: "Lighting is too dark, bright, or uneven. Face a soft light.")
        }
        var laplacian: [Double] = []
        for y in 1..<111 {
            for x in 1..<111 {
                let i = y * 112 + x
                laplacian.append(gray[i - 1] + gray[i + 1] + gray[i - 112] + gray[i + 112] - 4 * gray[i])
            }
        }
        let lapMean = laplacian.reduce(0, +) / Double(laplacian.count)
        let variance = laplacian.reduce(0) { $0 + pow($1 - lapMean, 2) } / Double(laplacian.count)
        guard variance >= 70 else { throw FaceQualityError(reason: "Image is blurry. Hold still and check camera focus.") }
        return try predict(rgb)
    }

    public func predict(_ rgb: [Float]) throws -> [Float] {
        guard rgb.count == 3 * 112 * 112, rgb.allSatisfy(\.isFinite) else { throw RecognitionError.invalidEmbedding }
        let tensor = try MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32)
        for i in rgb.indices { tensor[i] = NSNumber(value: rgb[i]) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(multiArray: tensor)])
        let output = try load().prediction(from: provider)
        guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue, embedding.count == 128 else {
            throw RecognitionError.invalidEmbedding
        }
        return try Embedding.normalize((0..<128).map { embedding[$0].floatValue })
    }

    private func align(_ image: CIImage, face: VNFaceObservation) throws -> CIImage {
        guard let landmarks = face.landmarks, let eye1 = landmarks.leftEye, let eye2 = landmarks.rightEye,
              let nose = landmarks.noseCrest, let lips = landmarks.outerLips else {
            throw FaceQualityError(reason: "Eyes, nose, and mouth must be visible. Remove obstructions and face the camera.")
        }
        func points(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
            region.normalizedPoints.map {
                CGPoint(x: (face.boundingBox.minX + CGFloat($0.x) * face.boundingBox.width) * image.extent.width,
                        y: (face.boundingBox.minY + CGFloat($0.y) * face.boundingBox.height) * image.extent.height)
            }
        }
        func center(_ points: [CGPoint]) throws -> CGPoint {
            guard !points.isEmpty else { throw FaceQualityError(reason: "Face landmarks are incomplete.") }
            return CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count), y: points.map(\.y).reduce(0, +) / Double(points.count))
        }
        let eyes = try [center(points(eye1)), center(points(eye2))].sorted { $0.x < $1.x }
        guard let tip = points(nose).min(by: { $0.y < $1.y }),
              let mouthLeft = points(lips).min(by: { $0.x < $1.x }),
              let mouthRight = points(lips).max(by: { $0.x < $1.x }) else {
            throw FaceQualityError(reason: "Face landmarks are incomplete.")
        }
        let source = [eyes[0], eyes[1], tip, mouthLeft, mouthRight]
        // OpenCV SFace's five canonical landmarks, converted to Core Image's lower-left origin.
        let target = [CGPoint(x: 38.2946, y: 112 - 51.6963), CGPoint(x: 73.5318, y: 112 - 51.5014),
                      CGPoint(x: 56.0252, y: 112 - 71.7366), CGPoint(x: 41.5493, y: 112 - 92.3655),
                      CGPoint(x: 70.7299, y: 112 - 92.2041)]
        let aCenter = try center(source), bCenter = try center(target)
        var real = 0.0, imaginary = 0.0, denominator = 0.0
        for (s, t) in zip(source, target) {
            let x = s.x - aCenter.x, y = s.y - aCenter.y
            let u = t.x - bCenter.x, v = t.y - bCenter.y
            real += x * u + y * v
            imaginary += x * v - y * u
            denominator += x * x + y * y
        }
        guard denominator > 1 else { throw FaceQualityError(reason: "Move closer and face the camera.") }
        let a = real / denominator, b = imaginary / denominator
        let transform = CGAffineTransform(a: a, b: b, c: -b, d: a,
                                          tx: bCenter.x - a * aCenter.x + b * aCenter.y,
                                          ty: bCenter.y - b * aCenter.x - a * aCenter.y)
        let residual = zip(source, target).reduce(0.0) { total, pair in
            let p = pair.0.applying(transform)
            return total + pow(p.x - pair.1.x, 2) + pow(p.y - pair.1.y, 2)
        }
        guard sqrt(residual / 5) <= 5 else { throw FaceQualityError(reason: "Face alignment is poor. Look toward the camera.") }
        return image.transformed(by: transform).cropped(to: CGRect(x: 0, y: 0, width: 112, height: 112))
    }
}
