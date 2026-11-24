import Cocoa

/// What onboarding needs from the rest of the app. The app delegate provides it; tests use a fake.
@MainActor
protocol OnboardingHost: CameraCheckHost {
    var cameraAccess: CameraAccess { get }
    var detectionIsOn: Bool { get }
    var opensAtLogin: Bool { get }
    var pullZones: Set<PullZone> { get }
    func setPullZones(_ zones: Set<PullZone>)
    func openCameraSettings()
    func startPracticeReminder(onClose: @escaping () -> Void) -> Bool
    func highlightMenuBarIcon()
    func turnOnDetection()
    func setOpensAtLogin(_ on: Bool) -> Bool
}

// MARK: - Steps

/// Steps in order.
enum OnboardingStep: Int, CaseIterable {
    case welcome, privacy, areas, camera, practice, menuBar, check, finish

    var railTitle: String {
        switch self {
        case .welcome: return "Welcome"
        case .privacy: return "Privacy"
        case .areas: return "What You Pull"
        case .camera: return "Camera"
        case .practice: return "Practice"
        case .menuBar: return "Menu Bar"
        case .check: return "Check Camera"
        case .finish: return "Turn On"
        }
    }

    var title: String {
        switch self {
        case .welcome: return "Welcome to Trich"
        case .privacy: return "It all stays on your Mac"
        case .areas: return "What do you pull?"
        case .camera: return "Detection and your camera"
        case .practice: return "Try a practice reminder"
        case .menuBar: return "Find Trich in your menu bar"
        case .check: return "Check your camera"
        case .finish: return "Turn on Trich"
        }
    }
}

// MARK: - Controller

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    static let completionKey = "hasCompletedOnboarding"

    weak var host: OnboardingHost?

    /// Multiplies every font size. Tests use it to check larger text still fits.
    var textScale: CGFloat = 1

    private let defaults: UserDefaults
    private(set) var window: NSWindow?
    private(set) var step: OnboardingStep = .welcome
    private var furthest: OnboardingStep = .welcome
    /// Steps passed with Skip. The rail keeps their number instead of a check.
    private var skipped: Set<OnboardingStep> = []
    private var displayObserver: NSObjectProtocol?
    /// The full-screen practice reminder ran.
    private var practiced = false
    /// The Shift hold was practiced inside the window.
    private var rehearsed = false
    /// Live while the Check Camera step is reading the camera; nil before it starts.
    private var checkPanel: CameraCheckPanel?
    private var completed = false
    private var onComplete: (() -> Void)?
    private var onSkip: (() -> Void)?
    private var cameraPoll: Timer?
    private var shownAccess: CameraAccess?

    private let baseSize = NSSize(width: 800, height: 600)
    private let railWidth: CGFloat = 240
    private let contentInset: CGFloat = 56

    private var contentHost = NSView()
    private var currentContent: NSView?
    private var ambient: AmbientLight?
    private var heroMark: LivingMark?
    /// The mark assembles once per session; later marks fade in.
    private var markAssembled = false
    /// Headlines build word by word only on a step's first visit.
    private var buildHeadline = true
    private var preview: ReminderPreview?
    private var zoneCards: [ZoneCard] = []
    private var railButtons: [RailButton] = []
    private var progressFill: NSLayoutConstraint?
    private var progressTrackWidth: CGFloat = 0
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressBar = NSView()
    private let soundButton = NSButton()
    private let backButton = TrichTextButton(title: "Back")
    private let secondaryButton = TrichTextButton(title: "")
    private let primaryButton = TrichPillButton(title: "")
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?

    /// The in-window Shift practice.
    private var heldKeys = (left: false, right: false)
    private var holdTimer: Timer?
    private var holdSeconds = 0
    private var detectionObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    // MARK: Public

    /// Shows onboarding. `startOver` begins at Welcome; otherwise it resumes where the user left off.
    func show(startOver: Bool = true, onComplete: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onSkip = onSkip
        completed = false
        TrichFeel.defaults = defaults
        TrichFeel.prepare()
        if window == nil { buildWindow() }
        if startOver { furthest = .welcome; skipped = [] }
        markAssembled = false
        window?.alphaValue = 1
        go(to: startOver ? .welcome : step, animated: false)
        if Self.offscreenForTesting {
            // Move first, then order in, so no frame ever lands on a display.
            window?.setFrameOrigin(Self.offscreenOrigin)
            window?.orderFrontRegardless()
        } else {
            window?.center()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        enterMark()
        updateAmbientRunning()
    }

    /// Test hook: shows the window parked off every display, never activating the app or
    /// taking focus, with ambient motion running as if the window were key.
    static var offscreenForTesting = false
    private static let offscreenOrigin = CGPoint(x: -40000, y: -40000)

    func bringToFrontIfVisible() -> Bool {
        guard let window, window.isVisible else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Moves to a step. Internal so the screenshot harness can visit every step.
    /// Animated moves come from the person, so they also play the step's note and a haptic.
    func go(to target: OnboardingStep, animated: Bool = true) {
        // After Turn On Trich the steps are behind the person; only Done remains.
        guard window != nil, farewell == nil else { return }
        let forward = target.rawValue >= step.rawValue
        let changed = target != step
        step = target
        buildHeadline = target.rawValue >= furthest.rawValue
        if target.rawValue > furthest.rawValue { furthest = target }
        if target != .check { stopCheck() }
        if target != .practice { resetHold() }
        render(animated: animated, forward: forward)
        if animated && changed {
            TrichFeel.play(.step(target.rawValue))
            TrichFeel.haptic(.levelChange)
        }
        updateCameraPoll()
        if target == .menuBar { host?.highlightMenuBarIcon() }
    }

    /// Test hook: shows the practice step as it looks after a practice reminder closed.
    func markPracticedForTesting() {
        practiced = true
        if step == .practice { render(animated: false, forward: true) }
    }

    /// Test hook: drives the in-window Shift practice without a keyboard.
    func simulateShiftForTesting(left: Bool, right: Bool) { shiftKeysChanged(left: left, right: right) }


    // MARK: Window

    private func buildWindow() {
        let origin = Self.offscreenForTesting ? Self.offscreenOrigin : .zero
        let window = OnboardingWindow(contentRect: NSRect(origin: origin, size: baseSize),
                                      styleMask: [.titled, .closable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.title = "Welcome to Trich"
        window.isReleasedWhenClosed = false
        // Content is rebuilt each step, so Tab (Full Keyboard Access) follows the new views
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.onBack = { [weak self] in self?.goBack() }
        window.onForward = { [weak self] in self?.goForwardIfContinue() }
        window.onShift = { [weak self] left, right in self?.shiftKeysChanged(left: left, right: right) }
        window.onPointer = { [weak self] offset in
            self?.ambient?.drift(offset)
            self?.heroMark?.lean(offset)
            self?.heroMark?.breatheIfRested()
        }
        self.window = window
        buildContent()
        // Reduce Motion, Reduce Transparency and Increase Contrast rebuild the window in place.
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.currentContent = nil
                self.buildContent()
                self.render(animated: false, forward: true, quiet: true)
                self.updateAmbientRunning()
            }
        }
    }

    /// Builds everything inside the window. Runs again when light or dark mode switches.
    private func buildContent() {
        guard let window else { return }
        let root = TrichStyle.applyGlass(to: window) { [weak self] in
            guard let self else { return }
            self.currentContent = nil
            self.buildContent()
            self.render(animated: false, forward: true)
            self.updateAmbientRunning()
        }
        progressBar.subviews.forEach { $0.removeFromSuperview() }

        let rail = buildRail()
        root.addSubview(rail)
        let pane = buildPane()
        root.addSubview(pane)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rail.topAnchor.constraint(equalTo: root.topAnchor),
            rail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: railWidth),
            pane.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            pane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pane.topAnchor.constraint(equalTo: root.topAnchor),
            pane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func buildRail() -> NSView {
        let rail = ColorView(color: TrichStyle.frameTint)
        let divider = ColorView(color: TrichStyle.hairline)
        rail.addSubview(divider)

        let icon = NSImageView(image: TrichMark.image(small: true))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        let name = makeLabel("Trich", size: 15, weight: .semibold)
        let brand = NSStackView(views: [icon, name])
        brand.spacing = 8
        brand.alignment = .centerY

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        railButtons = OnboardingStep.allCases.map { step in
            let button = RailButton(step: step, scale: textScale)
            button.target = self
            button.action = #selector(railClicked(_:))
            list.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: railWidth - 32).isActive = true
            return button
        }

        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = TrichStyle.track.cgColor
        progressBar.layer?.cornerRadius = 2
        progressBar.setAccessibilityElement(true)
        progressBar.setAccessibilityRole(.progressIndicator)
        progressBar.setAccessibilityLabel("Setup progress")
        let fill = ColorView(color: TrichStyle.cobalt)
        fill.layer?.cornerRadius = 2
        progressBar.addSubview(fill)
        progressLabel.font = font(12, .regular)
        progressLabel.textColor = TrichStyle.muted
        progressLabel.setAccessibilityElement(false)

        soundButton.isBordered = false
        soundButton.imagePosition = .imageOnly
        soundButton.target = self
        soundButton.action = #selector(soundToggled)
        soundButton.setAccessibilityLabel("Sound effects")
        updateSoundButton()

        for view in [brand, list, progressBar, progressLabel, soundButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rail.addSubview(view)
        }
        progressTrackWidth = railWidth - 48
        let fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        progressFill = fillWidth
        NSLayoutConstraint.activate([
            divider.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
            divider.topAnchor.constraint(equalTo: rail.topAnchor),
            divider.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            brand.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 24),
            brand.topAnchor.constraint(equalTo: rail.topAnchor, constant: 56),
            list.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 16),
            list.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 32),
            progressBar.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 24),
            progressBar.widthAnchor.constraint(equalToConstant: progressTrackWidth),
            progressBar.heightAnchor.constraint(equalToConstant: 4),
            progressLabel.leadingAnchor.constraint(equalTo: progressBar.leadingAnchor),
            progressLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 8),
            progressLabel.bottomAnchor.constraint(equalTo: rail.bottomAnchor, constant: -24),
            soundButton.trailingAnchor.constraint(equalTo: progressBar.trailingAnchor, constant: 4),
            soundButton.centerYAnchor.constraint(equalTo: progressLabel.centerYAnchor),
            soundButton.widthAnchor.constraint(equalToConstant: 24),
            soundButton.heightAnchor.constraint(equalToConstant: 24),
            fill.leadingAnchor.constraint(equalTo: progressBar.leadingAnchor),
            fill.topAnchor.constraint(equalTo: progressBar.topAnchor),
            fill.bottomAnchor.constraint(equalTo: progressBar.bottomAnchor),
            fillWidth,
        ])
        return rail
    }

    private func buildPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        let light = AmbientLight()
        light.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(light)
        ambient = light
        contentHost = NSView()
        contentHost.wantsLayer = true
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(contentHost)

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let divider = ColorView(color: TrichStyle.hairline)
        bar.addSubview(divider)
        pane.addSubview(bar)

        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.keyEquivalent = "\u{1b}"
        backButton.setAccessibilityHelp("Goes to the previous step. Shortcut: Escape or Left Arrow.")
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryClicked)
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.keyEquivalent = "\r"
        for button in [backButton, secondaryButton, primaryButton] as [NSButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(button)
        }

        NSLayoutConstraint.activate([
            light.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            light.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            light.topAnchor.constraint(equalTo: pane.topAnchor),
            light.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: pane.topAnchor, constant: 64),
            contentHost.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -24),
            bar.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 72),
            divider.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: bar.topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            backButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: contentInset - 12),
            backButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            primaryButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -contentInset),
            primaryButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            secondaryButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -8),
            secondaryButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return pane
    }

    // MARK: Rendering

    /// `quiet` refreshes the current step in place, without moving focus or announcing it again.
    private func render(animated: Bool, forward: Bool, quiet: Bool = false) {
        guard let window else { return }
        shownAccess = host?.cameraAccess

        for button in railButtons {
            let state: RailButton.State
            if farewell == .watching { state = .done }
            else if button.step == step { state = .current }
            else if button.step.rawValue <= furthest.rawValue, !skipped.contains(button.step) { state = .done }
            else { state = .upcoming }
            button.update(state: state, number: button.step.rawValue + 1, total: OnboardingStep.allCases.count,
                          animated: animated)
        }
        let number = step.rawValue + 1
        let total = OnboardingStep.allCases.count
        progressLabel.stringValue = "Step \(number) of \(total)"
        progressBar.setAccessibilityValue("Step \(number) of \(total)")

        let content: NSView
        if let farewell, let kept = updateFarewellInPlace(farewell, animated: animated) {
            content = kept
            configureButtons(for: step)
        } else {
            heroMark = nil
            successCheck = nil
            preview = nil
            zoneCards = []
            content = makeContent(for: step)
            configureButtons(for: step)
            swap(in: content, animated: animated, forward: forward)
            if animated { successCheck?.play() }
        }

        let fillWidth = progressTrackWidth * CGFloat(number) / CGFloat(total)
        if animated && window.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = TrichStyle.reduceMotion ? 0.15 : 0.45
                context.timingFunction = TrichStyle.easeMove
                context.allowsImplicitAnimation = true
                progressFill?.animator().constant = fillWidth
            }
        } else {
            progressFill?.constant = fillWidth
        }

        window.recalculateKeyViewLoop()
        guard !quiet else { return }
        window.initialFirstResponder = primaryButton
        window.makeFirstResponder(primaryButton)
        let announcement = farewell.map { "\(farewellText($0).title) \(farewellText($0).body)" }
            ?? "Step \(number) of \(total). \(step.title)."
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: announcement,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        NSAccessibility.post(element: content, notification: .layoutChanged)
    }

    /// Puts new content in place. Animated, the old content eases out toward where it came from,
    /// and the new one slides in on a spring with its rows following a beat apart.
    private func swap(in content: NSView, animated: Bool, forward: Bool) {
        guard let window else { return }
        let previous = currentContent
        currentContent = content
        content.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: contentInset),
            content.widthAnchor.constraint(equalToConstant: baseSize.width - railWidth - contentInset * 2),
            content.topAnchor.constraint(equalTo: contentHost.topAnchor),
        ])
        fitWindow(to: content)
        contentHost.layoutSubtreeIfNeeded()

        guard animated && window.isVisible, let layer = content.layer else {
            previous?.removeFromSuperview()
            heroMark?.startBreathing()
            return
        }
        let reduceMotion = TrichStyle.reduceMotion
        let direction: CGFloat = forward ? 1 : -1

        if let previous, let old = previous.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 0
            slide.toValue = reduceMotion ? 0 : -16 * direction
            let group = CAAnimationGroup()
            group.animations = [fade, slide]
            group.duration = reduceMotion ? 0.12 : 0.16
            group.timingFunction = TrichStyle.easeIn
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { previous.removeFromSuperview() } }
            old.add(group, forKey: "leave")
            CATransaction.commit()
        }

        let now = CACurrentMediaTime()
        if reduceMotion {
            // The new step fades in once the old one has nearly gone, so the two never overlap.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.18
            fade.beginTime = now + 0.1
            fade.fillMode = .backwards
            layer.add(fade, forKey: "enter")
            heroMark?.startBreathing()
            return
        }
        let slide = TrichMotion.spring("transform.translation.x", from: 28 * direction, to: 0, duration: 0.5)
        slide.beginTime = now + 0.1
        slide.fillMode = .backwards
        layer.add(slide, forKey: "enter")

        let rows = (content as? NSStackView)?.arrangedSubviews ?? [content]
        enterRows(rows, from: now + 0.1, buildHeadline: buildHeadline)
        enterMark()
    }

    /// Rows arrive one after another, rising a few points as they fade in, while the eye is
    /// still on the headline. A first visit builds the headline word by word and the rows
    /// start 120 ms after its first word; a revisit fades it in as one piece. Every row has
    /// started within 450 ms.
    private func enterRows(_ rows: [NSView], from start: CFTimeInterval, buildHeadline: Bool) {
        var next = start
        for row in rows {
            row.wantsLayer = true
            if let title = row as? Headline, buildHeadline, !TrichStyle.reduceMotion {
                title.build(at: next + 0.04)
                next += 0.12
                continue
            }
            guard let rowLayer = row.layer else { continue }
            let begin = min(next, start + 0.45)
            next += 0.045
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = TrichStyle.reduceMotion ? 0.18 : 0.28
            fade.timingFunction = TrichStyle.ease
            var animations: [CAAnimation] = [fade]
            if !TrichStyle.reduceMotion, !(row is Headline) {
                animations.append(TrichMotion.spring("transform.translation.y", from: -8, to: 0, duration: 0.5))
            }
            for animation in animations {
                animation.beginTime = begin
                animation.fillMode = .backwards
                rowLayer.add(animation, forKey: animation === fade ? "fade" : "rise")
            }
        }
    }

    /// The mark builds itself the first time it appears in a session. After that it fades in.
    private func enterMark() {
        guard let heroMark else { return }
        if markAssembled {
            heroMark.fadeIn()
        } else {
            markAssembled = true
            heroMark.playEntrance()
        }
    }

    /// Grows the window if larger text needs more room, so nothing clips.
    private func fitWindow(to content: NSView) {
        guard let window else { return }
        contentHost.layoutSubtreeIfNeeded()
        let needed = content.fittingSize.height + 64 + 24 + 72
        let height = max(baseSize.height, ceil(needed / 8) * 8)
        guard abs(window.frame.height - height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true)
    }

    private func configureButtons(for step: OnboardingStep) {
        if let farewell { return configureFarewellButtons(farewell) }
        backButton.isHidden = step == .welcome
        var primary = ("Continue", { [weak self] in self?.advance() } as () -> Void)
        var secondary: (String, () -> Void)?

        switch step {
        case .camera:
            // Camera access is requested on the last step, by Turn On Trich.
            if host?.cameraAccess == .denied {
                secondary = ("Open System Settings", { [weak self] in self?.host?.openCameraSettings() })
            }
        case .practice:
            if !practiced && !rehearsed {
                primary = ("Start Practice Reminder", { [weak self] in self?.startPractice() })
                secondary = ("Skip", { [weak self] in self?.skip() })
            } else if !practiced {
                secondary = ("Try Full Screen", { [weak self] in self?.startPractice() })
            }
        case .check:
            if checkPanel == nil {
                primary = ("Check Camera", { [weak self] in self?.startCheck() })
                secondary = ("Skip", { [weak self] in self?.skip() })
            } else if checkPanel?.state == .noAccess {
                secondary = ("Open System Settings", { [weak self] in self?.host?.openCameraSettings() })
            }
        case .finish:
            if host?.detectionIsOn == true {
                primary = ("Done", { [weak self] in self?.finish() })
            } else {
                primary = ("Turn On Trich", { [weak self] in self?.turnOnClicked() })
                secondary = ("Not now", { [weak self] in self?.finish() })
            }
        default:
            break
        }

        primaryButton.setTitle(primary.0, scale: textScale)
        primaryAction = primary.1
        secondaryButton.isHidden = secondary == nil
        secondaryButton.setTitle(secondary?.0 ?? "", scale: textScale)
        secondaryAction = secondary?.1
        backButton.setTitle("Back", scale: textScale)
    }

    private var primaryIsContinue: Bool { primaryButton.plainTitle == "Continue" }

    // MARK: Step content

    private func makeContent(for step: OnboardingStep) -> NSView {
        if let farewell { return farewellContent(farewell) }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0

        func add(_ view: NSView, after spacing: CGFloat) {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(spacing, after: last) }
            stack.addArrangedSubview(view)
            if view is NSTextField || view is CardView || view is Headline {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        let title = headline(step.title)

        switch step {
        case .welcome:
            let mark = LivingMark(side: 88)
            heroMark = mark
            add(mark, after: 0)
            add(title, after: 32)
            add(body("A free Mac app for trichotillomania. It interrupts you when your hand reaches your hair, beard or eyebrows."), after: 16)
            add(note(), after: 24)
            add(secondaryText("An awareness tool, not a medical treatment."), after: 16)

        case .privacy:
            add(symbolTile("lock.shield"), after: 0)
            add(title, after: 32)
            let card = CardView()
            card.setRows([
                row(symbol: "eye", text: "Camera frames stay in memory, then get thrown away."),
                row(symbol: "wifi.slash", text: "Nothing is recorded or uploaded."),
                row(symbol: "clock", text: "Only reminder times are saved, for 90 days."),
            ])
            add(card, after: 24)

        case .areas:
            add(title, after: 0)
            add(body("Pick as many as you like, and Trich only watches those."), after: 16)
            let chosen = host?.pullZones ?? [.beard]
            // Seeing the choice counts as making it, so the menu never repeats it
            host?.setPullZones(chosen)
            let notes: [PullZone: String] = [.beard: "Chin, jaw and lip",
                                             .brows: "Brows and lashes. Glasses may trip it.",
                                             .scalp: "Front and sides"]
            zoneCards = PullZone.allCases.map { zone in
                let card = ZoneCard(zone: zone, note: notes[zone] ?? "", scale: textScale)
                card.setOn(chosen.contains(zone), animated: false)
                card.target = self
                card.action = #selector(zoneClicked(_:))
                return card
            }
            let row = NSStackView(views: zoneCards)
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = 12
            zoneCards.forEach { $0.heightAnchor.constraint(equalToConstant: round(208 * max(1, textScale * 0.92))).isActive = true }
            add(row, after: 24)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            add(secondaryText("Eyebrows and scalp are newer, so they miss more often. You can change this anytime from the menu bar."), after: 16)

        case .camera:
            add(symbolTile("camera"), after: 0)
            add(title, after: 32)
            add(body("Detection starts off. When it's on, the camera watches for your hand near the areas you picked. It's an estimate, so it can be wrong sometimes."), after: 16)
            let card = CardView()
            card.setRows([cameraRow()])
            add(card, after: 24)
            add(secondaryText("The green camera light means Trich is watching."), after: 16)

        case .practice:
            let preview = ReminderPreview(scale: textScale)
            self.preview = preview
            add(preview, after: 0)
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            add(title, after: 24)
            add(body("When your hand gets close, this covers your screens. Hold both Shift keys for 3 seconds to close it, or wait 15 seconds."), after: 16)
            if practiced || rehearsed {
                add(row(symbol: "checkmark.circle", text: "Nice. That's how you close a reminder.", tint: TrichStyle.cobalt), after: 16)
            } else {
                add(secondaryText("You can try it right here by holding both Shift keys."), after: 16)
            }

        case .menuBar:
            let strip = MenuBarStrip(scale: textScale)
            add(strip, after: 0)
            strip.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            add(title, after: 32)
            add(body("Click the tt. icon to turn detection on or off, pause it, or open your dashboard."), after: 16)
            let legend = CardView()
            legend.setRows([
                row(image: MenuBarIcon.image(.active, accessibilityDescription: ""), text: "Watching", tint: TrichStyle.text),
                row(image: MenuBarIcon.image(.dimmed, accessibilityDescription: ""), text: "Off or paused", tint: TrichStyle.text),
                row(image: MenuBarIcon.image(.alert, accessibilityDescription: ""), text: "Camera needs attention", tint: TrichStyle.text),
            ], spacing: 8)
            add(legend, after: 24)
            add(secondaryText("If the notch hides the icon, open Trich from Applications to see the dashboard and the Detection menu."), after: 16)

        case .check:
            add(symbolTile("person.crop.square"), after: 0)
            add(title, after: 32)
            let askFirst = host?.cameraAccess == .notDetermined ? " macOS asks for camera access first." : ""
            add(body("If you like, check that Trich can find your face and hand." + askFirst), after: 16)
            if let checkPanel {
                let card = CardView()
                card.setRows([checkPanel])
                add(card, after: 24)
            }
            add(secondaryText("There's no camera preview, and nothing is recorded or saved."), after: 16)

        case .finish:
            let mark = LivingMark(side: 72)
            heroMark = mark
            add(mark, after: 0)
            add(title, after: 32)
            let on = host?.detectionIsOn == true
            let access = host?.cameraAccess ?? .notDetermined
            let start: String
            switch access {
            case _ where on: start = "Trich is watching."
            case .notDetermined: start = "Trich asks for camera access, then starts watching."
            case .denied, .restricted: start = "Trich starts watching once it can use the camera."
            default: start = "Trich starts watching right away."
            }
            add(body(start + " It pauses when your Mac sleeps or locks."), after: 16)
            add(secondaryText("Pause it before screen sharing, since reminders show up on shared screens."), after: 16)
            let login = NSButton(checkboxWithTitle: "Start Trich at login", target: self, action: #selector(loginToggled(_:)))
            login.font = font(14, .regular)
            login.state = host?.opensAtLogin == true ? .on : .off
            add(login, after: 24)
            if access == .denied || access == .restricted {
                add(row(symbol: "exclamationmark.triangle", text: "Camera access is off, so Trich can't watch yet."), after: 16)
            }
        }
        return stack
    }

    private var contentWidth: CGFloat { baseSize.width - railWidth - contentInset * 2 }

    private func headline(_ text: String) -> Headline {
        Headline(text, font: font(28, .semibold), color: TrichStyle.text, width: contentWidth)
    }

    /// A short note from Ahmed, so the first screen sounds like a person.
    private func note() -> NSView {
        let card = CardView()
        let text = makeLabel("I made Trich for my own pulling. You're not alone in this, and I hope it helps you too.", size: 14, wraps: true)
        let signature = makeLabel("Ahmed", size: 13, wraps: false)
        signature.textColor = TrichStyle.muted
        card.setRows([text, signature], spacing: 8)
        return card
    }

    private func cameraRow() -> NSView {
        switch host?.cameraAccess ?? .notDetermined {
        case .notDetermined:
            return row(symbol: "camera", text: "macOS asks for access the first time Trich uses the camera.")
        case .authorized:
            return row(symbol: "checkmark.circle", text: "Camera access is on.", tint: TrichStyle.cobalt)
        case .denied:
            return row(symbol: "exclamationmark.triangle", text: "Camera access is off. Turn it on in Privacy & Security → Camera.")
        case .restricted:
            return row(symbol: "lock", text: "This Mac blocks the camera. A work or school profile may be the reason.")
        case .noDevice:
            return row(symbol: "video.slash", text: "No camera found. Open the lid or connect one.")
        }
    }

    // MARK: Building blocks

    private func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        TrichFont.ui(round(size * textScale), weight: weight)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, wraps: Bool = false) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = font(size, weight)
        label.textColor = TrichStyle.text
        label.isSelectable = false
        if wraps { label.setContentCompressionResistancePriority(.required, for: .vertical) }
        return label
    }

    private func body(_ text: String) -> NSTextField {
        let label = makeLabel(text, size: 15, wraps: true)
        label.attributedStringValue = spaced(text, size: 15, color: TrichStyle.text, lineHeight: 1.35)
        return label
    }

    private func secondaryText(_ text: String) -> NSTextField {
        let label = makeLabel(text, size: 13, wraps: true)
        label.attributedStringValue = spaced(text, size: 13, color: TrichStyle.muted, lineHeight: 1.3)
        return label
    }

    private func spaced(_ text: String, size: CGFloat, color: NSColor, lineHeight: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        let f = font(size, .regular)
        style.lineSpacing = f.pointSize * (lineHeight - 1.2)
        return NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color, .paragraphStyle: style])
    }

    /// A frosted tile holding one SF Symbol in cobalt.
    private func symbolTile(_ name: String) -> NSView {
        let tile = GlassCard()
        tile.layer?.cornerRadius = 18
        tile.setAccessibilityElement(false)
        let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        image.contentTintColor = TrichStyle.cobalt
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 72),
            tile.heightAnchor.constraint(equalToConstant: 72),
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    private func row(symbol: String, text: String, tint: NSColor? = nil) -> NSView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        return row(image: image, text: text, tint: tint)
    }

    private func row(image source: NSImage, text: String, tint: NSColor? = nil) -> NSView {
        let image = NSImageView(image: source)
        image.symbolConfiguration = .init(pointSize: round(15 * textScale), weight: .regular)
        image.contentTintColor = tint ?? TrichStyle.muted
        image.setAccessibilityElement(false)
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: round(22 * textScale)).isActive = true
        let label = makeLabel(text, size: 14, wraps: true)
        let row = NSView()
        row.addSubview(image)
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        let lineHeight = ceil(label.font?.boundingRectForFont.height ?? 18)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            image.centerYAnchor.constraint(equalTo: row.topAnchor, constant: lineHeight / 2),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    // MARK: Actions

    @objc private func primaryClicked() { primaryAction?() }
    @objc private func secondaryClicked() { secondaryAction?() }
    @objc private func backClicked() { goBack() }

    @objc private func railClicked(_ sender: RailButton) {
        guard sender.step.rawValue <= furthest.rawValue, sender.step != step else { return }
        go(to: sender.step)
    }

    @objc private func soundToggled() {
        TrichFeel.muted.toggle()
        updateSoundButton()
        if TrichFeel.soundsOn { TrichFeel.play(.toggleOn) }
        TrichFeel.haptic(.alignment)
    }

    private func updateSoundButton() {
        let on = !TrichFeel.muted && TrichFeel.systemAllowsSounds
        let symbol = on ? "speaker.wave.2" : "speaker.slash"
        soundButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        soundButton.symbolConfiguration = .init(pointSize: round(12 * textScale), weight: .regular)
        soundButton.contentTintColor = TrichStyle.muted
        soundButton.isEnabled = TrichFeel.systemAllowsSounds
        soundButton.toolTip = TrichFeel.systemAllowsSounds
            ? (on ? "Turn off sounds" : "Turn on sounds")
            : "Sounds follow your Mac's sound effects setting, which is off."
        soundButton.setAccessibilityValue(on ? "On" : "Off")
    }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }

    /// Right Arrow and Command-] move on when the primary button continues, or when the step can be skipped.
    private func goForwardIfContinue() {
        if primaryIsContinue { advance() }
        else if !secondaryButton.isHidden && secondaryButton.title == "Skip" { skip() }
    }

    private func skip() {
        skipped.insert(step)
        advance()
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        go(to: next)
    }

    @objc private func zoneClicked(_ sender: ZoneCard) {
        var zones = host?.pullZones ?? [.beard]
        let turningOn = !sender.isOn
        if turningOn { zones.insert(sender.zone) } else { zones.remove(sender.zone) }
        // Something has to stay on
        guard !zones.isEmpty else {
            TrichMotion.shake(sender)
            TrichFeel.play(.nope)
            if !TrichFeel.soundsOn { NSSound.beep() }
            return
        }
        host?.setPullZones(zones)
        sender.setOn(turningOn, animated: true)
        TrichFeel.play(turningOn ? .toggleOn : .toggleOff)
        TrichFeel.haptic(.alignment)
    }

    private func startPractice() {
        let started = host?.startPracticeReminder { [weak self] in
            guard let self else { return }
            self.practiced = true; self.skipped.remove(.practice)
            TrichFeel.play(.practiceDone)
            TrichFeel.haptic(.levelChange)
            if self.step == .practice { self.render(animated: false, forward: true) }
            self.window?.makeKeyAndOrderFront(nil)
        } ?? false
        if !started { NSSound.beep() }
    }

    // MARK: Shift practice

    /// The window passes on every Shift change. Only the practice step listens.
    private func shiftKeysChanged(left: Bool, right: Bool) {
        guard step == .practice, let preview else { return }
        let wasBoth = heldKeys.left && heldKeys.right
        if (left && !heldKeys.left) || (right && !heldKeys.right) { TrichFeel.play(.key) }
        heldKeys = (left, right)
        preview.show(left: left, right: right)
        let both = left && right
        if both && !wasBoth {
            holdSeconds = 0
            preview.startHold(seconds: 3)
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdTick() }
            }
            holdTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !both && wasBoth {
            holdTimer?.invalidate()
            holdTimer = nil
            preview.cancelHold()
        }
    }

    private func holdTick() {
        holdSeconds += 1
        preview?.holdTick(holdSeconds)
        guard holdSeconds >= 3 else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        heldKeys = (false, false)
        preview?.finishHold {
            TrichFeel.play(.practiceDone)
            TrichFeel.haptic(.levelChange)
        }
        let first = !rehearsed
        rehearsed = true; skipped.remove(.practice)
        guard first else { return }
        // Let the full ring land before the text below catches up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.step == .practice, let content = self.currentContent as? NSStackView,
                  let hint = content.arrangedSubviews.last else { return }
            let done = self.row(symbol: "checkmark.circle", text: "Nice. That's how you close a reminder.", tint: TrichStyle.cobalt)
            content.removeArrangedSubview(hint)
            hint.removeFromSuperview()
            content.addArrangedSubview(done)
            done.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            done.wantsLayer = true
            if !TrichStyle.reduceMotion, let layer = done.layer {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.duration = 0.3
                layer.add(fade, forKey: nil)
            }
            self.configureButtons(for: .practice)
            NSAccessibility.post(element: self.window as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Nice. That's how you close a reminder.",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func resetHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        heldKeys = (false, false)
    }

    // MARK: Check camera

    private func startCheck() {
        let panel = CameraCheckPanel(scale: textScale)
        checkPanel = panel
        skipped.remove(.check)
        render(animated: false, forward: true, quiet: true)
        host?.startCameraCheck { [weak self, weak panel] state in
            guard let panel else { return }
            let before = panel.state
            panel.update(state)
            if (before == .noAccess) != (state == .noAccess), self?.step == .check {
                self?.configureButtons(for: .check)
            }
        }
    }

    private func stopCheck() {
        guard checkPanel != nil else { return }
        checkPanel = nil
        host?.stopCameraCheck()
    }

    /// Test hook: shows the check step with a reading, without a camera.
    func showCheckForTesting(_ state: CameraCheckState) {
        let panel = CameraCheckPanel(scale: textScale)
        panel.update(state)
        checkPanel = panel
        if step == .check { render(animated: false, forward: true) }
    }

    @objc private func loginToggled(_ sender: NSButton) {
        let wanted = sender.state == .on
        if host?.setOpensAtLogin(wanted) != true {
            sender.state = wanted ? .off : .on
            NSSound.beep()
        } else {
            TrichFeel.play(wanted ? .toggleOn : .toggleOff)
            TrichFeel.haptic(.alignment)
        }
    }

    // MARK: Finish

    /// After Turn On Trich: waiting for macOS camera access, watching, or access turned off.
    enum Farewell { case waiting, watching, cameraOff }
    private(set) var farewell: Farewell?
    private var farewellPoll: Timer?
    private var successCheck: SuccessCheck?

    /// Press first, then the consequence: macOS asks for the camera right away, and the
    /// window stays to show what happened.
    private func turnOnClicked() {
        farewell = .waiting
        stopCameraPoll()
        render(animated: true, forward: true)
        listenForDetection()
        host?.turnOnDetection()
        detectionMaybeOn()
        guard farewell != .watching else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.detectionMaybeOn() }
        }
        farewellPoll = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// After Turn On Trich the mark stays where it is and only the words under it change, so
    /// one object carries the eye through the camera prompt. On success a small check settles
    /// on the tile's corner. Returns nil when the screen needs a full swap instead.
    private func updateFarewellInPlace(_ state: Farewell, animated: Bool) -> NSView? {
        guard state != .cameraOff, let mark = heroMark, let stack = currentContent as? NSStackView,
              stack.arrangedSubviews.first === mark else { return nil }
        stack.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
        func add(_ view: NSView, after spacing: CGFloat) {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(spacing, after: last) }
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let text = farewellText(state)
        add(headline(text.title), after: 32)
        add(body(text.body), after: 16)
        if state == .watching {
            let zones = host?.pullZones ?? [.beard]
            add(secondaryText("Watching your \(PullZone.phrase(for: zones))."), after: 16)
            if successCheck == nil {
                let check = SuccessCheck(side: 24)
                successCheck = check
                mark.addSubview(check)
                NSLayoutConstraint.activate([
                    check.centerXAnchor.constraint(equalTo: mark.trailingAnchor, constant: -4),
                    check.centerYAnchor.constraint(equalTo: mark.bottomAnchor, constant: -4),
                ])
                if animated { check.settle() }
            }
        }
        fitWindow(to: stack)
        contentHost.layoutSubtreeIfNeeded()
        if animated, window?.isVisible == true {
            enterRows(Array(stack.arrangedSubviews.dropFirst()), from: CACurrentMediaTime(), buildHeadline: true)
        }
        return stack
    }

    private func farewellContent(_ state: Farewell) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        func add(_ view: NSView, after spacing: CGFloat) {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(spacing, after: last) }
            stack.addArrangedSubview(view)
            if view is NSTextField || view is Headline {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        switch state {
        case .waiting:
            let mark = LivingMark(side: 72)
            heroMark = mark
            add(mark, after: 0)
        case .watching:
            let check = SuccessCheck(side: 64)
            successCheck = check
            add(check, after: 0)
        case .cameraOff:
            add(symbolTile("video.slash"), after: 0)
        }
        let text = farewellText(state)
        add(headline(text.title), after: 32)
        add(body(text.body), after: 16)
        return stack
    }

    private func farewellText(_ state: Farewell) -> (title: String, body: String) {
        switch state {
        case .waiting: return ("Almost there", "Allow camera access when macOS asks, and Trich starts watching.")
        case .watching: return ("You got this", "Trich is watching. Find it in your menu bar anytime.")
        case .cameraOff:
            if host?.cameraAccess == .restricted {
                return ("The camera is blocked", "This Mac blocks the camera. A work or school profile may be the reason. Ask your IT team to allow it.")
            }
            return ("Camera access is off", "Turn it on in Privacy & Security → Camera, and Trich starts watching.")
        }
    }

    private func configureFarewellButtons(_ state: Farewell) {
        backButton.isHidden = true
        primaryButton.setTitle("Done", scale: textScale)
        primaryAction = { [weak self] in self?.closeAfterFarewell() }
        if state == .cameraOff, host?.cameraAccess != .restricted {
            secondaryButton.isHidden = false
            secondaryButton.setTitle("Open System Settings", scale: textScale)
            secondaryAction = { [weak self] in self?.host?.openCameraSettings() }
        } else {
            secondaryButton.isHidden = true
            secondaryAction = nil
        }
        // Let the success land and hold for a second before offering Done.
        primaryButton.alphaValue = 1
        guard state == .watching, window?.isVisible == true else { return }
        primaryButton.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = TrichStyle.ease
                self?.primaryButton.animator().alphaValue = 1
            }
        }
    }

    private func closeAfterFarewell() {
        guard let window, window.isVisible else { return finish() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = TrichStyle.easeIn
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                self.finish()
                window.alphaValue = 1
            }
        }
    }

    /// Test hook: clicks the primary button.
    func pressPrimaryForTesting() { primaryClicked() }

    /// Test hook: the screen after Turn On Trich, in each state.
    func showFarewellForTesting(_ state: Farewell) {
        if step != .finish { go(to: .finish, animated: false) }
        farewell = state
        render(animated: true, forward: true)
    }

    private func finish() {
        completed = true
        defaults.set(true, forKey: Self.completionKey)
        furthest = .welcome
        step = .welcome
        practiced = false
        rehearsed = false
        farewell = nil
        farewellPoll?.invalidate()
        farewellPoll = nil
        primaryButton.alphaValue = 1
        window?.orderOut(nil)
        stopCameraPoll()
        stopCheck()
        resetHold()
        let completion = onComplete
        onComplete = nil
        onSkip = nil
        completion?()
    }

    /// Chimes once detection really starts, after camera access is granted, even if the
    /// window has closed by then.
    private func listenForDetection() {
        if let detectionObserver { NotificationCenter.default.removeObserver(detectionObserver) }
        let observer = NotificationCenter.default.addObserver(forName: .trichStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detectionMaybeOn() }
        }
        detectionObserver = observer
        // Only this listen's timer may end it, so an older Turn On can't drop a newer observer
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self, weak observer] in
            guard let self, let observer, self.detectionObserver === observer else { return }
            self.stopListeningForDetection()
        }
    }

    private func detectionMaybeOn() {
        let access = host?.cameraAccess
        if host?.detectionIsOn == true, access == .authorized {
            // A window still on "Almost there" updates even after the 120 s listen ends
            guard detectionObserver != nil || farewell == .waiting else { return }
            stopListeningForDetection()
            farewellPoll?.invalidate()
            farewellPoll = nil
            guard farewell != nil, window?.isVisible == true else {
                TrichFeel.play(.success)
                return
            }
            farewell = .watching
            render(animated: true, forward: true)
            // The chime and the tap land with the check, after a quiet beat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.heroMark?.celebrate()
                TrichFeel.play(.success)
                TrichFeel.haptic(.levelChange)
            }
        } else if farewell == .waiting, access == .denied || access == .restricted {
            farewell = .cameraOff
            render(animated: true, forward: true)
        }
    }

    private func stopListeningForDetection() {
        if let detectionObserver { NotificationCenter.default.removeObserver(detectionObserver) }
        detectionObserver = nil
    }

    // Closing with the red button means "skip for now": stay incomplete and remember the step.
    func windowWillClose(_ notification: Notification) {
        stopCameraPoll()
        stopCheck()
        resetHold()
        guard !completed else { return }
        // After Turn On Trich, closing the window is the same as Done.
        if farewell != nil { return finish() }
        let skip = onSkip
        onComplete = nil
        onSkip = nil
        skip?()
    }

    // MARK: Ambient motion

    func windowDidBecomeKey(_ notification: Notification) { updateAmbientRunning() }
    func windowDidResignKey(_ notification: Notification) {
        updateAmbientRunning()
        if step == .practice, heldKeys.left || heldKeys.right { shiftKeysChanged(left: false, right: false) }
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateAmbientRunning() }
    func windowDidMiniaturize(_ notification: Notification) { updateAmbientRunning() }

    /// Breathing and light only run while the window is visible and key.
    private func updateAmbientRunning() {
        guard let window else { return }
        let running = Self.offscreenForTesting ? window.isVisible
            : window.isVisible && window.isKeyWindow && window.occlusionState.contains(.visible)
        ambient?.setRunning(running)
        heroMark?.setRunning(running)
    }

    // MARK: Camera polling

    private func updateCameraPoll() {
        guard step == .camera || step == .finish else { return stopCameraPoll() }
        guard cameraPoll == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let access = self.host?.cameraAccess, access != self.shownAccess else { return }
                self.render(animated: false, forward: true, quiet: true)
            }
        }
        cameraPoll = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopCameraPoll() {
        cameraPoll?.invalidate()
        cameraPoll = nil
    }
}

// MARK: - Window

/// Left Arrow or ⌘[ goes back; Right Arrow or ⌘] continues when the step's main button is Continue.
/// Also reports the two physical Shift keys and where the pointer is, for the practice and parallax.
private final class OnboardingWindow: NSWindow {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onShift: ((Bool, Bool) -> Void)?
    /// The pointer's offset from the window's center, each axis from -1 to 1.
    var onPointer: ((CGPoint) -> Void)?
    private var lastPointer = Date.distantPast

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        acceptsMouseMovedEvents = true
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            // Only the device-side Shift bits, so either Shift alone never counts as both.
            let raw = event.modifierFlags.rawValue
            onShift?(raw & 0x2 != 0, raw & 0x4 != 0)
        case .mouseMoved:
            // About 20 updates a second is plenty for a 1 s ease.
            if Date().timeIntervalSince(lastPointer) > 0.05, let view = contentView {
                lastPointer = Date()
                let p = event.locationInWindow
                let x = (p.x / max(view.bounds.width, 1)) * 2 - 1
                let y = (p.y / max(view.bounds.height, 1)) * 2 - 1
                onPointer?(CGPoint(x: max(-1, min(1, x)), y: max(-1, min(1, y))))
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, command, event.charactersIgnoringModifiers) {
        case (123, _, _), (_, true, "["): onBack?()
        case (124, _, _), (_, true, "]"): onForward?()
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "[": onBack?(); return true
            case "]": onForward?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Views

private final class ColorView: NSView {
    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A frosted card holding rows.
private final class CardView: GlassCard {
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setRows(_ rows: [NSView], spacing: CGFloat = 12) {
        stack.spacing = spacing
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

/// One step in the left rail: a marker (ring with number, check, or outline) and its name.
private final class RailButton: NSButton {
    enum State { case current, done, upcoming }

    let step: OnboardingStep
    private var shown: State?
    private let marker = NSView()
    private let number = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private let name = NSTextField(labelWithString: "")

    init(step: OnboardingStep, scale: CGFloat) {
        self.step = step
        super.init(frame: .zero)
        isBordered = false
        title = ""
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = 8

        marker.wantsLayer = true
        marker.layer?.cornerRadius = 10
        number.font = TrichFont.ui(round(11 * scale), weight: .semibold)
        number.alignment = .center
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        check.contentTintColor = .white
        name.font = TrichFont.ui(round(13 * scale), weight: .medium)
        name.stringValue = step.railTitle

        for view in [marker, number, check, name] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
        }
        addSubview(marker)
        marker.addSubview(number)
        marker.addSubview(check)
        addSubview(name)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: max(32, round(32 * scale))),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 20),
            marker.heightAnchor.constraint(equalToConstant: 20),
            number.centerXAnchor.constraint(equalTo: marker.centerXAnchor),
            number.centerYAnchor.constraint(equalTo: marker.centerYAnchor),
            check.centerXAnchor.constraint(equalTo: marker.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: marker.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 12),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(state: State, number value: Int, total: Int, animated: Bool) {
        let previous = shown
        shown = state
        number.stringValue = "\(value)"
        let hairline = TrichStyle.track.cgColor
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !TrichStyle.reduceMotion ? 0.2 : 0
            context.allowsImplicitAnimation = true
            switch state {
            case .current:
                marker.layer?.backgroundColor = NSColor.clear.cgColor
                marker.layer?.borderColor = TrichStyle.cobalt.cgColor
                marker.layer?.borderWidth = 2
                number.textColor = TrichStyle.text
                name.textColor = TrichStyle.text
                layer?.backgroundColor = TrichStyle.selection.cgColor
            case .done:
                marker.layer?.backgroundColor = TrichStyle.cobalt.cgColor
                marker.layer?.borderWidth = 0
                name.textColor = TrichStyle.text
                layer?.backgroundColor = NSColor.clear.cgColor
            case .upcoming:
                marker.layer?.backgroundColor = NSColor.clear.cgColor
                marker.layer?.borderColor = hairline
                marker.layer?.borderWidth = 1
                number.textColor = TrichStyle.muted
                name.textColor = TrichStyle.muted
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
        number.isHidden = state == .done
        check.isHidden = state != .done
        isEnabled = state != .upcoming
        let stateText = state == .current ? "current" : state == .done ? "done" : "not reached yet"
        setAccessibilityLabel("Step \(value) of \(total), \(step.railTitle), \(stateText)")

        // A step just finished: its check pops in.
        if animated, state == .done, previous == .current, let layer = marker.layer, !TrichStyle.reduceMotion {
            layer.add(TrichMotion.spring("transform", from: TrichMotion.scale(0.9, in: layer),
                                         to: CATransform3DIdentity, duration: 0.24, bounce: 0.1), forKey: "pop")
        }
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
