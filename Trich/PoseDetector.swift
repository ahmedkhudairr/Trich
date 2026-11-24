import Vision
import AVFoundation

protocol PoseDetectorDelegate: AnyObject {
    /// Always called on the main thread
    func poseDetector(_ detector: PoseDetector, didDetectPullingAt zone: PullZone)
}

/// Decides which camera frames get analysed, about 10 a second at any camera rate:
/// while a hand was seen in the last `activeHold` or anything moved, else about 5 a
/// second. A hand can't enter view without moving, so at 10 fps it is analysed on the
/// frame it appears. Times are the frames' capture timestamps, which stay steady while
/// delivery times jitter.
struct ScanPacer {
    static let activeInterval: TimeInterval = 0.1
    // Still scene: worst case one frame (100 ms at 10 fps) before a new hand is analysed
    static let idleInterval: TimeInterval = 0.2
    static let activeHold: TimeInterval = 3.0
    // Frame clocks jitter by a few ms; a frame this early still counts as on time
    private static let jitter: TimeInterval = 0.01

    // When the last analysis was due. Trails the real time by at most half an interval,
    // so uneven frame gaps (15 fps gives 67 ms) still average out to the interval.
    private var lastDue: TimeInterval?
    private var lastHandSeen: TimeInterval?

    func isActive(at now: TimeInterval) -> Bool {
        guard let lastHandSeen else { return false }
        return now - lastHandSeen < Self.activeHold
    }

    /// True if the frame at `now` should be analysed; counts it as analysed.
    mutating func shouldAnalyze(at now: TimeInterval, moved: Bool) -> Bool {
        let interval = moved || isActive(at: now) ? Self.activeInterval : Self.idleInterval
        if let lastDue {
            let due = lastDue + interval
            guard now >= due - Self.jitter else { return false }
            self.lastDue = max(due, now - interval / 2)
        } else {
            lastDue = now
        }
        return true
    }

    mutating func noteHand(at now: TimeInterval) {
        lastHandSeen = now
    }
}

/// Tells whether anything moved since the previous frame, from a coarse grid of
/// brightness averages. Costs microseconds, so it runs on every frame. Unknown pixel
/// formats always count as movement, so they are never analysed less often.
struct MotionGate {
    static let columns = 24, rows = 18
    private static let samplesPerSide = 4
    // Brightness levels (of 255) a cell must change by; averaging 16 samples keeps
    // sensor noise well below this
    static let cellThreshold = 10
    static let movedCells = 2

    private var previous: [UInt8]?

    mutating func moved(in buffer: CVPixelBuffer) -> Bool {
        let grid = Self.brightnessGrid(of: buffer)
        defer { previous = grid }
        guard let grid, let previous, previous.count == grid.count else { return true }
        var changed = 0
        for index in grid.indices where abs(Int(grid[index]) - Int(previous[index])) >= Self.cellThreshold {
            changed += 1
            if changed >= Self.movedCells { return true }
        }
        return false
    }

    static func brightnessGrid(of buffer: CVPixelBuffer) -> [UInt8]? {
        // Where the luma byte sits: plane (nil = interleaved), bytes per pixel, offset
        let layout: (plane: Int?, step: Int, offset: Int)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            layout = (0, 1, 0)
        case kCVPixelFormatType_422YpCbCr8:      layout = (nil, 2, 1)  // 2vuy
        case kCVPixelFormatType_422YpCbCr8_yuvs: layout = (nil, 2, 0)
        case kCVPixelFormatType_32BGRA:         layout = (nil, 4, 1)  // green
        default:                                return nil
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base: UnsafeMutableRawPointer?, width: Int, height: Int, bytesPerRow: Int
        if let plane = layout.plane {
            base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        } else {
            base = CVPixelBufferGetBaseAddress(buffer)
            width = CVPixelBufferGetWidth(buffer)
            height = CVPixelBufferGetHeight(buffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        }
        guard let base, width > 0, height > 0 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        let n = samplesPerSide
        var grid = [UInt8]()
        grid.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var sum = 0
                for sy in 0..<n {
                    let y = (row * n + sy) * height / (rows * n)
                    for sx in 0..<n {
                        let x = (column * n + sx) * width / (columns * n)
                        sum += Int(bytes[y * bytesPerRow + x * layout.step + layout.offset])
                    }
                }
                grid.append(UInt8(sum / (n * n)))
            }
        }
        return grid
    }
}

/// All detection state lives on `queue` (the camera's frame queue), so no locking is needed.
/// Unchecked Sendable for the same reason.
final class PoseDetector: NSObject, @unchecked Sendable {

    weak var delegate: PoseDetectorDelegate?

    // After the overlay is dismissed, ignore detections for this long
    private static let cooldownDuration: TimeInterval = 5.0

    private let queue: DispatchQueue
    private var tracker = PullTracker()
    private var pacer = ScanPacer()
    private var motionGate = MotionGate()
    private var cooldownEnds: TimeInterval?
    private var isOverlayActive = false
    private var isEnabled = false
    private var generation = 0
    @MainActor private var requestedGeneration = 0

    // Reused across frames. Revisions are pinned so an OS update can't quietly shift
    // the confidences the thresholds were tuned on.
    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.revision = VNDetectHumanHandPoseRequestRevision1
        request.maximumHandCount = 2
        return request
    }()

    private let faceLandmarksRequest: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        return request
    }()

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    /// Invalidate queued callbacks immediately, then reset frame state on its own queue.
    @MainActor
    func setEnabled(_ enabled: Bool) {
        requestedGeneration += 1
        let newGeneration = requestedGeneration
        queue.async { [self] in
            generation = newGeneration
            isEnabled = enabled
            isOverlayActive = false
            cooldownEnds = nil
            tracker.reset()
            pacer = ScanPacer()
            motionGate = MotionGate()
        }
    }

    func setSensitivity(_ sensitivity: Sensitivity) {
        queue.async { self.tracker.rule.sensitivity = sensitivity }
    }

    func setZones(_ zones: Set<PullZone>) {
        queue.async { self.tracker.rule.zones = zones }
    }

    /// Called after the overlay is dismissed: ignore detections for a few seconds
    func startCooldown() {
        queue.async { [self] in
            cooldownEnds = ProcessInfo.processInfo.systemUptime + Self.cooldownDuration
            isOverlayActive = false
            tracker.reset()
        }
    }

    /// Called if a detection could not be shown: start watching again straight away
    func resume() {
        queue.async { [self] in
            isOverlayActive = false
            tracker.reset()
        }
    }
}

// MARK: - CameraManagerDelegate

extension PoseDetector: CameraManagerDelegate {

    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        guard isEnabled, !isOverlayActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let end = cooldownEnds {
            guard now >= end else { return }
            cooldownEnds = nil
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let captureTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let frameTime = captureTime.isFinite ? captureTime : now
        let moved = motionGate.moved(in: pixelBuffer)
        guard pacer.shouldAnalyze(at: frameTime, moved: moved) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        // Hands first: most frames have no hand near the head, and then the face pass is skipped.
        // Vision occasionally fails on low-contrast frames; that counts as a frame with no hand.
        let observations = (try? handler.perform([handPoseRequest])) != nil ? handPoseRequest.results ?? [] : []
        if !observations.isEmpty { pacer.noteHand(at: frameTime) }
        let hands = observations.map(HandReading.init)
        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(max(CVPixelBufferGetHeight(pixelBuffer), 1))

        let zone = tracker.update(hands: hands, aspect: aspect, at: frameTime) { [faceLandmarksRequest] in
            guard (try? handler.perform([faceLandmarksRequest])) != nil else { return nil }
            return FaceReading.largest(faceLandmarksRequest.results ?? [])
        }
        if let zone { alert(zone) }
    }

    /// Frame-queue confirmation step, also exercised without a camera in lifecycle tests.
    func process(_ hits: [PullZone: CGFloat], at now: TimeInterval) {
        guard isEnabled, !isOverlayActive else { return }
        if let zone = tracker.confirm(hits, at: now) { alert(zone) }
    }

    private func alert(_ zone: PullZone) {
        guard isEnabled, !isOverlayActive else { return }
        isOverlayActive = true
        let detectedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedGeneration == detectedGeneration else { return }
            self.delegate?.poseDetector(self, didDetectPullingAt: zone)
        }
    }
}
