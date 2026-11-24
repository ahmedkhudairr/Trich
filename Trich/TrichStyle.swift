import Cocoa
import AVFoundation

// MARK: - Palette and glass

/// Colors, materials and motion shared by onboarding, the dashboard and the menu bar icon.
/// One palette from the app icon. Dark: charcoal surfaces, off-white text. Light is the inverse:
/// white surfaces, charcoal text, cobalt frames and accents. Cobalt is never the color of small text.
@MainActor
enum TrichStyle {
    static let charcoal = NSColor(srgbRed: 0x15 / 255.0, green: 0x16 / 255.0, blue: 0x19 / 255.0, alpha: 1)
    static let offWhite = NSColor(srgbRed: 0xF1 / 255.0, green: 0xF2 / 255.0, blue: 0xF5 / 255.0, alpha: 1)
    static let cobalt = NSColor(srgbRed: 0x28 / 255.0, green: 0x78 / 255.0, blue: 0xF0 / 255.0, alpha: 1)
    static let reminder = NSColor(srgbRed: 0x17 / 255.0, green: 0x3D / 255.0, blue: 0x7A / 255.0, alpha: 1)
    private static let mutedDark = NSColor(srgbRed: 0x8F / 255.0, green: 0x93 / 255.0, blue: 0x9D / 255.0, alpha: 1)
    /// #8F939D is only 3:1 on white, so light mode darkens it to reach 6:1.
    private static let mutedLight = NSColor(srgbRed: 0x5C / 255.0, green: 0x60 / 255.0, blue: 0x6A / 255.0, alpha: 1)
    private static let surfaceDarkSolid = NSColor(srgbRed: 0x1E / 255.0, green: 0x20 / 255.0, blue: 0x25 / 255.0, alpha: 1)

    /// Test hook: renders the solid Reduce Transparency look without changing the system setting.
    static var forceReduceTransparency = false
    /// Test hook: renders the Reduce Motion behavior without changing the system setting.
    static var forceReduceMotion = false

    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    static var reduceTransparency: Bool {
        forceReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var reduceMotion: Bool { forceReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func background(dark: Bool) -> NSColor { dark ? charcoal : .white }
    static func text(dark: Bool) -> NSColor { dark ? offWhite : charcoal }
    static func muted(dark: Bool) -> NSColor { dark ? mutedDark : mutedLight }
    static func surface(dark: Bool) -> NSColor {
        if !dark { return .white }
        return reduceTransparency ? surfaceDarkSolid : NSColor.white.withAlphaComponent(0.03)
    }
    static func hairline(dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(increaseContrast ? 0.32 : 0.08)
             : cobalt.withAlphaComponent(increaseContrast ? 0.7 : 0.28)
    }

    static var background: NSColor { background(dark: isDark) }
    static var text: NSColor { text(dark: isDark) }
    static var muted: NSColor { muted(dark: isDark) }

    /// The base over the blur. At 94% the worst case desktop keeps muted text above 4.5:1 in both modes.
    static var glassTint: NSColor { background.withAlphaComponent(0.94) }
    /// The rail and other "around" areas: darker in dark mode, a cobalt wash in light mode.
    static var frameTint: NSColor {
        if isDark { return NSColor.black.withAlphaComponent(reduceTransparency ? 0 : 0.18) }
        return cobalt.withAlphaComponent(0.06)
    }
    static var surface: NSColor { surface(dark: isDark) }
    static var hairline: NSColor { hairline(dark: isDark) }
    static var track: NSColor {
        isDark ? NSColor.white.withAlphaComponent(increaseContrast ? 0.4 : 0.12)
               : cobalt.withAlphaComponent(increaseContrast ? 0.6 : 0.2)
    }
    static var selection: NSColor { isDark ? NSColor.white.withAlphaComponent(0.06) : cobalt.withAlphaComponent(0.1) }
    /// The primary button is the text color with the background color on it: 16:1 in both modes.
    static var pillFill: NSColor { text }
    static var pillText: NSColor { background }

    static let ease = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    /// Exits leave a little faster than things enter.
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
    /// Something already on screen moving to a new place.
    static let easeMove = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)

    /// Glass window: transparent title bar over a tinted blur, or solid with Reduce Transparency.
    /// Calls `onAppearanceChange` when light or dark mode switches, so the owner can rebuild.
    static func applyGlass(to window: NSWindow, onAppearanceChange: (() -> Void)? = nil) -> NSView {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        let root = AppearanceView()
        root.onChange = onAppearanceChange
        if reduceTransparency {
            window.isOpaque = true
            window.backgroundColor = background
        } else {
            window.isOpaque = false
            window.backgroundColor = .clear
            let blur = NSVisualEffectView()
            blur.material = isDark ? .hudWindow : .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            let tint = NSView()
            tint.wantsLayer = true
            tint.layer?.backgroundColor = glassTint.cgColor
            for layer in [blur, tint] {
                layer.translatesAutoresizingMaskIntoConstraints = false
                layer.setAccessibilityElement(false)
                root.addSubview(layer)
                NSLayoutConstraint.activate([
                    layer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                    layer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                    layer.topAnchor.constraint(equalTo: root.topAnchor),
                    layer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                ])
            }
        }
        window.contentView = root
        return root
    }
}

/// Reports a switch away from the mode its contents were built in.
final class AppearanceView: NSView {
    var onChange: (() -> Void)?
    private var builtDark = TrichStyle.isDark

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark != builtDark, let onChange else { return }
        builtDark = dark
        DispatchQueue.main.async { onChange() }
    }
}

// MARK: - Buttons

/// The primary button. The ↩ hint shows Return triggers it.
final class TrichPillButton: NSButton {
    private(set) var plainTitle = ""
    private var scale: CGFloat = 1
    private let returnHint: Bool

    init(title: String, returnHint: Bool = true) {
        self.returnHint = returnHint
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        focusRingType = .exterior
        setTitle(title, scale: 1)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ text: String, scale: CGFloat) {
        plainTitle = text
        self.scale = scale
        layer?.backgroundColor = TrichStyle.pillFill.cgColor
        let title = NSMutableAttributedString(string: text, attributes: [
            .font: TrichFont.ui(round(14 * scale), weight: .semibold),
            .foregroundColor: TrichStyle.pillText,
        ])
        if returnHint { title.append(NSAttributedString(string: "   ↩", attributes: [
            .font: TrichFont.ui(round(13 * scale), weight: .regular),
            .foregroundColor: TrichStyle.pillText.withAlphaComponent(0.65),
        ])) }
        attributedTitle = title
        setAccessibilityLabel(text)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + 40, height: max(36, ceil(size.height) + 16))
    }

    override func mouseDown(with event: NSEvent) {
        TrichMotion.press(self, down: true)
        super.mouseDown(with: event)
        TrichMotion.press(self, down: false)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

final class TrichTextButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        focusRingType = .exterior
        setTitle(title, scale: 1)
    }

    override func mouseDown(with event: NSEvent) {
        TrichMotion.press(self, down: true)
        super.mouseDown(with: event)
        TrichMotion.press(self, down: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A faint fill on hover, so the text reads as a button.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override var isHidden: Bool { didSet { if isHidden { setHover(false) } } }

    private func setHover(_ on: Bool) {
        layer?.cornerRadius = 8
        layer?.backgroundColor = on ? TrichStyle.text.withAlphaComponent(0.06).cgColor : nil
    }

    func setTitle(_ text: String, scale: CGFloat) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: TrichFont.ui(round(14 * scale), weight: .regular),
            .foregroundColor: TrichStyle.text,
        ])
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + 24, height: max(36, ceil(size.height) + 16))
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

// MARK: - Motion

/// Springs and press feedback shared by every pressable surface.
@MainActor
enum TrichMotion {
    /// An Apple-style spring: how long it feels, and how much it overshoots (0 for none).
    static func spring(_ keyPath: String, from: Any?, to: Any?, duration: Double = 0.45, bounce: Double = 0) -> CASpringAnimation {
        let animation = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        animation.keyPath = keyPath
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }

    /// A uniform scale about the layer's center, whatever its anchor point.
    static func scale(_ s: CGFloat, in layer: CALayer) -> CATransform3D {
        let dx = (0.5 - layer.anchorPoint.x) * layer.bounds.width
        let dy = (0.5 - layer.anchorPoint.y) * layer.bounds.height
        var t = CATransform3DMakeTranslation(dx, dy, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -dx, -dy, 0)
    }

    /// Presses in to 97% while the mouse is down and springs back on release.
    /// Animations only, so AppKit's own layer geometry is never touched.
    static func press(_ view: NSView, down: Bool, depth: CGFloat = 0.97) {
        guard let layer = view.layer, !TrichStyle.reduceMotion else { return }
        let current = layer.presentation()?.transform ?? CATransform3DIdentity
        layer.removeAnimation(forKey: "press")
        if down {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = current
            animation.toValue = scale(depth, in: layer)
            animation.duration = 0.12
            animation.timingFunction = TrichStyle.ease
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "press")
        } else {
            layer.add(spring("transform", from: current, to: CATransform3DIdentity, duration: 0.35, bounce: 0.3), forKey: "press")
        }
    }

    /// A short, damped side to side shake for "that can't change".
    static func shake(_ view: NSView) {
        guard let layer = view.layer, !TrichStyle.reduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -5, 4, -2, 1, 0]
        // Each swing eases on its own, so the shake slows evenly instead of buzzing then crawling.
        animation.keyTimes = [0, 0.18, 0.4, 0.62, 0.82, 1]
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 5)
        animation.duration = 0.36
        layer.add(animation, forKey: "shake")
    }
}

// MARK: - The tt. mark

/// The app icon's shapes as vectors, so the mark is sharp at every size.
/// Path data matches the app icon master (1024 grid, y down); keep the two in step.
enum TrichMark {
    static let tileBox = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let glyphBox = CGRect(x: 282, y: 336, width: 460, height: 357.5)

    static let tile = path("M383.41,100H640.59C722.19,100 763,100 806.92,113.89C854.88,131.34 892.66,169.12 910.11,217.08C924,261 924,301.81 924,383.41V640.59C924,722.19 924,763 910.11,806.92C892.66,854.88 854.88,892.66 806.92,910.11C763,924 722.19,924 640.59,924H383.41C301.81,924 261,924 217.08,910.11C169.12,892.66 131.34,854.88 113.89,806.92C100,763 100,722.19 100,640.59V383.41C100,301.81 100,261 113.89,217.08C131.34,169.12 169.12,131.34 217.08,113.89C261,100 301.81,100 383.41,100Z")
    /// The first t, the second t and the dot, in that order.
    static let glyphs = [
        "M322,336H389V407H441V458H389V612C389,628.57 402.43,642 419,642H441V683.5C441,689.02 436.52,693.5 431,693.5H410C344,693.5 322,671.38 322,605V458H282V407H322Z",
        "M504,336H571V407H623V458H571V612C571,628.57 584.43,642 601,642H623V683.5C623,689.02 618.52,693.5 613,693.5H592C526,693.5 504,671.38 504,605V458H464V407H504Z",
        "M704,616C724.99,616 742,633.01 742,654C742,674.99 724.99,692 704,692C683.01,692 666,674.99 666,654C666,633.01 683.01,616 704,616Z",
    ].map(path)
    static let glyph: CGPath = {
        let all = CGMutablePath()
        glyphs.forEach { all.addPath($0) }
        return all
    }()

    /// The in-window mark from the asset catalog (PDF, Preserve Vector Data).
    /// `small` has no glow and suits 16 to 48 pt; the regular mark is for 64 pt and up.
    @MainActor static func image(small: Bool) -> NSImage {
        let name = small ? "TrichMarkSmall" : "TrichMark"
        if let image = NSImage(named: name) { return image }
        // Screenshot harnesses run outside the app bundle, so read the asset from the repo.
        let folder = URL(fileURLWithPath: "Trich/Assets.xcassets/\(name).imageset")
        let pdf = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "pdf" }
        return pdf.flatMap { NSImage(contentsOf: $0) } ?? NSImage()
    }

    /// Absolute M, L, H, V, C and Z: all the master uses.
    private static func path(_ d: String) -> CGPath {
        let p = CGMutablePath()
        var point = CGPoint.zero
        var numbers: [CGFloat] = []
        var command: Character = "M"
        func flush() {
            let n = numbers
            switch command {
            case "M": point = CGPoint(x: n[0], y: n[1]); p.move(to: point)
            case "L": point = CGPoint(x: n[0], y: n[1]); p.addLine(to: point)
            case "H": point.x = n[0]; p.addLine(to: point)
            case "V": point.y = n[0]; p.addLine(to: point)
            case "C":
                point = CGPoint(x: n[4], y: n[5])
                p.addCurve(to: point, control1: CGPoint(x: n[0], y: n[1]), control2: CGPoint(x: n[2], y: n[3]))
            default: p.closeSubpath()
            }
            numbers = []
        }
        var token = ""
        var started = false
        for ch in d + " " {
            if ch.isLetter || ch == "," || ch == " " {
                if let value = Double(token) { numbers.append(CGFloat(value)) }
                token = ""
                if ch.isLetter {
                    if started { flush() }
                    started = true
                    command = ch
                }
            } else {
                token.append(ch)
            }
        }
        flush()
        return p
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Detection status, sensitivity or the login item changed.
    static let trichStatusDidChange = Notification.Name("TrichStatusDidChange")
    /// Reminder history was added to or cleared.
    static let trichHistoryDidChange = Notification.Name("TrichHistoryDidChange")
}

// MARK: - Camera access

/// One reading of camera permission, shared by onboarding and the status menu so they never disagree.
enum CameraAccess: Equatable {
    case notDetermined, authorized, denied, restricted, noDevice

    @MainActor static var current: CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return AVCaptureDevice.default(for: .video) == nil ? .noDevice : .authorized
        default: return .notDetermined
        }
    }
}

// MARK: - Menu bar icon

/// The tt. mark as a template image, so it follows light and dark menu bars.
enum MenuBarIcon {
    enum Style { case active, dimmed, alert }

    static let size = NSSize(width: 22, height: 18)

    static func image(_ style: Style, accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let alpha: CGFloat = style == .dimmed ? 0.4 : 1
            // The app icon's own tt., 12 pt tall, sitting on a whole-point baseline.
            let box = TrichMark.glyphBox
            let scale: CGFloat = 12 / box.height
            let x = round((rect.width - box.width * scale) / 2)
            var t = CGAffineTransform(translationX: x, y: 15).scaledBy(x: scale, y: -scale)
                .translatedBy(x: -box.minX, y: -box.minY)
            if let mark = TrichMark.glyph.copy(using: &t), let context = NSGraphicsContext.current?.cgContext {
                context.addPath(mark)
                context.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
                context.fillPath()
            }

            if style == .alert {
                let dot = NSRect(x: rect.maxX - 6, y: rect.maxY - 7, width: 6, height: 6)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
