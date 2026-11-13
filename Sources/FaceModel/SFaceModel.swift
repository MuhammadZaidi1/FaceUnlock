import CoreImage
import CoreML
import CryptoKit
import RecognitionCore
import Vision

private struct ModelAssetError: LocalizedError {
    let reason: String
    var errorDescription: String? { "Face model unavailable: " + reason }
}

public struct FaceQualityMetrics: Sendable {
    public var alignmentResidual: Double?
    public var meanLuminance: Double?
    public var clippedFraction: Double?
    public var laplacianVariance: Double?
}

public struct FaceQualityError: LocalizedError {
    let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

public protocol FaceEmbeddingModel {
    var lastQualityMetrics: FaceQualityMetrics? { get }
    func prepare() throws
    func embedding(from buffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float]
}

public extension FaceEmbeddingModel {
    var lastQualityMetrics: FaceQualityMetrics? { nil }
    func prepare() throws {}
}

/// SFace MobileFaceNet weights, not a generic Vision feature print.
/// Used serially on the capture queue; model compilation/inference never runs on the UI thread.
public final class SFaceModel: FaceEmbeddingModel {
    public private(set) var lastQualityMetrics: FaceQualityMetrics?
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
              loaded.modelDescription.inputDescriptionsByName["face"]?.multiArrayConstraint?.dataType == .float32,
              loaded.modelDescription.outputDescriptionsByName["embedding"]?.multiArrayConstraint?.shape.map(\.intValue) == SFaceTensorContract.outputShape,
              loaded.modelDescription.outputDescriptionsByName["embedding"]?.multiArrayConstraint?.dataType == .float32,
              loaded.modelDescription.metadata[.versionString] as? String == "2021dec-pipeline1-fp32" else {
            throw ModelAssetError(reason: "unexpected input/output tensor contract.")
        }
        model = loaded
        return loaded
    }

    public func embedding(from buffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float] {
        lastQualityMetrics = FaceQualityMetrics()
        let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let aligned = try align(image, face: face)
        var bytes = [UInt8](repeating: 0, count: 112 * 112 * 4)
        context.render(aligned, toBitmap: &bytes, rowBytes: 112 * 4,
                       bounds: CGRect(x: 0, y: 0, width: 112, height: 112),
                       format: .RGBA8, colorSpace: nil)
        // Core Image renders bitmap rows top-to-bottom; pass unscaled RGB byte values to SFace.
        let rgb = try SFaceTensorContract.channelsFirstRGB(bytes)
        var gray = [Double](repeating: 0, count: 112 * 112)
        for y in 0..<112 {
            for x in 0..<112 {
                let p = (y * 112 + x) * 4
                let i = y * 112 + x
                gray[i] = 0.299 * Double(bytes[p]) + 0.587 * Double(bytes[p + 1]) + 0.114 * Double(bytes[p + 2])
            }
        }
        let mean = gray.reduce(0, +) / Double(gray.count)
        let clipped = gray.filter { $0 < 15 || $0 > 240 }.count
        lastQualityMetrics?.meanLuminance = mean
        lastQualityMetrics?.clippedFraction = Double(clipped) / Double(gray.count)
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
        lastQualityMetrics?.laplacianVariance = variance
        guard variance >= 70 else { throw FaceQualityError(reason: "Image is blurry. Hold still and check camera focus.") }
        return try predict(rgb)
    }

    public func predict(_ rgb: [Float]) throws -> [Float] {
        try SFaceTensorContract.validateInput(rgb)
        let tensor = try MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32)
        for i in rgb.indices { tensor[i] = NSNumber(value: rgb[i]) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(multiArray: tensor)])
        let output = try load().prediction(from: provider)
        return try SFaceTensorContract.normalizedOutput(output.featureValue(for: "embedding"))
    }

    private func align(_ image: CIImage, face: VNFaceObservation) throws -> CIImage {
        guard let landmarks = face.landmarks, let eye1 = landmarks.leftEye, let eye2 = landmarks.rightEye,
              let nose = landmarks.noseCrest, let lips = landmarks.outerLips else {
            throw FaceQualityError(reason: "Eyes, nose, and mouth must be visible. Remove obstructions and face the camera.")
        }
        func points(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
            region.normalizedPoints.map {
                FaceAlignment.imagePoint($0, boundingBox: face.boundingBox, extent: image.extent)
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
        let (transform, residual) = try FaceAlignment.transform(source: source, extent: image.extent)
        lastQualityMetrics?.alignmentResidual = residual
        guard residual <= 5 else { throw FaceQualityError(reason: "Face alignment is poor. Look toward the camera.") }
        return image.transformed(by: transform).cropped(to: CGRect(x: 0, y: 0, width: 112, height: 112))
    }
}
