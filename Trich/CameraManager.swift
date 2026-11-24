import AVFoundation
import CoreVideo
import os

// Receives raw sample buffers for analysis. Kept as a class-bound protocol
// so CameraManager can hold a weak reference and avoid retain cycles
protocol CameraManagerDelegate: AnyObject {
    /// Called on `CameraManager.videoQueue`
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer)
}

/// A camera the app could use, reduced to what the choice depends on.
struct CameraCandidate: Equatable {
    enum Kind { case builtIn, external, continuity }

    let id: String
    let name: String
    let kind: Kind
    let isSuspended: Bool

    /// The camera to use: the user's pick if it's usable, else the built-in camera,
    /// else an external one. An iPhone (Continuity Camera) is only used when picked.
    static func choose(from candidates: [CameraCandidate], preferredID: String?) -> CameraCandidate? {
        let usable = candidates.filter { !$0.isSuspended }
        if let preferredID, let preferred = usable.first(where: { $0.id == preferredID }) { return preferred }
        return usable.first { $0.kind == .builtIn } ?? usable.first { $0.kind == .external }
    }
}

/// Owns a single capture session for the app's lifetime.
/// `start()` / `stop()` can be called any number of times; the camera (and its
/// green light) is fully off whenever the session is stopped.
///
/// Availability is reported through `onAvailabilityChange`:
/// - `true` once frames arrive after a start,
/// - `false` when there is no usable camera, it fails, or it stops sending frames
///   for `stallTimeout` (lid closed, privacy shutter, camera wedged after wake).
///
/// Unchecked Sendable: mutable state is confined to `sessionQueue`, except the
/// frame clock, which is shared with `videoQueue` under a lock.
final class CameraManager: NSObject, @unchecked Sendable {

    /// Read only on `videoQueue`, where frames arrive. Change it with `setDelegate(_:)`.
    private weak var delegate: CameraManagerDelegate?

    /// Swaps the frame receiver on `videoQueue`, so a frame never reads it mid-write.
    func setDelegate(_ newDelegate: CameraManagerDelegate?) {
        videoQueue.async { [self, weak newDelegate] in delegate = newDelegate }
    }

    /// Called on the main thread when a camera appears or disappears
    var onAvailabilityChange: ((Bool) -> Void)?

    /// Frames are delivered and analysed on this queue
    let videoQueue = DispatchQueue(label: "io.github.ahmedkhudairr.trich.video", qos: .utility)

    /// No frames for this long while running counts as "camera unavailable"
    static let stallTimeout: TimeInterval = 8
    private static let watchdogInterval: TimeInterval = 2

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()

    // startRunning/stopRunning block for a while. Keep them off the main thread,
    // and serialized so a quick on→off→on can never leave the camera running
    private let sessionQueue = DispatchQueue(label: "io.github.ahmedkhudairr.trich.session")

    private var wantsRunning = false          // sessionQueue only
    private var isOutputAdded = false         // sessionQueue only
    private var hasRetriedAfterError = false  // sessionQueue only
    private var reportsFailures = true        // sessionQueue only; false during a quiet `retry()`
    private var preferredCameraID: String?    // sessionQueue only
    private var cameraState: Set<String> = []  // sessionQueue only; the cameras seen last
    private var watchdog: DispatchSourceTimer?

    private struct FrameClock {
        var lastFrame: TimeInterval = 0
        var awaitingFirstFrame = false
    }
    private let frameClock = OSAllocatedUnfairLock(initialState: FrameClock())

    // Detection analyses about 10 frames a second (ScanPacer), so ask for the slowest
    // rate at or above that. Many Mac cameras can't go below 15 fps.
    private static let targetFrameRate: Float64 = 10

    // Lower resolution means fewer pixels for Vision to process
    private static let presets: [AVCaptureSession.Preset] = [.medium, .vga640x480, .high]

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(devicesChanged),
                           name: AVCaptureDevice.wasConnectedNotification, object: nil)
        center.addObserver(self, selector: #selector(devicesChanged),
                           name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionRuntimeError),
                           name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    func start() {
        sessionQueue.async { [self] in
            wantsRunning = true
            reportsFailures = true
            guard !session.isRunning else { return }
            hasRetriedAfterError = false
            run()
        }
    }

    /// Tries the camera again while the app already shows it as unavailable.
    /// Reports `true` once frames arrive; a failure is not reported again.
    func retry() {
        sessionQueue.async { [self] in
            guard !session.isRunning else { return }
            wantsRunning = true
            reportsFailures = false
            run()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            wantsRunning = false
            stopSession()
        }
    }

    /// Uses this camera when it's available (nil = automatic: built-in first).
    func selectCamera(id: String?) {
        sessionQueue.async { [self] in
            guard preferredCameraID != id else { return }
            preferredCameraID = id
            if wantsRunning { run() }
        }
    }

    /// Cameras offered for choosing, built-in first. Desk View is never listed.
    static func availableCameras() -> [CameraCandidate] {
        discoverDevices().map(candidate(for:)).sorted { $0.kind == .builtIn && $1.kind != .builtIn }
    }

    // MARK: - Running (sessionQueue only)

    /// Makes sure the session runs on the right camera, then waits for frames.
    private func run() {
        let devices = Self.discoverDevices()
        cameraState = Self.fingerprint(devices)
        guard let choice = CameraCandidate.choose(from: devices.map(Self.candidate(for:)),
                                                  preferredID: preferredCameraID),
              let device = devices.first(where: { $0.uniqueID == choice.id }),
              configure(for: device)
        else { return fail() }

        if !session.isRunning {
            let now = ProcessInfo.processInfo.systemUptime
            frameClock.withLock { $0 = FrameClock(lastFrame: now, awaitingFirstFrame: true) }
            session.startRunning()
            guard session.isRunning else { return fail() }
        }
        armWatchdog()
    }

    /// Stops the camera and says so, unless this was a quiet retry.
    private func fail() {
        stopSession()
        if reportsFailures {
            reportAvailability(false)
        } else {
            wantsRunning = false
        }
    }

    private func stopSession() {
        watchdog?.cancel()
        watchdog = nil
        if session.isRunning { session.stopRunning() }
    }

    private func framesStarted() {
        guard wantsRunning, session.isRunning else { return }
        hasRetriedAfterError = false
        reportsFailures = true
        reportAvailability(true)
    }

    private func armWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval,
                       leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.checkFrames() }
        timer.resume()
        watchdog = timer
    }

    private func checkFrames() {
        guard wantsRunning else { return stopSession() }
        let lastFrame = frameClock.withLock { $0.lastFrame }
        let stalled = ProcessInfo.processInfo.systemUptime - lastFrame >= Self.stallTimeout
        if stalled || !session.isRunning { fail() }
    }

    // MARK: - Configuration (sessionQueue only)

    private static func discoverDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video, position: .unspecified
        ).devices
    }

    /// Each camera and whether it is suspended (lid closed, privacy shutter).
    private static func fingerprint(_ devices: [AVCaptureDevice]) -> Set<String> {
        Set(devices.map { "\($0.uniqueID) \($0.isSuspended)" })
    }

    // Without the Info.plist opt-in, an iPhone reports itself as a built-in wide-angle camera
    private static func candidate(for device: AVCaptureDevice) -> CameraCandidate {
        let kind: CameraCandidate.Kind
        if device.isContinuityCamera {
            kind = .continuity
        } else if device.deviceType == .builtInWideAngleCamera {
            kind = .builtIn
        } else {
            kind = .external
        }
        return CameraCandidate(id: device.uniqueID, name: device.localizedName,
                               kind: kind, isSuspended: device.isSuspended)
    }

    /// Makes sure the session reads from `device`. Returns false if it can't.
    private func configure(for device: AVCaptureDevice) -> Bool {
        let currentInput = session.inputs.first as? AVCaptureDeviceInput
        if let currentInput, currentInput.device.uniqueID == device.uniqueID, isOutputAdded { return true }

        // Center Stage zooms and pans to follow the person, which moves the frame the zones
        // were tuned on. This only applies to Trich; other apps keep the person's setting.
        if AVCaptureDevice.centerStageControlMode != .app {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let currentInput { session.removeInput(currentInput) }

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)

        if let preset = Self.presets.first(where: session.canSetSessionPreset) {
            session.sessionPreset = preset
        }

        if !isOutputAdded {
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            // Discard late frames rather than building up a backlog on the processing queue
            videoOutput.alwaysDiscardsLateVideoFrames = true
            guard session.canAddOutput(videoOutput) else { return false }
            session.addOutput(videoOutput)
            isOutputAdded = true
        }

        setFrameRate(on: device)
        return true
    }

    private func setFrameRate(on device: AVCaptureDevice) {
        guard let duration = Self.frameDuration(for: device.activeFormat.videoSupportedFrameRateRanges.map {
            (min: $0.minFrameRate, max: $0.maxFrameRate, longest: $0.maxFrameDuration)
        }), (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    /// The frame duration for the slowest supported rate at or above `targetFrameRate`,
    /// or nil when every range is slower than that.
    static func frameDuration(for ranges: [(min: Float64, max: Float64, longest: CMTime)]) -> CMTime? {
        ranges.compactMap { range -> (rate: Float64, duration: CMTime)? in
            guard range.max >= targetFrameRate else { return nil }
            return range.min >= targetFrameRate
                ? (range.min, range.longest)
                : (targetFrameRate, CMTime(value: 1, timescale: CMTimeScale(targetFrameRate)))
        }
        .min { $0.rate < $1.rate }?.duration
    }

    private func reportAvailability(_ available: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onAvailabilityChange?(available)
        }
    }

    // MARK: - Camera plugged in / unplugged / failed

    @objc private func devicesChanged() {
        sessionQueue.async { [self] in
            // Not running (e.g. "no camera" state): say when a usable camera exists now,
            // so the app can start again when one is plugged in
            guard wantsRunning else {
                // Microphones and headphones post this too. Only a change in cameras counts,
                // so a wedged camera isn't reported as back when AirPods connect.
                let devices = Self.discoverDevices()
                let state = Self.fingerprint(devices)
                guard state != cameraState else { return }
                cameraState = state
                let candidates = devices.map(Self.candidate(for:))
                if CameraCandidate.choose(from: candidates, preferredID: preferredCameraID) != nil {
                    reportAvailability(true)
                }
                return
            }
            run()
        }
    }

    @objc private func sessionRuntimeError() {
        // Try once to recover (e.g. the camera was reset); report if that fails
        sessionQueue.async { [self] in
            guard wantsRunning, !hasRetriedAfterError else { return fail() }
            hasRetriedAfterError = true
            stopSession()
            run()
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let isFirstFrame = frameClock.withLock { clock in
            clock.lastFrame = now
            defer { clock.awaitingFirstFrame = false }
            return clock.awaitingFirstFrame
        }
        if isFirstFrame { sessionQueue.async { [self] in framesStarted() } }
        delegate?.cameraManager(self, didOutput: sampleBuffer)
    }
}
