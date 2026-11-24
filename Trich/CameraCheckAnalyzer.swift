import AVFoundation
import Vision

/// Looks for a face and a hand while Check Camera is open, about four times a second.
/// Every frame still goes on to `next` (detection). Only two yes/no answers leave this class.
///
/// Unchecked Sendable: frame state lives on the camera's video queue.
final class CameraCheckAnalyzer: NSObject, CameraManagerDelegate, @unchecked Sendable {
    weak var next: CameraManagerDelegate?

    private static let interval: TimeInterval = 0.25
    private static let minimumConfidence: Float = 0.5

    private let onReading: @Sendable (_ face: Bool, _ hand: Bool) -> Void
    private var lastAnalysis: TimeInterval = 0
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        // The same model revision as detection, so the check doesn't load a second one.
        request.revision = VNDetectHumanHandPoseRequestRevision1
        request.maximumHandCount = 2
        return request
    }()

    /// `onReading` is called on the main thread.
    init(onReading: @escaping @Sendable (_ face: Bool, _ hand: Bool) -> Void) {
        self.onReading = onReading
        super.init()
    }

    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        next?.cameraManager(manager, didOutput: sampleBuffer)

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAnalysis >= Self.interval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard (try? handler.perform([faceRequest, handRequest])) != nil else { return }
        let face = !(faceRequest.results ?? []).isEmpty
        let hand = (handRequest.results ?? []).contains { $0.confidence > Self.minimumConfidence }
        let onReading = onReading
        DispatchQueue.main.async { onReading(face, hand) }
    }
}
