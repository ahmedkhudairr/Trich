import Cocoa

@MainActor
final class OverlayWindowController: NSObject {

    static let shared = OverlayWindowController()

    /// The reminder's fixed wording. Do not change it.
    static let reminderText = "Relax your hands.\nHold both Shift keys for 3 seconds.\nOr wait \(Int(autoDismissDelay)) seconds."

    private var overlayWindows: [NSWindow] = []
    private var holdViews: [ShiftHoldView] = []
    private var keyMonitor: KeyMonitor?
    private var dismissCallback: (() -> Void)?

    // Last reported Shift state, so displays added mid-reminder start in sync
    private var shiftKeys = ShiftKeys()
    private var heldFor: TimeInterval = 0
    private var lastAnnouncement: (text: String, time: TimeInterval)?

    // Safety net: the overlay always clears by itself after this long
    static let autoDismissDelay: TimeInterval = 15
    private var autoDismissTimer: Timer?

    // The app the user was in, so typing goes back to it after the overlay clears
    private var previousApp: NSRunningApplication?

    private override init() {
        super.init()
        // Cover displays that are connected (or rearranged) while the overlay is up
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    var isShowing: Bool { !overlayWindows.isEmpty }

    // MARK: - Public interface

    /// Shows a dismissible reminder on every available screen.
    @discardableResult
    func showOverlay(onDismiss: @escaping () -> Void) -> Bool {
        guard dismissCallback == nil else { return false }

        guard !NSScreen.screens.isEmpty else { return false }
        dismissCallback = onDismiss
        shiftKeys = ShiftKeys()
        heldFor = 0
        lastAnnouncement = nil

        previousApp = NSWorkspace.shared.frontmostApplication
        showWindows(fadeIn: true)
        announce(Self.reminderText.replacingOccurrences(of: "\n", with: " "), force: true)

        let monitor = KeyMonitor()
        monitor.onShiftKeysChanged = { [weak self] keys, held in self?.shiftKeysChanged(keys, heldFor: held) }
        monitor.onUnlockGestureCompleted = { [weak self] in self?.dismissOverlay() }
        keyMonitor = monitor
        monitor.startMonitoring()

        let timer = Timer(timeInterval: Self.autoDismissDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissOverlay() }
        }
        autoDismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    /// The reminder fades in on every display at once, 250 ms (200 ms with Reduce Motion).
    private func showWindows(fadeIn: Bool = false) {
        for screen in NSScreen.screens {
            let window = makeOverlayWindow(for: screen)
            if fadeIn { window.alphaValue = 0 }
            overlayWindows.append(window)
            if let holdView = window.contentView?.firstSubview(of: ShiftHoldView.self) {
                holdView.update(keys: shiftKeys, heldFor: heldFor)
                holdViews.append(holdView)
            }
            window.orderFrontRegardless()
        }

        overlayWindows.first?.makeKeyAndOrderFront(nil)
        guard fadeIn else { return }
        let windows = overlayWindows
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 0.25
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            windows.forEach { $0.animator().alphaValue = 1 }
        }
    }

    /// After a finished hold the full ring stays 120 ms, then every window fades out in 180 ms.
    /// The overlay counts as gone right away; the fading windows ignore clicks.
    private func fadeOutWindows() {
        let windows = overlayWindows
        let hold = heldFor >= KeyMonitor.requiredHoldDuration - 0.1 ? 0.12 : 0
        overlayWindows.removeAll()
        holdViews.removeAll()
        windows.forEach { $0.ignoresMouseEvents = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
                windows.forEach { $0.animator().alphaValue = 0 }
            } completionHandler: {
                windows.forEach { $0.orderOut(nil) }
            }
        }
    }

    private func removeWindows() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        holdViews.removeAll()
    }

    @objc private func screensChanged() {
        guard dismissCallback != nil else { return }
        removeWindows()
        showWindows()
        if overlayWindows.isEmpty { dismissOverlay() }
    }

    // MARK: - Shift feedback

    private func shiftKeysChanged(_ keys: ShiftKeys, heldFor held: TimeInterval) {
        let keysChanged = keys != shiftKeys
        shiftKeys = keys
        heldFor = held
        holdViews.forEach { $0.update(keys: keys, heldFor: held) }
        if keysChanged, let spoken = ShiftHoldView.spokenPrompt(for: keys) { announce(spoken) }
    }

    /// VoiceOver speech. Progress is spoken only when the keys change, at most every 1.5 s.
    private func announce(_ text: String, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, let last = lastAnnouncement, last.text == text || now - last.time < 1.5 { return }
        lastAnnouncement = (text, now)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    // MARK: - Window construction

    func makeOverlayWindow(for screen: NSScreen) -> NSWindow {
        let window = ReminderWindow(
            // This initializer adds the supplied screen's global origin.
            contentRect: CGRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.canHide = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false

        let localBounds = CGRect(origin: .zero, size: screen.frame.size)
        let contentView = NSView(frame: localBounds)

        // Blur layer
        let blurView = NSVisualEffectView(frame: localBounds)
        blurView.material = .fullScreenUI
        blurView.appearance = NSAppearance(named: .darkAqua)
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.autoresizingMask = [.width, .height]
        blurView.setAccessibilityElement(false)
        contentView.addSubview(blurView)

        // Reminder blue tint
        let dimView = NSView(frame: localBounds)
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = ReminderColors.tint.cgColor
        dimView.autoresizingMask = [.width, .height]
        dimView.setAccessibilityElement(false)
        contentView.addSubview(dimView)

        // Instructions, then the live Shift keys
        let label = makeLabel()
        let holdView = ShiftHoldView()
        let stack = NSStackView(views: [label, holdView])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 40
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: min(localBounds.width * 0.8, 700)),
        ])

        window.contentView = contentView
        return window
    }

    private func makeLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: Self.reminderText)
        label.textColor = NSColor.white.withAlphaComponent(0.95)
        label.font = TrichFont.ui(28, weight: .medium)
        label.alignment = .center
        label.isSelectable = false
        label.setAccessibilityLabel(Self.reminderText.replacingOccurrences(of: "\n", with: " "))
        return label
    }

    // MARK: - Keyboard unlock

    @objc func dismissOverlay() {
        guard dismissCallback != nil else { return }
        keyMonitor?.stopMonitoring()
        keyMonitor = nil
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        fadeOutWindows()
        restoreFocus()
        let cb = dismissCallback
        dismissCallback = nil
        cb?()
    }

    /// Hands typing back to the app the reminder interrupted, unless the user moved on
    /// to another app meanwhile or the Mac is locking.
    private func restoreFocus() {
        defer { previousApp = nil }
        guard let previousApp, !previousApp.isTerminated, !Self.screenIsLocked else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let allowed = [previousApp.processIdentifier, NSRunningApplication.current.processIdentifier]
        guard front == nil || allowed.contains(front!) else { return }
        previousApp.activate()
    }

    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }
}

// MARK: - Colors

enum ReminderColors {
    /// #173D7A at 88% over the blur: the reminder's own blue.
    static let tint = NSColor(srgbRed: 0x17 / 255.0, green: 0x3D / 255.0, blue: 0x7A / 255.0, alpha: 0.88)
    /// #2878F0, the icon's cobalt, for a held key.
    static let cobalt = NSColor(srgbRed: 0x28 / 255.0, green: 0x78 / 255.0, blue: 0xF0 / 255.0, alpha: 1)
}

// MARK: - Shift keys and hold ring

/// Two keycaps that light while each physical Shift key is held, with a ring between them
/// that fills over the 3 s hold. Reduce Motion fills the ring a second at a time and counts.
final class ShiftHoldView: NSView {
    private let leftKey = KeycapView(title: "left ⇧", spokenName: "Left Shift")
    private let rightKey = KeycapView(title: "right ⇧", spokenName: "Right Shift")
    let ring = HoldRingView()
    private let prompt = NSTextField(labelWithString: "")

    static let promptHeight: CGFloat = 24

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        prompt.font = TrichFont.ui(17)
        prompt.textColor = NSColor.white.withAlphaComponent(0.85)
        prompt.alignment = .center
        prompt.setAccessibilityElement(false)

        let row = NSStackView(views: [leftKey, ring, rightKey])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 24

        let column = NSStackView(views: [row, prompt])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 16
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            prompt.heightAnchor.constraint(equalToConstant: Self.promptHeight),
        ])

        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(keys: ShiftKeys, heldFor held: TimeInterval) {
        leftKey.setHeld(keys.left)
        rightKey.setHeld(keys.right)
        ring.update(holding: keys.both, heldFor: held,
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        prompt.stringValue = Self.visiblePrompt(for: keys) ?? ""
    }

    /// One short line about the key still missing. Silent until a key goes down.
    static func visiblePrompt(for keys: ShiftKeys) -> String? {
        switch (keys.left, keys.right) {
        case (true, true): return "Keep holding."
        case (true, false): return "Now hold right ⇧ too."
        case (false, true): return "Now hold left ⇧ too."
        case (false, false): return nil
        }
    }

    static func spokenPrompt(for keys: ShiftKeys) -> String? {
        switch (keys.left, keys.right) {
        case (true, true): return "Both Shift keys held. Keep holding."
        case (true, false): return "Now hold right Shift too."
        case (false, true): return "Now hold left Shift too."
        case (false, false): return nil
        }
    }

    var promptText: String { prompt.stringValue }
}

final class KeycapView: NSView {
    private let title: NSTextField
    private let spokenName: String
    private(set) var isHeld = false

    init(title text: String, spokenName: String) {
        title = NSTextField(labelWithString: text)
        self.spokenName = spokenName
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous

        // Bold, since white on cobalt (4.2:1) passes AA only as large bold text.
        title.font = TrichFont.ui(20, weight: .bold)
        title.textColor = .white
        title.alignment = .center
        title.setAccessibilityElement(false)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 128),
            heightAnchor.constraint(equalToConstant: 56),
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(spokenName)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        applyStyle()
    }

    /// Held: cobalt with a white edge, so the change never relies on color alone.
    private func applyStyle() {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if isHeld {
            layer?.backgroundColor = ReminderColors.cobalt.cgColor
            layer?.borderColor = NSColor.white.cgColor
            layer?.borderWidth = 2
            title.textColor = .white
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(increaseContrast ? 0.9 : 0.45).cgColor
            layer?.borderWidth = 1.5
            title.textColor = NSColor.white.withAlphaComponent(0.9)
        }
        setAccessibilityValue(isHeld ? "held" : "not held")
    }
}

/// Fills over the 3 s hold and empties on release.
final class HoldRingView: NSView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let count = NSTextField(labelWithString: "")
    private var isFilling = false

    private static let size: CGFloat = 56
    private static let lineWidth: CGFloat = 4

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let inset = Self.lineWidth / 2
        let circle = CGRect(x: inset, y: inset, width: Self.size - Self.lineWidth, height: Self.size - Self.lineWidth)
        // Start at 12 o'clock and run clockwise.
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)

        for shape in [track, fill] {
            shape.frame = bounds
            shape.path = path
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        fill.strokeColor = NSColor.white.cgColor
        fill.strokeEnd = 0

        count.font = TrichFont.ui(17, weight: .semibold, tabular: true)
        count.textColor = .white
        count.alignment = .center
        count.setAccessibilityElement(false)
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(count)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            count.centerXAnchor.constraint(equalTo: centerXAnchor),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Hold progress")
        setAccessibilityValue("0 of 3 seconds")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var progress: CGFloat { fill.strokeEnd }

    func update(holding: Bool, heldFor held: TimeInterval, reduceMotion: Bool) {
        let duration = KeyMonitor.requiredHoldDuration
        let seconds = holding ? min(Int(held), Int(duration)) : 0
        setAccessibilityValue("\(seconds) of \(Int(duration)) seconds")

        guard holding else {
            isFilling = false
            count.stringValue = ""
            fill.removeAllAnimations()
            setStrokeEnd(0, duration: reduceMotion ? 0 : 0.2)
            return
        }

        if reduceMotion {
            // Whole steps, no motion: the ring fills a third per second and shows the count.
            count.stringValue = seconds > 0 ? "\(seconds)" : ""
            setStrokeEnd(CGFloat(seconds) / CGFloat(duration), duration: 0)
            return
        }

        count.stringValue = ""
        guard !isFilling else { return }
        isFilling = true
        let start = CGFloat(min(held / duration, 1))
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = start
        animation.toValue = 1
        animation.duration = max(duration - held, 0.01)
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        fill.strokeEnd = 1
        fill.add(animation, forKey: "fill")
    }

    /// Static fill for snapshots and tests.
    func show(progress: CGFloat, count text: String = "") {
        fill.removeAllAnimations()
        isFilling = false
        count.stringValue = text
        setStrokeEnd(progress, duration: 0)
    }

    private func setStrokeEnd(_ value: CGFloat, duration: TimeInterval) {
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        fill.strokeEnd = value
        CATransaction.commit()
    }
}

// MARK: - Window

final class ReminderWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    // Swallow typing quietly: no beep, and no menu shortcut (such as ⌘Q) can skip the two-Shift rule.
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
    override func cancelOperation(_ sender: Any?) {}
}

private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}
