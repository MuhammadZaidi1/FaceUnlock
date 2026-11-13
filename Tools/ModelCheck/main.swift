import CoreImage
import FaceModel
import Foundation
import RecognitionCore

// Synthetic non-face inputs only: tests real weight execution, not identity accuracy.
// Never prints or saves model output vectors.
do {
    if CommandLine.arguments.contains("--require-app-bundle"), Bundle.main.bundleURL.pathExtension != "app" {
        throw RecognitionError.modelUnavailable
    }
    if CommandLine.arguments.contains("--require-app-bundle") {
        print("Checking bundle resources at: \(Bundle.main.resourceURL?.path ?? "none")")
    }
    let bottom = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 112, height: 56))
    let top = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 56, width: 112, height: 56))
    var bytes = [UInt8](repeating: 0, count: 112 * 112 * 4)
    CIContext().render(top.composited(over: bottom), toBitmap: &bytes, rowBytes: 112 * 4,
                       bounds: CGRect(x: 0, y: 0, width: 112, height: 112), format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
    guard bytes[0] < 15, bytes[1] > 240, bytes[(111 * 112) * 4] > 240 else {
        throw RecognitionError.invalidEmbedding
    }
    print("PASS: Core Image row orientation / RGB preprocessing contract.")
    let model = SFaceModel()
    let count = 3 * 112 * 112
    let gradient = (0..<count).map { Float(($0 * 37 + $0 / 112) % 256) }
    let checker = (0..<count).map { Float(($0 / 8 % 2) * 200 + 20) }
    let first = try model.predict(gradient)
    let repeated = try model.predict(gradient)
    let different = try model.predict(checker)
    guard first.count == 128,
          try Embedding.cosine(first, repeated) > 0.99999,
          try Embedding.cosine(first, different) < 0.9999 else {
        throw RecognitionError.modelUnavailable
    }
    print("PASS: real SFace Core ML inference; 128 finite dimensions, deterministic and input-dependent. No camera or Keychain used.")
} catch {
    fputs("FAIL: real SFace inference unavailable: \(error.localizedDescription)\n", stderr)
    exit(1)
}
