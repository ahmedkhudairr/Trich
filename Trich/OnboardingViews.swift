import Cocoa

// Onboarding's drawn pieces. Everything is vector: Core Animation shape layers or AppKit
// drawing at the window's backing scale, never a scaled bitmap. Ambient motion is slow,
// runs at a low frame rate, and pauses whenever the window is hidden or not key.

// MARK: - Ambient motion

/// Slow, low-frame-rate motion that can be paused as a group.
@MainActor
enum Ambient {
    /// A few slow breaths that start and end at `from`, so the layer rests there with no snap.
    /// 15 fps is plenty for a 5 second breath and keeps the GPU nearly idle.
    static func breathe(_ keyPath: String, from: Any, to: Any, period: Double, breaths: Float) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = period / 2
        animation.autoreverses = true
        animation.repeatCount = breaths
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15)
        return animation
    }

    static func pause(_ layer: CALayer) {
        guard layer.speed != 0 else { return }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = now
    }

    static func resume(_ layer: CALayer) {
        guard layer.speed == 0 else { return }
        let paused = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
    }
}

/// A view whose layers are its own (not AppKit's backing layer), so they can be paused and
/// kept at the screen's scale.
class LayerHostView: NSView {
    let root = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(root)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        layoutLayers()
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        func apply(_ layer: CALayer) {
            layer.contentsScale = scale
            if layer.shouldRasterize { layer.rasterizationScale = scale }
            layer.sublayers?.forEach(apply)
        }
        apply(root)
    }

    func layoutLayers() {}
    func setRunning(_ running: Bool) { running ? Ambient.resume(root) : Ambient.pause(root) }
}

// MARK: - The living tt. mark

/// The app icon drawn live from its vector paths: the tile, a soft cobalt glow and the tt.
/// It assembles itself once, takes a few slow breaths, and hops its dot when something good happens.
final class LivingMark: LayerHostView {
    private let side: CGFloat
    private let halo = CAShapeLayer()
    private let tile = CALayer()
    private let fill = CAGradientLayer()
    private let tileMask = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let group = CALayer()
    private let glow = CAShapeLayer()
    private let parts = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private let haloOpacity: Float = TrichStyle.isDark ? 0.45 : 0.3

    init(side: CGFloat) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true

        let cobalt = TrichStyle.cobalt.cgColor
        halo.fillColor = TrichStyle.charcoal.cgColor
        halo.shadowColor = cobalt
        halo.shadowOffset = .zero
        halo.shadowRadius = side * 0.16
        halo.shadowOpacity = haloOpacity

        fill.colors = [NSColor(srgbRed: 0x1A / 255.0, green: 0x1B / 255.0, blue: 0x1F / 255.0, alpha: 1).cgColor,
                       NSColor(srgbRed: 0x11 / 255.0, green: 0x12 / 255.0, blue: 0x15 / 255.0, alpha: 1).cgColor]
        fill.startPoint = CGPoint(x: 0.5, y: 1)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        tile.mask = tileMask
        rim.fillColor = nil
        rim.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        rim.lineWidth = 2

        glow.fillColor = cobalt
        glow.shadowColor = cobalt
        glow.shadowOffset = .zero
        glow.shadowRadius = side * 0.05
        glow.shadowOpacity = 1
        glow.opacity = 0.45
        glow.shouldRasterize = true
        parts.forEach { $0.fillColor = cobalt }

        root.addSublayer(halo)
        root.addSublayer(tile)
        tile.addSublayer(fill)
        tile.addSublayer(group)
        tile.addSublayer(rim)
        group.addSublayer(glow)
        parts.forEach(group.addSublayer)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutLayers() {
        let k = side / TrichMark.tileBox.width
        var t = CGAffineTransform(translationX: 0, y: side).scaledBy(x: k, y: -k)
            .translatedBy(x: -TrichMark.tileBox.minX, y: -TrichMark.tileBox.minY)
        let tilePath = TrichMark.tile.copy(using: &t)
        for layer in [tile, fill, group, glow, rim, halo, tileMask] + parts { layer.frame = root.bounds }
        tileMask.path = tilePath
        rim.path = tilePath
        halo.path = tilePath
        halo.shadowPath = tilePath
        glow.path = TrichMark.glyph.copy(using: &t)
        glow.shadowPath = glow.path
        for (layer, path) in zip(parts, TrichMark.glyphs) { layer.path = path.copy(using: &t) }
    }

    /// The mark builds itself: tile, then each t rises, then the dot lands and the glow warms up.
    func playEntrance() {
        guard !TrichStyle.reduceMotion else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = 0.3
            root.add(fade, forKey: "enter")
            startBreathing(after: 0.3)
            return
        }
        let now = CACurrentMediaTime()
        func enter(_ layer: CALayer, delay: Double, rise: CGFloat, bounce: Double = 0, duration: Double = 0.55) {
            let move = TrichMotion.spring("transform.translation.y", from: rise, to: 0, duration: duration, bounce: bounce)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.2
            for animation in [move, fade] as [CAAnimation] {
                animation.beginTime = now + delay
                animation.fillMode = .backwards
                layer.add(animation, forKey: animation === move ? "rise" : "fade")
            }
        }
        let scale = TrichMotion.spring("transform.scale", from: 0.92, to: 1, duration: 0.6, bounce: 0.1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = 0.25
        for animation in [scale, fade] as [CAAnimation] { tile.add(animation, forKey: nil); halo.add(animation, forKey: nil) }
        enter(parts[0], delay: 0.12, rise: -side * 0.2)
        enter(parts[1], delay: 0.2, rise: -side * 0.2)
        enter(parts[2], delay: 0.36, rise: side * 0.3, bounce: 0.15, duration: 0.6)
        let warm = CABasicAnimation(keyPath: "opacity")
        warm.fromValue = 0
        warm.toValue = glow.opacity
        warm.duration = 0.9
        warm.beginTime = now + 0.5
        warm.fillMode = .backwards
        glow.add(warm, forKey: "warm")
        startBreathing(after: 1.4)
    }

    /// Fades in already built, for every mark after the first in a session.
    func fadeIn() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = 0.2
        root.add(fade, forKey: "enter")
        startBreathing(after: 0.2)
    }

    /// Three slow breaths, then rest: the tt. grows a hair and its glow swells every 5 seconds.
    func startBreathing(after delay: Double = 0) {
        guard !TrichStyle.reduceMotion else { return }
        let begin = CACurrentMediaTime() + delay
        let grow = Ambient.breathe("transform.scale", from: 1, to: 1.025, period: 5, breaths: 3)
        let swell = Ambient.breathe("opacity", from: 0.45, to: 0.85, period: 5, breaths: 3)
        let haloSwell = Ambient.breathe("shadowOpacity", from: haloOpacity, to: haloOpacity * 1.6, period: 5, breaths: 3)
        for (layer, animation) in [(group, grow), (glow, swell), (halo, haloSwell)] as [(CALayer, CABasicAnimation)] {
            animation.beginTime = begin
            layer.add(animation, forKey: "breathe")
        }
    }

    /// Breathes again once a rest has begun, for example when the pointer moves.
    func breatheIfRested() {
        guard group.animation(forKey: "breathe") == nil else { return }
        startBreathing()
    }

    /// The dot hops once and the glow flares, for a finished step.
    func celebrate() {
        guard !TrichStyle.reduceMotion else { return }
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, side * 0.1, 0, side * 0.03, 0]
        hop.keyTimes = [0, 0.35, 0.65, 0.82, 1]
        hop.duration = 0.6
        hop.timingFunctions = [TrichStyle.ease, TrichStyle.easeIn, TrichStyle.ease, TrichStyle.easeIn]
        parts[2].add(hop, forKey: "hop")
        let flare = CABasicAnimation(keyPath: "shadowRadius")
        flare.fromValue = side * 0.09
        flare.toValue = side * 0.05
        flare.duration = 0.9
        flare.timingFunction = TrichStyle.ease
        glow.add(flare, forKey: "flare")
    }

    /// Follows the pointer by a point or two, for a sense of depth.
    func lean(_ offset: CGPoint) {
        guard !TrichStyle.reduceMotion else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        CATransaction.setAnimationTimingFunction(TrichStyle.ease)
        group.setAffineTransform(CGAffineTransform(translationX: offset.x * 1.5, y: offset.y * 1.5))
        halo.setAffineTransform(CGAffineTransform(translationX: -offset.x * 2, y: -offset.y * 2))
        CATransaction.commit()
    }
}

// MARK: - Ambient light

/// One soft cobalt light behind the content. It drifts away from the pointer, so the glass in
/// front of it feels like it has depth.
final class AmbientLight: LayerHostView {
    private let light = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let strength: CGFloat = TrichStyle.isDark ? 0.16 : 0.09
        light.type = .radial
        light.colors = [TrichStyle.cobalt.withAlphaComponent(strength).cgColor,
                        TrichStyle.cobalt.withAlphaComponent(strength * 0.35).cgColor,
                        TrichStyle.cobalt.withAlphaComponent(0).cgColor]
        light.locations = [0, 0.45, 1]
        light.startPoint = CGPoint(x: 0.5, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(light)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutLayers() {
        let size: CGFloat = 640
        light.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        light.position = CGPoint(x: 140, y: bounds.height - 120)
    }

    func drift(_ offset: CGPoint) {
        guard !TrichStyle.reduceMotion else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.2)
        CATransaction.setAnimationTimingFunction(TrichStyle.ease)
        light.setAffineTransform(CGAffineTransform(translationX: -offset.x * 10, y: -offset.y * 10))
        CATransaction.commit()
    }
}

// MARK: - Headline

/// A step title. A short one-line title builds word by word, each word rising inside its own
/// clip. Longer or wrapping titles stay a plain label. Body text never builds.
final class Headline: NSView {
    private var words: [NSView] = []

    init(_ text: String, font: NSFont, color: NSColor, width: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        let parts = text.split(separator: " ").map(String.init)
        let fits = NSAttributedString(string: text, attributes: [.font: font]).size().width < width - 8
        if parts.count <= 7 && fits {
            let row = NSStackView()
            row.spacing = 0
            row.alignment = .firstBaseline
            for (index, word) in parts.enumerated() {
                let label = NSTextField(labelWithString: index < parts.count - 1 ? word + " " : word)
                label.font = font
                label.textColor = color
                label.setAccessibilityElement(false)
                label.wantsLayer = true
                let clip = NSView()
                clip.wantsLayer = true
                clip.layer?.masksToBounds = true
                clip.setAccessibilityElement(false)
                label.translatesAutoresizingMaskIntoConstraints = false
                clip.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                    label.topAnchor.constraint(equalTo: clip.topAnchor),
                    label.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
                ])
                row.addArrangedSubview(clip)
                words.append(label)
            }
            pin(row)
        } else {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.textColor = color
            label.isSelectable = false
            label.setAccessibilityElement(false)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            pin(label)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func pin(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Words rise 12 pt inside their clips, 60 ms apart. Returns when the last word starts,
    /// so what follows can wait for it. Without word build it returns `begin`.
    @discardableResult
    func build(at begin: CFTimeInterval) -> CFTimeInterval {
        guard !words.isEmpty, !TrichStyle.reduceMotion else { return begin }
        for (index, word) in words.enumerated() {
            guard let layer = word.layer else { continue }
            let start = begin + Double(index) * 0.06
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            // The clip is an unflipped view, so its layer's y runs up: start 12 pt low.
            rise.fromValue = -12
            rise.toValue = 0
            rise.duration = 0.45
            rise.timingFunction = TrichStyle.ease
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.3
            fade.timingFunction = TrichStyle.ease
            for animation in [rise, fade] as [CAAnimation] {
                animation.beginTime = start
                animation.fillMode = .backwards
            }
            layer.add(rise, forKey: "rise")
            layer.add(fade, forKey: "fade")
        }
        return begin + Double(words.count - 1) * 0.06
    }
}

// MARK: - Success check

/// A cobalt dot that grows into a check: detection is on.
final class SuccessCheck: LayerHostView {
    private let disc = CAShapeLayer()
    private let check = CAShapeLayer()

    init(side: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        disc.fillColor = TrichStyle.cobalt.cgColor
        check.fillColor = nil
        check.strokeColor = NSColor.white.cgColor
        check.lineCap = .round
        check.lineJoin = .round
        root.addSublayer(disc)
        root.addSublayer(check)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutLayers() {
        let w = bounds.width
        disc.frame = root.bounds
        disc.path = CGPath(ellipseIn: root.bounds, transform: nil)
        check.frame = root.bounds
        check.lineWidth = w * 0.08
        let path = CGMutablePath()
        path.move(to: CGPoint(x: w * 0.29, y: w * 0.51))
        path.addLine(to: CGPoint(x: w * 0.44, y: w * 0.36))
        path.addLine(to: CGPoint(x: w * 0.72, y: w * 0.64))
        check.path = path
    }

    /// Settles onto the mark's corner: scale 0.9 to 1 with no bounce, or a fade with Reduce Motion.
    func settle() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = TrichStyle.reduceMotion ? 0.2 : 0.24
        fade.timingFunction = TrichStyle.ease
        root.add(fade, forKey: "enter")
        guard !TrichStyle.reduceMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.9
        scale.toValue = 1
        scale.duration = 0.24
        scale.timingFunction = TrichStyle.ease
        root.add(scale, forKey: "settle")
    }

    func play() {
        let now = CACurrentMediaTime()
        if TrichStyle.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = 0.2
            root.add(fade, forKey: "enter")
            return
        }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.18
        grow.toValue = 1
        grow.duration = 0.4
        grow.timingFunction = TrichStyle.ease
        disc.add(grow, forKey: "grow")
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.24
        draw.beginTime = now + 0.22
        draw.fillMode = .backwards
        draw.timingFunction = TrichStyle.ease
        check.add(draw, forKey: "draw")
    }
}

// MARK: - Frosted card

/// A pane of frosted glass: a faint fill, a hairline edge and a brighter top edge where light
/// catches it. Solid when Reduce Transparency is on.
class GlassCard: NSView {
    private let sheen = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        sheen.cornerRadius = 14
        sheen.cornerCurve = .continuous
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.6)
        layer?.addSublayer(sheen)
        restyle(selected: false, hover: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheen.frame = bounds
        CATransaction.commit()
    }

    func restyle(selected: Bool, hover: Bool) {
        let dark = TrichStyle.isDark
        let base = TrichStyle.surface
        let fillColor: NSColor = selected
            ? TrichStyle.cobalt.withAlphaComponent(dark ? 0.16 : 0.08)
            : hover ? (dark ? NSColor.white.withAlphaComponent(0.06) : TrichStyle.cobalt.withAlphaComponent(0.03)) : base
        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = (selected ? TrichStyle.cobalt : TrichStyle.hairline).cgColor
        layer?.borderWidth = selected ? 1.5 : 1
        let glint = TrichStyle.reduceTransparency ? 0 : (dark ? 0.05 : 0.6)
        sheen.colors = [NSColor.white.withAlphaComponent(glint).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        if !dark { layer?.shadowColor = TrichStyle.cobalt.cgColor; layer?.shadowOpacity = 0.06; layer?.shadowRadius = 8; layer?.shadowOffset = CGSize(width: 0, height: -2) }
    }
}

// MARK: - Zone cards

/// A minimal face on a 24-unit grid: head, ears, dot eyes, and one area (beard, eyebrows or
/// scalp). The area is a soft tint, and the head outline turns cobalt where it bounds it.
final class FaceDrawing: NSView {
    let zone: PullZone
    var selected = false {
        didSet {
            guard selected != oldValue else { return }
            if window != nil, !TrichStyle.reduceMotion, let layer {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.22
                fade.timingFunction = TrichStyle.ease
                layer.add(fade, forKey: "select")
            }
            needsDisplay = true
        }
    }

    init(zone: PullZone) {
        self.zone = zone
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 72).isActive = true
        heightAnchor.constraint(equalToConstant: 84).isActive = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static let stroke: CGFloat = 1.25

    private static func shape(_ build: (CGMutablePath) -> Void) -> CGPath {
        let path = CGMutablePath()
        build(path)
        return path
    }

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private static let head = shape {
        $0.move(to: p(12, 3.5))
        $0.addCurve(to: p(19, 11.2), control1: p(16.6, 3.5), control2: p(19, 6.9))
        $0.addCurve(to: p(12, 20.5), control1: p(19, 16.7), control2: p(15.9, 20.5))
        $0.addCurve(to: p(5, 11.2), control1: p(8.1, 20.5), control2: p(5, 16.7))
        $0.addCurve(to: p(12, 3.5), control1: p(5, 6.9), control2: p(7.4, 3.5))
        $0.closeSubpath()
    }

    private static let ears = shape {
        $0.move(to: p(5, 11.3))
        $0.addCurve(to: p(3.3, 12.7), control1: p(3.9, 10.9), control2: p(3.1, 11.6))
        $0.addCurve(to: p(5.25, 14.2), control1: p(3.5, 13.8), control2: p(4.3, 14.4))
        $0.move(to: p(19, 11.3))
        $0.addCurve(to: p(20.7, 12.7), control1: p(20.1, 10.9), control2: p(20.9, 11.6))
        $0.addCurve(to: p(18.75, 14.2), control1: p(20.5, 13.8), control2: p(19.7, 14.4))
    }

    private static let eyes = shape {
        $0.addEllipse(in: CGRect(x: 8.45, y: 10.95, width: 1.9, height: 1.9))
        $0.addEllipse(in: CGRect(x: 13.65, y: 10.95, width: 1.9, height: 1.9))
    }

    private static let brows = shape {
        $0.move(to: p(7.7, 9.85))
        $0.addCurve(to: p(11.1, 9.2), control1: p(8.7, 9), control2: p(9.9, 8.8))
        $0.move(to: p(12.9, 9.2))
        $0.addCurve(to: p(16.3, 9.85), control1: p(14.1, 8.8), control2: p(15.3, 9))
    }

    /// Hair above a soft hairline; drawn clipped to the head.
    private static let scalpArea = shape {
        $0.move(to: p(5.1, 10.4))
        $0.addCurve(to: p(12, 7.6), control1: p(5.9, 8.2), control2: p(8.6, 7.6))
        $0.addCurve(to: p(18.9, 10.4), control1: p(15.4, 7.6), control2: p(18.1, 8.2))
        $0.addLine(to: p(19.5, 2))
        $0.addLine(to: p(4.5, 2))
        $0.closeSubpath()
    }

    /// The crown of the head outline, from temple to temple.
    private static let scalpEdge = shape {
        $0.move(to: p(5.03, 10.4))
        $0.addCurve(to: p(12, 3.5), control1: p(5.31, 6.49), control2: p(7.69, 3.5))
        $0.addCurve(to: p(18.97, 10.4), control1: p(16.31, 3.5), control2: p(18.69, 6.49))
    }

    /// Beard below a mustache line; drawn clipped to the head.
    private static let beardArea = shape {
        $0.move(to: p(5.15, 13.6))
        $0.addCurve(to: p(9.6, 15.7), control1: p(5.9, 15.3), control2: p(7.6, 16))
        $0.addCurve(to: p(12, 15.3), control1: p(10.7, 15.5), control2: p(11.3, 15.3))
        $0.addCurve(to: p(14.4, 15.7), control1: p(12.7, 15.3), control2: p(13.3, 15.5))
        $0.addCurve(to: p(18.85, 13.6), control1: p(16.4, 16), control2: p(18.1, 15.3))
        $0.addLine(to: p(19.5, 22))
        $0.addLine(to: p(4.5, 22))
        $0.closeSubpath()
    }

    /// The jaw of the head outline, from cheek to cheek.
    private static let beardEdge = shape {
        $0.move(to: p(18.79, 13.6))
        $0.addCurve(to: p(12, 20.5), control1: p(18.03, 17.77), control2: p(15.3, 20.5))
        $0.addCurve(to: p(5.21, 13.6), control1: p(8.7, 20.5), control2: p(5.97, 17.77))
    }

    private static let mouth = shape {
        $0.move(to: p(10.7, 17.6))
        $0.addCurve(to: p(13.3, 17.6), control1: p(11.6, 17.95), control2: p(12.4, 17.95))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = TrichStyle.isDark
        let line = TrichStyle.muted
        let accent = selected ? TrichStyle.cobalt : line
        let tint = selected ? TrichStyle.cobalt.withAlphaComponent(dark ? 0.34 : 0.30)
                            : line.withAlphaComponent(0.32)

        // Center the 24-unit grid in the view.
        let scale = min(bounds.width, bounds.height) / 24
        context.translateBy(x: (bounds.width - 24 * scale) / 2, y: (bounds.height - 24 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.setLineWidth(Self.stroke)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        func stroke(_ path: CGPath, _ color: NSColor, width: CGFloat = FaceDrawing.stroke) {
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.strokePath()
        }

        let area: CGPath? = zone == .scalp ? Self.scalpArea : zone == .beard ? Self.beardArea : nil
        if let area {
            context.saveGState()
            context.addPath(Self.head)
            context.clip()
            context.addPath(area)
            context.setFillColor(tint.cgColor)
            context.fillPath()
            context.restoreGState()
        }

        stroke(Self.head, line)
        stroke(Self.ears, line)
        switch zone {
        case .scalp: stroke(Self.scalpEdge, accent)
        case .beard: stroke(Self.beardEdge, accent)
        case .brows: stroke(Self.brows, accent, width: Self.stroke * 1.4)
        }

        // The mouth is cut through the beard so the card shows behind it.
        if zone == .beard {
            context.saveGState()
            context.setBlendMode(.clear)
            stroke(Self.mouth, .black)
            context.restoreGState()
        }

        context.addPath(Self.eyes)
        context.setFillColor(line.cgColor)
        context.fillPath()
    }
}

/// A pressable card for one pulling area. Behaves like a checkbox for keyboard and VoiceOver.
final class ZoneCard: NSButton {
    let zone: PullZone
    private(set) var isOn = false
    private let glass = GlassCard()
    private let ring = CAShapeLayer()
    private let face: FaceDrawing
    private let badge = NSView()
    private let tick = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private var hovering = false

    init(zone: PullZone, note: String, scale: CGFloat) {
        self.zone = zone
        face = FaceDrawing(zone: zone)
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        focusRingType = .exterior
        setButtonType(.momentaryChange)

        titleLabel.stringValue = zone.title
        titleLabel.font = TrichFont.ui(round(14 * scale), weight: .semibold)
        titleLabel.alignment = .center
        noteLabel.stringValue = note
        noteLabel.font = TrichFont.ui(round(12 * scale))
        noteLabel.alignment = .center
        noteLabel.isSelectable = false

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 10
        tick.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        tick.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        tick.contentTintColor = .white

        for view in [glass, face, badge, titleLabel, noteLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        tick.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(tick)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            face.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            face.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20),
            tick.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            tick.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: face.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            noteLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            noteLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            noteLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            noteLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
        ])
        glass.layer?.cornerCurve = .circular
        ring.fillColor = nil
        ring.strokeColor = TrichStyle.cobalt.cgColor
        ring.lineWidth = 1.5
        layer?.addSublayer(ring)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(zone.title)
        setAccessibilityHelp(note)
        setOn(false, animated: false)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 13.25, cornerHeight: 13.25, transform: nil)
        ring.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setOn(_ on: Bool, animated: Bool) {
        isOn = on
        face.selected = on
        titleLabel.textColor = TrichStyle.text
        noteLabel.textColor = TrichStyle.muted
        badge.layer?.backgroundColor = (on ? TrichStyle.cobalt : NSColor.clear).cgColor
        // Muted ring and, in light mode, a cobalt edge, so an unticked card still reads as a control
        badge.layer?.borderColor = TrichStyle.muted.cgColor
        badge.layer?.borderWidth = on ? 0 : 1.5
        tick.isHidden = !on
        glass.restyle(selected: on, hover: hovering)
        glass.layer?.borderColor = Self.edge.cgColor
        glass.layer?.borderWidth = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.isHidden = !on
        ring.strokeEnd = 1
        CATransaction.commit()
        setAccessibilityValue(on ? 1 : 0)
        guard animated, on, let layer = badge.layer, !TrichStyle.reduceMotion else { return }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.duration = 0.24
        draw.timingFunction = TrichStyle.ease
        ring.add(draw, forKey: "draw")
        layer.add(TrichMotion.spring("transform", from: TrichMotion.scale(0.9, in: layer),
                                     to: CATransform3DIdentity, duration: 0.24, bounce: 0.1), forKey: "pop")
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; restyleHover() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyleHover() }
    private func restyleHover() {
        glass.restyle(selected: isOn, hover: hovering)
        glass.layer?.borderColor = Self.edge.cgColor
        glass.layer?.borderWidth = 1
    }
    private static var edge: NSColor {
        TrichStyle.isDark ? TrichStyle.hairline : TrichStyle.cobalt.withAlphaComponent(0.5)
    }

    override func mouseDown(with event: NSEvent) {
        TrichMotion.press(self, down: true)
        super.mouseDown(with: event)
        TrichMotion.press(self, down: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

// MARK: - Reminder preview with a live Shift practice

/// A small drawing of the reminder, laid out like the real one: the three lines, the two
/// Shift keycaps with the ring between them, and a prompt. While the practice step is open,
/// the keycaps light as the real Shift keys go down, and the ring fills over 3 seconds.
final class ReminderPreview: NSView {
    private let left: Keycap
    private let right: Keycap
    private let ring = HoldRing()
    private let prompt = NSTextField(labelWithString: "")
    private let scale: CGFloat

    init(scale: CGFloat) {
        self.scale = scale
        left = Keycap(text: "left ⇧", scale: scale)
        right = Keycap(text: "right ⇧", scale: scale)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Preview of a reminder: Relax your hands. Hold both Shift keys for 3 seconds. Or wait 15 seconds.")
        setAccessibilityHelp("Try it here: hold both Shift keys.")

        let screen = NSView()
        screen.wantsLayer = true
        screen.layer?.backgroundColor = TrichStyle.reminder.cgColor
        screen.layer?.cornerRadius = 14
        screen.layer?.cornerCurve = .continuous
        let lines = NSStackView()
        lines.orientation = .vertical
        lines.alignment = .centerX
        lines.spacing = 2
        for (text, size, weight) in [("Relax your hands.", 17.0, NSFont.Weight.semibold),
                                     ("Hold both Shift keys for 3 seconds.", 17, .semibold),
                                     ("Or wait 15 seconds.", 17, .semibold)] as [(String, CGFloat, NSFont.Weight)] {
            let label = NSTextField(labelWithString: text)
            label.font = TrichFont.ui(round(size * scale), weight: weight)
            label.textColor = .white
            lines.addArrangedSubview(label)
        }
        let keys = NSStackView(views: [left, ring, right])
        keys.spacing = 16
        keys.alignment = .centerY
        prompt.font = TrichFont.ui(round(12 * scale), weight: .medium)
        prompt.wantsLayer = true
        prompt.textColor = .white
        prompt.alignment = .center

        for view in [screen, lines, keys, prompt] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
        }
        addSubview(screen)
        screen.addSubview(lines)
        screen.addSubview(keys)
        screen.addSubview(prompt)
        NSLayoutConstraint.activate([
            screen.leadingAnchor.constraint(equalTo: leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: trailingAnchor),
            screen.topAnchor.constraint(equalTo: topAnchor),
            lines.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            lines.topAnchor.constraint(equalTo: screen.topAnchor, constant: 24),
            keys.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            keys.topAnchor.constraint(equalTo: lines.bottomAnchor, constant: 16),
            prompt.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            prompt.topAnchor.constraint(equalTo: keys.bottomAnchor, constant: 8),
            prompt.heightAnchor.constraint(equalToConstant: ceil(16 * scale)),
            prompt.bottomAnchor.constraint(equalTo: screen.bottomAnchor, constant: -16),
            screen.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Lights the keycaps and sets the prompt the way the real reminder does.
    func show(left l: Bool, right r: Bool) {
        left.setDown(l)
        right.setDown(r)
        switch (l, r) {
        case (true, false): setPrompt("Now hold right ⇧ too.")
        case (false, true): setPrompt("Now hold left ⇧ too.")
        case (true, true): setPrompt("Keep holding.")
        default: setPrompt("")
        }
    }

    /// Swaps the prompt in place with a short crossfade.
    private func setPrompt(_ text: String) {
        guard prompt.stringValue != text else { return }
        if !TrichStyle.reduceMotion, let layer = prompt.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            layer.add(fade, forKey: "swap")
        }
        prompt.stringValue = text
    }

    func startHold(seconds: Double) { ring.fill(over: seconds) }
    func cancelHold() { ring.empty() }
    func holdTick(_ second: Int) { ring.step(to: second) }

    /// The full ring holds for a beat, then keys and ring resolve into one check.
    /// `onResolved` runs on that frame, for the sound and haptic.
    func finishHold(onResolved: @escaping () -> Void) {
        ring.complete()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.left.setDown(false)
            self.right.setDown(false)
            self.ring.resolve()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = TrichStyle.reduceMotion ? 0.15 : 0.3
                context.timingFunction = TrichStyle.ease
                self.left.animator().alphaValue = 0.35
                self.right.animator().alphaValue = 0.35
            }
            self.setPrompt("That's it.")
            onResolved()
        }
    }
}

final class Keycap: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String, scale: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        label.stringValue = text
        label.font = TrichFont.ui(round(13 * scale), weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: round(84 * scale)),
            heightAnchor.constraint(equalToConstant: round(36 * scale)),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setDown(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Lit keys are cobalt with a white edge, so the state never rests on color alone.
    /// Instant, because a key going down is the person's own action.
    func setDown(_ down: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = (down ? TrichStyle.cobalt : NSColor.white.withAlphaComponent(0.1)).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(down ? 1 : 0.45).cgColor
        layer?.borderWidth = down ? 2 : 1
        CATransaction.commit()
    }
}

/// White ring on a faint track, filling clockwise from 12 o'clock.
final class HoldRing: LayerHostView {
    private let track = CAShapeLayer()
    private let bar = CAShapeLayer()
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        for (layer, alpha) in [(track, 0.25), (bar, 1.0)] {
            layer.fillColor = nil
            layer.strokeColor = NSColor.white.withAlphaComponent(alpha).cgColor
            layer.lineWidth = 3
            layer.lineCap = .round
            root.addSublayer(layer)
        }
        bar.strokeEnd = 0
        count.font = TrichFont.ui(11, weight: .semibold, tabular: true)
        count.textColor = .white
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(count)
        count.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        count.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutLayers() {
        let circle = CGMutablePath()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        circle.addArc(center: center, radius: bounds.width / 2 - 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for layer in [track, bar] { layer.frame = root.bounds; layer.path = circle }
    }

    func fill(over seconds: Double) {
        count.stringValue = ""
        guard !TrichStyle.reduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = bar.presentation()?.strokeEnd ?? 0
        animation.toValue = 1
        animation.duration = seconds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.strokeEnd = 1
        CATransaction.commit()
        bar.add(animation, forKey: "fill")
    }

    /// Reduce Motion: the ring jumps a third each second and shows the count.
    func step(to second: Int) {
        guard TrichStyle.reduceMotion else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.strokeEnd = CGFloat(second) / 3
        CATransaction.commit()
        count.stringValue = second > 0 && second < 3 ? "\(second)" : ""
    }

    func empty() {
        count.stringValue = ""
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = bar.presentation()?.strokeEnd ?? bar.strokeEnd
        animation.toValue = 0
        animation.duration = TrichStyle.reduceMotion ? 0 : 0.2
        animation.timingFunction = TrichStyle.ease
        bar.removeAnimation(forKey: "fill")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.strokeEnd = 0
        CATransaction.commit()
        bar.add(animation, forKey: "empty")
    }

    func complete() {
        count.stringValue = ""
        bar.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.strokeEnd = 1
        CATransaction.commit()
    }

    /// The ring gives way to a white check, drawn in 300 ms.
    func resolve() {
        let duration = TrichStyle.reduceMotion ? 0.15 : 0.3
        let check = CAShapeLayer()
        let path = CGMutablePath()
        let w = bounds.width
        path.move(to: CGPoint(x: w * 0.3, y: w * 0.52))
        path.addLine(to: CGPoint(x: w * 0.44, y: w * 0.37))
        path.addLine(to: CGPoint(x: w * 0.71, y: w * 0.64))
        check.path = path
        check.fillColor = nil
        check.strokeColor = NSColor.white.cgColor
        check.lineWidth = 3
        check.lineCap = .round
        check.lineJoin = .round
        check.frame = root.bounds
        check.contentsScale = window?.backingScaleFactor ?? 2
        root.addSublayer(check)
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = TrichStyle.reduceMotion ? 1 : 0
        draw.duration = duration
        draw.timingFunction = TrichStyle.ease
        check.add(draw, forKey: "draw")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = TrichStyle.ease
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.opacity = 0
        bar.opacity = 0
        CATransaction.commit()
        track.add(fade, forKey: "fade")
        bar.add(fade, forKey: "fade")
    }
}

// MARK: - Menu bar drawing

/// A drawn strip of a menu bar with Trich's icon ringed in cobalt.
final class MenuBarStrip: GlassCard {
    init(scale: CGFloat) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("The menu bar, with Trich's tt. icon near the clock.")

        func symbol(_ name: String) -> NSImageView {
            let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
            view.symbolConfiguration = .init(pointSize: round(14 * scale), weight: .regular)
            view.contentTintColor = TrichStyle.muted
            return view
        }
        let mark = NSImageView(image: MenuBarIcon.image(.active, accessibilityDescription: ""))
        mark.contentTintColor = TrichStyle.text
        let ring = NSView()
        ring.wantsLayer = true
        ring.layer?.borderColor = TrichStyle.cobalt.cgColor
        ring.layer?.borderWidth = 2
        ring.layer?.cornerRadius = 7
        ring.layer?.cornerCurve = .continuous
        let clock = NSTextField(labelWithString: "Mon 9:41")
        clock.font = TrichFont.ui(round(13 * scale), weight: .medium)
        clock.textColor = TrichStyle.muted
        let items = NSStackView(views: [symbol("wifi"), symbol("battery.75percent"), mark, clock])
        items.spacing = 16
        items.alignment = .centerY

        for view in [items, ring] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [items, ring, mark, clock] as [NSView] { view.setAccessibilityElement(false) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: round(48 * scale)),
            items.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            items.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            ring.widthAnchor.constraint(equalTo: mark.widthAnchor, constant: 16),
            ring.heightAnchor.constraint(equalToConstant: round(28 * scale)),
        ])
        // The ring settles around the icon once, pointing the eye to it.
        if !TrichStyle.reduceMotion {
            ring.wantsLayer = true
            DispatchQueue.main.async { [weak ring] in
                guard let layer = ring?.layer else { return }
                let settle = TrichMotion.spring("transform", from: TrichMotion.scale(1.12, in: layer),
                                                to: CATransform3DIdentity, duration: 0.5, bounce: 0)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.duration = 0.3
                let begin = CACurrentMediaTime() + 0.25
                for animation in [settle, fade] as [CAAnimation] {
                    animation.beginTime = begin
                    animation.fillMode = .backwards
                    layer.add(animation, forKey: nil)
                }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}
