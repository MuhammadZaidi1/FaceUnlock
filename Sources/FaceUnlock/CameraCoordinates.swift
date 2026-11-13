import ImageIO

/// Native upright macOS webcam buffers are not rotated or mirrored for Vision.
/// Mirroring belongs solely to the preview layer and must never flip pose gates.
enum CameraCoordinates {
    static let visionOrientation = CGImagePropertyOrientation.up
    static let captureMirrored = false
    static let previewMirrored = true
}
