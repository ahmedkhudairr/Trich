import Cocoa

// MARK: - State

/// What Check Camera shows. Only two yes/no readings, never an image.
enum CameraCheckState: Equatable {
    case starting
    case live(face: Bool, hand: Bool)
    case noAccess
    case blocked
    case unavailable

    var tip: String {
        switch self {
        case .starting:
            return "Starting the camera…"
        case .live(false, _):
            return "Face the screen in good light."
        case .live(true, false):
            return "Now raise a hand to your face, well inside the frame."
        case .live(true, true):
            return "Looks good. Keep both well inside the frame."
        case .noAccess:
            return "Camera access is off. Turn it on in Privacy & Security → Camera."
        case .blocked:
            return "This Mac blocks the camera. A work or school profile may be the reason."
        case .unavailable:
            return "Can't reach the camera. Open the lid or connect one."
        }
    }
}

/// Runs the camera for Check Camera. The status bar controller provides it; tests use a fake.
@MainActor
protocol CameraCheckHost: AnyObject {
    /// Starts reading the camera and calls `onChange` on the main thread until `stopCameraCheck()`.
    func startCameraCheck(onChange: @escaping (CameraCheckState) -> Void)
    func stopCameraCheck()
    func openCameraSettings()
}

// MARK: - Panel

/// "Face ✓  Hand ✓" plus a tip. Used by the Check Camera window and the onboarding step.
@MainActor
final class CameraCheckPanel: NSView {
    private let faceRow = ReadingRow(name: "Face")
    private let handRow = ReadingRow(name: "Hand")
    private let tip = NSTextField(wrappingLabelWithString: "")
    private(set) var state: CameraCheckState = .starting
    private var lastSpoken: (tip: String, time: TimeInterval)?
    private var tickedAllSeen = false

    init(scale: CGFloat = 1) {
        super.init(frame: .zero)
        faceRow.scale = scale
        handRow.scale = scale
        tip.font = TrichFont.ui(round(14 * scale))
        tip.isSelectable = false

        let readings = NSStackView()
        readings.setViews([faceRow, handRow], in: .leading)
        readings.spacing = 32
        let stack = NSStackView(views: [readings, tip])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            tip.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Two lines always, so the window never resizes as the tip changes
            tip.heightAnchor.constraint(greaterThanOrEqualToConstant:
                ceil(NSLayoutManager().defaultLineHeight(for: tip.font!) * 2)),
        ])
        update(.starting)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ state: CameraCheckState) {
        let changed = state != self.state
        self.state = state
        switch state {
        case .live(let face, let hand):
            faceRow.seen = face
            handRow.seen = hand
        default:
            faceRow.seen = nil
            handRow.seen = nil
        }
        tip.textColor = TrichStyle.muted
        if tip.stringValue != state.tip {
            if !tip.stringValue.isEmpty { crossfade(tip, duration: 0.15) }
            tip.stringValue = state.tip
        }
        if changed { speak(state.tip) }
        // One soft tick the first time both readings land.
        if state == .live(face: true, hand: true), !tickedAllSeen {
            tickedAllSeen = true
            TrichFeel.play(.key)
        }
    }

    /// The tip is a live status, so VoiceOver hears it when it changes, at most every 1.5 s.
    private func speak(_ text: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastSpoken, last.tip == text || now - last.time < 1.5 { return }
        lastSpoken = (text, now)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
}

/// One reading: a name, then a checkmark when seen. Unseen shows a dash, so it never relies on color.
@MainActor
private final class ReadingRow: NSView {
    private let label = NSTextField(labelWithString: "")
    private let mark = NSImageView()
    private lazy var markWidth = mark.widthAnchor.constraint(equalToConstant: 18)
    private let name: String
    var scale: CGFloat = 1 { didSet { render() } }
    var seen: Bool? {
        didSet {
            guard seen != oldValue else { return }
            render()
            // The mark changes in place with a 240 ms crossfade.
            crossfade(mark, duration: 0.24)
        }
    }

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        let stack = NSStackView(views: [label, mark])
        stack.spacing = 8
        stack.setHuggingPriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        label.setAccessibilityElement(false)
        mark.setAccessibilityElement(false)
        mark.wantsLayer = true
        // Fixed width, so swapping the dash for the checkmark never nudges the next reading
        markWidth.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func render() {
        let size = round(22 * scale)
        label.font = TrichFont.ui(size, weight: .semibold)
        label.textColor = TrichStyle.text
        label.stringValue = name
        let symbol = seen == true ? "checkmark" : "minus"
        mark.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        mark.symbolConfiguration = .init(pointSize: round(18 * scale), weight: .bold)
        markWidth.constant = round(18 * scale)
        mark.contentTintColor = seen == true ? TrichStyle.cobalt : TrichStyle.muted
        switch seen {
        case true?: setAccessibilityLabel("\(name) seen")
        case false?: setAccessibilityLabel("\(name) not seen")
        case nil: setAccessibilityLabel("\(name) not checked yet")
        }
    }
}

/// Swaps a view's contents with a short fade.
@MainActor
private func crossfade(_ view: NSView, duration: CFTimeInterval) {
    view.wantsLayer = true
    let fade = CATransition()
    fade.type = .fade
    fade.duration = duration
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    view.layer?.add(fade, forKey: "contents")
}

// MARK: - Window

/// Check Camera… from the menu: live readings, nothing shown from the camera and nothing saved.
@MainActor
final class CameraCheckWindowController: NSObject, NSWindowDelegate {
    static let shared = CameraCheckWindowController()

    weak var host: CameraCheckHost?
    private(set) var window: NSWindow?
    private var panel: CameraCheckPanel?
    private let primary = TrichPillButton(title: "Done")
    private let secondary = TrichTextButton(title: "Open System Settings")

    func show() {
        if window == nil { buildWindow() }
        guard let window else { return }
        if !window.isVisible {
            panel?.update(.starting)
            render()
            startCheck()
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Test hook: shows a state without a host, far off screen and without taking focus.
    func showForTesting(_ state: CameraCheckState) {
        if window == nil { buildWindow() }
        panel?.update(state)
        render()
        window?.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        window?.orderFrontRegardless()
    }

    private func startCheck() {
        host?.startCameraCheck { [weak self] state in
            self?.panel?.update(state)
            self?.render()
        }
    }

    /// Coming back from System Settings with access turned on starts the check again.
    @objc private func appBecameActive() {
        guard window?.isVisible == true, panel?.state == .noAccess,
              CameraAccess.current != .denied else { return }
        startCheck()
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Check Camera"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = TrichStyle.applyGlass(to: window) { [weak self] in self?.rebuild() }

        let title = NSTextField(labelWithString: "Check Camera")
        title.font = TrichFont.ui(15, weight: .semibold)
        title.textColor = TrichStyle.text
        title.setAccessibilityRole(.staticText)

        let panel = CameraCheckPanel()
        self.panel = panel

        let footer = NSTextField(labelWithString: "There's no camera preview, and nothing is recorded or saved.")
        footer.font = TrichFont.ui(12)
        footer.textColor = TrichStyle.muted

        primary.target = self
        primary.action = #selector(done)
        primary.keyEquivalent = "\r"
        secondary.target = self
        secondary.action = #selector(openSettings)
        let buttons = NSStackView()
        buttons.setViews([secondary, primary], in: .trailing)
        buttons.spacing = 8

        let stack = NSStackView(views: [title, panel, footer, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(24, after: title)
        stack.setCustomSpacing(24, after: panel)
        stack.setCustomSpacing(24, after: footer)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            panel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        self.window = window
    }

    /// Light or dark switched: build the glass and labels again in the new colors.
    private func rebuild() {
        guard let window else { return }
        let state = panel?.state ?? .starting
        let frame = window.frame
        let visible = window.isVisible
        self.window = nil
        window.delegate = nil
        window.orderOut(nil)
        buildWindow()
        self.window?.setFrame(frame, display: false)
        panel?.update(state)
        render()
        if visible { self.window?.makeKeyAndOrderFront(nil) }
    }

    private func render() {
        secondary.isHidden = panel?.state != .noAccess
        primary.setTitle("Done", scale: 1)
        secondary.setTitle("Open System Settings", scale: 1)
    }

    @objc private func done() { window?.close() }
    @objc private func openSettings() { host?.openCameraSettings() }

    func windowWillClose(_ notification: Notification) {
        host?.stopCameraCheck()
    }
}
