import Foundation
import Vision

// The detection rule, kept free of the camera so it can run on recorded video.
// PoseDetector feeds it live frames.

// MARK: - Settings

/// Where someone pulls. Raw values are stored in settings and history, so never rename them.
enum PullZone: String, CaseIterable, Sendable {
    case beard, brows, scalp

    var title: String {
        switch self {
        case .beard: return "Beard"
        case .brows: return "Eyebrows"
        case .scalp: return "Scalp"
        }
    }

    /// "your beard", for status lines.
    var phrase: String {
        switch self {
        case .beard: return "beard"
        case .brows: return "eyebrows"
        case .scalp: return "scalp"
        }
    }

    /// Joins zones in display order: "beard", "beard and scalp", "beard, eyebrows and scalp".
    static func phrase(for zones: Set<PullZone>) -> String {
        let words = allCases.filter(zones.contains).map(\.phrase)
        guard let last = words.last else { return "" }
        return words.count == 1 ? last : words.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// How eager detection is. Medium is the tuned default.
enum Sensitivity: String, CaseIterable, Sendable {
    case low, medium, high

    var title: String { rawValue.capitalized }
}

/// The zones and sensitivity the user picked. Takes its defaults so tests can use a private suite.
struct DetectionSettings {
    static let zonesKey = "pullZones"
    static let sensitivityKey = "sensitivity"

    let defaults: UserDefaults

    /// Missing, empty or unreadable means beard only, which is how Trich worked before zones.
    var zones: Set<PullZone> {
        get {
            let raw = (defaults.array(forKey: Self.zonesKey) ?? []).compactMap { $0 as? String }
            let zones = Set(raw.compactMap(PullZone.init(rawValue:)))
            return zones.isEmpty ? [.beard] : zones
        }
        nonmutating set {
            // An explicit list, so a zone added later is never switched on behind the user's back.
            let kept = newValue.isEmpty ? [.beard] : newValue
            defaults.set(PullZone.allCases.filter(kept.contains).map(\.rawValue), forKey: Self.zonesKey)
        }
    }

    /// True once the user has seen the zone choice: onboarding's areas step, the menu's
    /// one-time line about it, or a pick. People from before zones existed start false.
    var hasChosenZones: Bool { defaults.object(forKey: Self.zonesKey) != nil }

    var sensitivity: Sensitivity {
        get { Sensitivity(rawValue: defaults.string(forKey: Self.sensitivityKey) ?? "") ?? .medium }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.sensitivityKey) }
    }
}

// MARK: - Readings

/// One hand joint in Vision's normalized image space (origin bottom left).
struct JointReading {
    let location: CGPoint
    let confidence: Float
}

/// One hand, as plain values.
struct HandReading {
    /// Thumb, index, middle, ring, little. Each runs from the tip inwards:
    /// tip, DIP, PIP (thumb: tip, IP, MP). Nil where Vision has no point.
    let fingers: [[JointReading?]]

    static let chains: [[VNHumanHandPoseObservation.JointName]] = [
        [.thumbTip, .thumbIP, .thumbMP],
        [.indexTip, .indexDIP, .indexPIP],
        [.middleTip, .middleDIP, .middlePIP],
        [.ringTip, .ringDIP, .ringPIP],
        [.littleTip, .littleDIP, .littlePIP],
    ]

    init(fingers: [[JointReading?]]) {
        self.fingers = fingers
    }

    init(_ observation: VNHumanHandPoseObservation) {
        let points = (try? observation.recognizedPoints(.all)) ?? [:]
        fingers = Self.chains.map { chain in
            chain.map { joint in
                points[joint].map { JointReading(location: $0.location, confidence: $0.confidence) }
            }
        }
    }

    var tips: [JointReading] { fingers.compactMap { $0.first ?? nil } }
}

/// The face landmarks detection uses, converted to normalized image space.
struct FaceReading {
    let box: CGRect
    let contour: [CGPoint]
    let nose: [CGPoint]
    let outerLips: [CGPoint]
    let leftEyebrow: [CGPoint]
    let rightEyebrow: [CGPoint]
    let leftEye: [CGPoint]
    let rightEye: [CGPoint]

    init(box: CGRect, contour: [CGPoint] = [], nose: [CGPoint] = [], outerLips: [CGPoint] = [],
         leftEyebrow: [CGPoint] = [], rightEyebrow: [CGPoint] = [], leftEye: [CGPoint] = [], rightEye: [CGPoint] = []) {
        self.box = box
        self.contour = contour
        self.nose = nose
        self.outerLips = outerLips
        self.leftEyebrow = leftEyebrow
        self.rightEyebrow = rightEyebrow
        self.leftEye = leftEye
        self.rightEye = rightEye
    }

    init(_ observation: VNFaceObservation) {
        let box = observation.boundingBox
        let landmarks = observation.landmarks
        func image(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.normalizedPoints ?? []).map {
                CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height)
            }
        }
        self.init(box: box,
                  contour: image(landmarks?.faceContour), nose: image(landmarks?.nose),
                  outerLips: image(landmarks?.outerLips),
                  leftEyebrow: image(landmarks?.leftEyebrow), rightEyebrow: image(landmarks?.rightEyebrow),
                  leftEye: image(landmarks?.leftEye), rightEye: image(landmarks?.rightEye))
    }

    /// If several people are in view, the one closest to the camera.
    static func largest(_ faces: [VNFaceObservation]) -> FaceReading? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
            .map(FaceReading.init)
    }
}

// MARK: - Rule

/// Per zone and sensitivity: how close a finger must be, and for how long.
struct ZoneTuning {
    /// Distance from the nearest zone point, in face widths
    var radius: CGFloat
    /// Alert when hits have lasted this long. Detection analyses about 10 frames a second,
    /// so 0.1 s is two frames in a row and 0 is one frame.
    var confirmTime: TimeInterval
    /// How long a face may be reused when Vision loses it (a hand over the eyes hides the whole face)
    var faceHold: TimeInterval
    /// 1: every analysed frame must hit. Below 1: this share of the frames in the last `window`
    /// seconds must hit, for fingers that Vision loses on some frames, as in hair
    var share: Double = 1
    var window: TimeInterval = 0
    /// Scalp: one sure fingertip counts within this share of the radius (0: two fingers needed)
    var singleFingerReach: CGFloat = 0

    static func `default`(_ zone: PullZone, _ sensitivity: Sensitivity) -> ZoneTuning {
        switch (zone, sensitivity) {
        case (.beard, .low):    return ZoneTuning(radius: 0.20, confirmTime: 0.2, faceHold: 0.5)
        case (.beard, .medium): return ZoneTuning(radius: 0.25, confirmTime: 0.1, faceHold: 0.5)
        case (.beard, .high):   return ZoneTuning(radius: 0.32, confirmTime: 0.1, faceHold: 0.5)
        // Glasses rims sit on the brows, so only a longer stay rules out adjusting them
        case (.brows, .low):    return ZoneTuning(radius: 0.10, confirmTime: 0.9, faceHold: 2)
        case (.brows, .medium): return ZoneTuning(radius: 0.14, confirmTime: 0.2, faceHold: 2)
        case (.brows, .high):   return ZoneTuning(radius: 0.18, confirmTime: 0.1, faceHold: 2)
        // A head resting on a hand looks like a scalp touch for its first half second. Fingers
        // in hair drop out on some frames, so Medium needs half the frames in 0.8 s and High
        // 60% of the frames in 0.5 s.
        case (.scalp, .low):
            return ZoneTuning(radius: 0.18, confirmTime: 0.4, faceHold: 2)
        case (.scalp, .medium):
            return ZoneTuning(radius: 0.22, confirmTime: 0.4, faceHold: 2, share: 0.5, window: 0.8, singleFingerReach: 0.5)
        case (.scalp, .high):
            return ZoneTuning(radius: 0.28, confirmTime: 0.2, faceHold: 2, share: 0.6, window: 0.5, singleFingerReach: 0.5)
        }
    }
}

/// Decides, frame by frame, which zones a hand is touching.
///
/// A finger counts by its most distal joint Vision is reasonably sure about, because
/// fingertips buried in hair are often unsure while the knuckles stay clear.
/// Distances are measured in face widths with true pixel proportions, so the zones
/// stay the same size near or far from the camera, on 4:3 or 16:9 frames.
struct PullRule {
    var zones: Set<PullZone> = [.beard]
    var sensitivity: Sensitivity = .medium {
        didSet { tuning = Self.tuning(for: sensitivity) }
    }
    private(set) var tuning: [PullZone: ZoneTuning] = PullRule.tuning(for: .medium)

    static let contactConfidence: Float = 0.3
    /// Brows and scalp only count a knuckle this sure, since a hand near the head often lies flat
    static let knuckleConfidence: Float = 0.5
    static let tipConfidence: Float = 0.5
    /// Room around the zones that still counts as near when deciding whether a fresh face is needed
    static let faceCacheMargin: CGFloat = 0.35

    static func tuning(for sensitivity: Sensitivity) -> [PullZone: ZoneTuning] {
        Dictionary(uniqueKeysWithValues: PullZone.allCases.map { ($0, ZoneTuning.default($0, sensitivity)) })
    }

    /// Tries other values without touching the defaults.
    mutating func override(_ zone: PullZone, _ change: (inout ZoneTuning) -> Void) {
        change(&tuning[zone]!)
    }

    struct Contact {
        let point: CGPoint
        let finger: Int
        let isTip: Bool
        let confidence: Float
    }

    /// Each finger's most distal joint above `contactConfidence`.
    static func contacts(_ hand: HandReading) -> [Contact] {
        hand.fingers.enumerated().compactMap { finger, chain in
            for (index, joint) in chain.enumerated() {
                if let joint, joint.confidence > contactConfidence {
                    return Contact(point: joint.location, finger: finger, isTip: index == 0, confidence: joint.confidence)
                }
            }
            return nil
        }
    }

    /// Converts normalized points to a space where x and y are both in frame heights.
    struct Space {
        let aspect: CGFloat     // frame width / height
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * aspect, y: p.y) }
        func faceWidth(_ face: FaceReading) -> CGFloat { max(face.box.width * aspect, 0.0001) }
    }

    /// Zone points in `Space`, for one face.
    static func points(_ zone: PullZone, face: FaceReading, space: Space) -> [CGPoint] {
        switch zone {
        case .beard: return beardPoints(face).map(space.point)
        case .brows: return (face.leftEyebrow + face.rightEyebrow).map(space.point)
        case .scalp: return scalpPoints(face, space: space)
        }
    }

    /// The jaw below the top of the lips, the lips themselves and the chin. Cutting at the lips,
    /// not the nose, keeps hands at the ears and glasses out.
    static func beardPoints(_ face: FaceReading) -> [CGPoint] {
        let box = face.box
        guard let chin = face.contour.min(by: { $0.y < $1.y }) else {
            // No jawline found: the lower part of the face box
            return [
                CGPoint(x: box.midX - box.width * 0.35, y: box.minY + box.height * 0.3),
                CGPoint(x: box.midX - box.width * 0.2, y: box.minY + box.height * 0.12),
                CGPoint(x: box.midX, y: box.minY + box.height * 0.05),
                CGPoint(x: box.midX + box.width * 0.2, y: box.minY + box.height * 0.12),
                CGPoint(x: box.midX + box.width * 0.35, y: box.minY + box.height * 0.3),
            ]
        }
        let lipTop = face.outerLips.map(\.y).max()
            ?? face.nose.map(\.y).min()
            ?? box.minY + box.height * 0.35
        return face.contour.filter { $0.y < lipTop } + face.outerLips + [chin]
    }

    /// Vision has no scalp landmarks, so these are estimated from the face box, turned with
    /// the eye line: hairline, temples and top of the head, in face widths from the box centre.
    static let scalpOffsets: [CGPoint] = [
        CGPoint(x: -0.45, y: 0.72), CGPoint(x: 0.45, y: 0.72),
        CGPoint(x: -0.22, y: 0.82), CGPoint(x: 0.22, y: 0.82), CGPoint(x: 0, y: 0.86),
        CGPoint(x: -0.62, y: 0.45), CGPoint(x: 0.62, y: 0.45),
        CGPoint(x: -0.25, y: 1.0), CGPoint(x: 0.25, y: 1.0), CGPoint(x: 0, y: 1.05),
    ]

    static func scalpPoints(_ face: FaceReading, space: Space) -> [CGPoint] {
        let width = space.faceWidth(face)
        let centre = space.point(CGPoint(x: face.box.midX, y: face.box.midY))
        var tilt: CGFloat = 0
        if let left = mean(face.leftEye), let right = mean(face.rightEye) {
            let l = space.point(left), r = space.point(right)
            // Measured left to right across the image, whichever eye Vision calls left
            let sign: CGFloat = l.x >= r.x ? 1 : -1
            tilt = atan2(sign * (l.y - r.y), sign * (l.x - r.x))
        }
        let c = cos(tilt), s = sin(tilt)
        return scalpOffsets.map { o in
            CGPoint(x: centre.x + (o.x * c - o.y * s) * width, y: centre.y + (o.x * s + o.y * c) * width)
        }
    }

    static func mean(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let n = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }

    /// A hand is at the eyes, glasses, nose or cheek, not the beard, when a sure fingertip is
    /// above the bottom of the nose, or most of its fingers are above the top lip. Its other
    /// fingers may still rest on the jaw.
    static func isAboveBeard(_ hand: HandReading, face: FaceReading) -> Bool {
        let noseBottom = face.nose.map(\.y).min() ?? face.box.minY + face.box.height * 0.4
        let margin = face.box.width * 0.3
        let reachesAboveNose = hand.tips.contains { tip in
            tip.confidence > tipConfidence && tip.location.y > noseBottom
                && tip.location.x > face.box.minX - margin && tip.location.x < face.box.maxX + margin
        }
        guard !reachesAboveNose else { return true }
        let lipTop = face.outerLips.map(\.y).max() ?? noseBottom
        let contacts = contacts(hand)
        return contacts.filter { $0.point.y > lipTop }.count * 2 > contacts.count
    }

    /// Zones this frame touches, each with its nearest finger distance in face widths.
    func hits(hands: [HandReading], face: FaceReading, aspect: CGFloat, zones only: Set<PullZone>? = nil) -> [PullZone: CGFloat] {
        let space = Space(aspect: aspect)
        let width = space.faceWidth(face)
        var result: [PullZone: CGFloat] = [:]
        for zone in PullZone.allCases where zones.contains(zone) && (only?.contains(zone) ?? true) {
            let points = Self.points(zone, face: face, space: space)
            guard !points.isEmpty, let radius = tuning[zone]?.radius else { continue }
            let singleFingerRadius = radius * (tuning[zone]?.singleFingerReach ?? 0)
            let browPoints = zone == .scalp ? Self.points(.brows, face: face, space: space) : []
            for hand in hands {
                if zone == .beard && Self.isAboveBeard(hand, face: face) { continue }
                var near: [(contact: Contact, distance: CGFloat)] = []
                for contact in Self.contacts(hand) {
                    if zone != .beard && !contact.isTip && contact.confidence <= Self.knuckleConfidence { continue }
                    let d = Self.distance(contact, to: points, space: space) / width
                    if d < radius { near.append((contact, d)) }
                }
                let enough: Bool
                switch zone {
                case .beard: enough = !near.isEmpty
                // Thumb or index alone (the pinching fingers), or any two
                case .brows: enough = near.contains { $0.contact.finger <= 1 } || near.count >= 2
                // Any two, or one sure fingertip (a one-finger twirl) well inside the zone and
                // nearer the hair than the brows, since one finger on the forehead looks the same
                case .scalp: enough = near.count >= 2 || near.contains { contact, distance in
                    contact.isTip && contact.confidence > Self.tipConfidence && distance < singleFingerRadius
                        && distance < Self.distance(contact, to: browPoints, space: space) / width
                }
                }
                guard enough, let closest = near.map(\.distance).min() else { continue }
                result[zone] = min(result[zone] ?? .infinity, closest)
            }
        }
        return result
    }

    static func distance(_ contact: Contact, to points: [CGPoint], space: Space) -> CGFloat {
        let p = space.point(contact.point)
        return points.map { hypot(p.x - $0.x, p.y - $0.y) }.min() ?? .infinity
    }

    /// False when every finger is well away from every enabled zone around `face`,
    /// so a fresh face reading can't change the answer.
    func couldHit(hands: [HandReading], face: FaceReading, aspect: CGFloat) -> Bool {
        let space = Space(aspect: aspect)
        let width = space.faceWidth(face)
        let contacts = hands.flatMap(Self.contacts).map { space.point($0.point) }
        for zone in zones {
            guard let radius = tuning[zone]?.radius else { continue }
            let reach = (radius + Self.faceCacheMargin) * width
            for point in Self.points(zone, face: face, space: space) {
                if contacts.contains(where: { hypot($0.x - point.x, $0.y - point.y) < reach }) { return true }
            }
        }
        return false
    }
}

// MARK: - Confirmation

/// Times each zone's hits across analysed frames and says when one should alert.
struct PullConfirmer {
    // Frame clocks jitter by a few ms, so a run this much short of the time still counts
    static let jitter: TimeInterval = 0.02
    // How far back distances are kept for choosing between zones
    static let memory: TimeInterval = 1.0

    private struct Frame {
        let time: TimeInterval
        let distance: CGFloat?
    }

    // Unbroken runs (share 1)
    private var runStart: [PullZone: TimeInterval] = [:]
    // Every analysed frame within `memory`, per zone
    private var recent: [PullZone: [Frame]] = [:]

    mutating func reset() {
        runStart = [:]
        recent = [:]
    }

    /// Records one analysed frame. Returns the zone to alert for, if any.
    mutating func update(_ hits: [PullZone: CGFloat], tuning: [PullZone: ZoneTuning],
                         at now: TimeInterval) -> PullZone? {
        var ready: [PullZone: TimeInterval] = [:]
        for zone in PullZone.allCases {
            var frames = recent[zone, default: []].filter { now - $0.time < Self.memory }
            frames.append(Frame(time: now, distance: hits[zone]))
            recent[zone] = frames
            guard let t = tuning[zone], hits[zone] != nil else {
                runStart[zone] = nil
                continue
            }
            let start = runStart[zone] ?? now
            runStart[zone] = start
            if t.share >= 1 {
                if now - start + Self.jitter >= t.confirmTime { ready[zone] = start }
            } else {
                let inWindow = frames.filter { now - $0.time < t.window - Self.jitter }
                let hitTimes = inWindow.filter { $0.distance != nil }.map(\.time)
                let first = hitTimes.min() ?? now
                if Double(hitTimes.count) >= t.share * Double(inWindow.count),
                   now - first + Self.jitter >= t.confirmTime {
                    ready[zone] = first
                }
            }
        }
        guard !ready.isEmpty else { return nil }
        let winner = likeliestZone(Set(ready.keys).union(hits.keys), tuning: tuning, at: now)
        reset()
        return winner
    }

    /// Where a hand sits between two zones (the forehead lies between brows and hairline),
    /// both can hit, and the one with the shorter confirmation would always win. Instead,
    /// over the longest confirmation among `candidates`, the zone hit on the most frames
    /// wins, then the one the fingers sat deepest inside.
    private func likeliestZone(_ candidates: Set<PullZone>, tuning: [PullZone: ZoneTuning],
                               at now: TimeInterval) -> PullZone? {
        let span = candidates.compactMap { tuning[$0].map { max($0.confirmTime, $0.window) } }.max() ?? 0
        let scored = PullZone.allCases.filter(candidates.contains).compactMap { zone -> (PullZone, Int, CGFloat)? in
            guard let radius = tuning[zone]?.radius else { return nil }
            let depths = recent[zone, default: []]
                .filter { now - $0.time <= span + Self.jitter }
                .compactMap { $0.distance.map { $0 / radius } }
            guard !depths.isEmpty else { return nil }
            return (zone, depths.count, depths.reduce(0, +) / CGFloat(depths.count))
        }
        return scored.min { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }?.0
    }
}

// MARK: - Tracker

/// Everything one camera needs between frames: the rule, the confirmation counts and the
/// last face. PoseDetector runs one live.
struct PullTracker {
    var rule = PullRule() {
        didSet { confirmer.reset() }
    }
    private var confirmer = PullConfirmer()
    private var lastFace: FaceReading?
    private var lastFaceTime: TimeInterval = -.infinity
    private var lastPassFoundFace = false

    // Where the head was recently, so the face pass can be skipped while hands are visible
    // but nowhere near it, as when typing
    static let faceCacheLifetime: TimeInterval = 1.0

    /// What the last call did, for inspection
    private(set) var ranFacePass = false
    private(set) var lastHits: [PullZone: CGFloat] = [:]

    mutating func reset() {
        confirmer.reset()
        lastFace = nil
        lastFaceTime = -.infinity
        lastPassFoundFace = false
        lastHits = [:]
    }

    /// One analysed frame. `findFace` runs the face pass and is only called when needed.
    /// Returns the zone to alert for, if this frame completes a confirmation.
    mutating func update(hands: [HandReading], aspect: CGFloat, at now: TimeInterval,
                         findFace: () -> FaceReading?) -> PullZone? {
        ranFacePass = false
        lastHits = [:]
        guard hands.contains(where: { !PullRule.contacts($0).isEmpty }) else { return confirm([:], at: now) }

        if lastPassFoundFace, let face = lastFace, now - lastFaceTime < Self.faceCacheLifetime,
           !rule.couldHit(hands: hands, face: face, aspect: aspect) {
            return confirm([:], at: now)
        }

        ranFacePass = true
        var hits: [PullZone: CGFloat] = [:]
        if let face = findFace() {
            lastFace = face
            lastFaceTime = now
            lastPassFoundFace = true
            hits = rule.hits(hands: hands, face: face, aspect: aspect)
        } else if let held = lastFace {
            // A hand over the face can hide it. Reuse the last one for zones that allow it.
            lastPassFoundFace = false
            let age = now - lastFaceTime
            let allowed = Set(rule.zones.filter { (rule.tuning[$0]?.faceHold ?? 0) > age })
            if !allowed.isEmpty { hits = rule.hits(hands: hands, face: held, aspect: aspect, zones: allowed) }
        }
        lastHits = hits
        return confirm(hits, at: now)
    }

    /// The confirmation step alone. Lifecycle tests drive it without Vision.
    mutating func confirm(_ hits: [PullZone: CGFloat], at now: TimeInterval) -> PullZone? {
        confirmer.update(hits.filter { rule.zones.contains($0.key) }, tuning: rule.tuning, at: now)
    }
}
