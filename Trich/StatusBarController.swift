import Cocoa
import AVFoundation
import ServiceManagement
import os

private let log = Logger(subsystem: "io.github.ahmedkhudairr.trich", category: "status")

enum TrichLinks {
    static let help = URL(string: "https://github.com/ahmedkhudairr/Trich#faq")!
    static let website = URL(string: "https://github.com/ahmedkhudairr/Trich")!
    static let releases = URL(string: "https://github.com/ahmedkhudairr/Trich/releases")!
    static let feedback = URL(string: "https://github.com/ahmedkhudairr/Trich/issues/new")!
}

extension OverlayWindowController {
    /// Shows the reminder. The overlay itself speaks the text to VoiceOver once.
    @discardableResult
    func showReminder(onDismiss: @escaping () -> Void) -> Bool {
        showOverlay(onDismiss: onDismiss)
    }
}

@MainActor
final class StatusBarController: NSObject {

    /// What the app is doing right now. Drives the icon and the menu.
    enum Status: Equatable {
        case off, watching, waitingForCamera, cameraDenied, cameraRestricted, noCamera, paused
        case snoozed(until: Date)

        /// `zones` names what is being watched, as in "Watching your beard and eyebrows".
        func menuText(_ zones: Set<PullZone>) -> String {
            switch self {
            case .off:              return "Detection is off"
            case .watching:         return "Watching your \(PullZone.phrase(for: zones))"
            case .waitingForCamera: return "Waiting for camera permission…"
            case .cameraDenied:     return "Camera access is off"
            case .cameraRestricted: return "Camera access is blocked on this Mac"
            case .noCamera:         return "Camera unavailable. Trying again…"
            case .paused:           return "Paused while your Mac is locked or asleep"
            case .snoozed(let until):
                return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
            }
        }

        /// A second, quieter line under the status in the menu.
        var hint: String? {
            switch self {
            case .cameraDenied:     return "Turn it on in Privacy & Security → Camera."
            case .cameraRestricted: return "A work or school profile may block it."
            case .noCamera:         return "Open the lid or connect a camera."
            default:                return nil
            }
        }

        /// Full tt. while watching, faded when off or paused, a dot when the camera needs attention.
        var iconStyle: MenuBarIcon.Style {
            switch self {
            case .watching:                                     return .active
            case .off, .waitingForCamera, .paused, .snoozed:    return .dimmed
            case .cameraDenied, .cameraRestricted, .noCamera:   return .alert
            }
        }
    }

    private enum Defaults {
        static let isActive = "isActive"
        static let pausedUntil = "pausedUntil"
        static let cameraID = "cameraID"
    }

    private static let pauseLength: TimeInterval = 60 * 60
    /// Check Camera counts a face or hand as seen if it showed up this recently, so ✓ doesn't flicker.
    private static let checkMemory: TimeInterval = 1

    private static let cameraSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
    /// Harnesses turn this off, so they never put an icon in the real menu bar.
    static var createsStatusItem = true
    private let statusItem: NSStatusItem? =
        createsStatusItem ? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) : nil
    /// Set on the status item once and filled each time it opens, so a click never meets a menu mid-swap.
    private let statusMenu = NSMenu(title: "Detection")
    /// When the status menu last opened, so the log shows a menu that closed at once.
    private var statusMenuOpenedAt: Date?
    /// The icon last drawn, so a refresh that changes nothing leaves the status item alone.
    private var drawnIcon: (style: MenuBarIcon.Style, label: String)?
    /// Keeps App Nap from throttling detection while Trich watches with every window closed.
    private var watchActivity: NSObjectProtocol?
    private let cameraManager = CameraManager()
    private let poseDetector: PoseDetector

    // Persisted across launches so the user doesn't have to re-enable every time
    private var isActive: Bool {
        didSet {
            UserDefaults.standard.set(isActive, forKey: Defaults.isActive)
            cameraAvailable = true  // try the camera again
            if !isActive { setSnooze(until: nil) }
            refresh()
        }
    }

    private let settings = DetectionSettings(defaults: .standard)

    private var sensitivity: Sensitivity {
        didSet {
            settings.sensitivity = sensitivity
            poseDetector.setSensitivity(sensitivity)
            buildMenu()
        }
    }

    /// What the user pulls. Only these zones are watched.
    private(set) var zones: Set<PullZone> {
        didSet {
            settings.zones = zones
            poseDetector.setZones(zones)
            updateIcon()
            buildMenu()
            NotificationCenter.default.post(name: .trichStatusDidChange, object: self)
        }
    }

    private(set) var status: Status = .off
    private var cameraAvailable = true
    /// Pause for 1 Hour, by the wall clock, so time asleep or locked counts. Kept across relaunches.
    private var snoozeUntil: Date? {
        didSet { UserDefaults.standard.set(snoozeUntil?.timeIntervalSince1970, forKey: Defaults.pausedUntil) }
    }
    private var snoozeTimer: Timer?
    private var pauseReasons: Set<String> = []        // sleep, screen lock, display sleep…
    private var hasRequestedCamera = false
    private var permissionPollTimer: Timer?
    private var cameraRetryTimer: Timer?

    private var cameraCheck: CameraCheckAnalyzer?
    /// One handler per open check (the Check Camera window, onboarding), so neither freezes the other.
    private var cameraCheckHandlers: [ObjectIdentifier: (CameraCheckState) -> Void] = [:]
    private var checkSawFace: TimeInterval = -.infinity
    private var checkSawHand: TimeInterval = -.infinity

    override init() {
        // Detection starts after the user explicitly chooses Turn On.
        isActive = UserDefaults.standard.bool(forKey: Defaults.isActive)
        sensitivity = settings.sensitivity
        zones = settings.zones
        poseDetector = PoseDetector(queue: cameraManager.videoQueue)
        super.init()

        // A fixed name keeps the spot the user ⌘-drags the icon to, away from the notch, across launches.
        statusItem?.autosaveName = "Trich"
        statusMenu.delegate = self
        statusItem?.menu = statusMenu
        poseDetector.setSensitivity(sensitivity)
        poseDetector.setZones(zones)
        poseDetector.delegate = self
        cameraManager.setDelegate(poseDetector)
        cameraManager.selectCamera(id: UserDefaults.standard.string(forKey: Defaults.cameraID))
        cameraManager.onAvailabilityChange = { [weak self] available in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cameraAvailable = available
                if !available { self.sendCheckState(.unavailable) }
                self.refresh()
            }
        }

        let saved = UserDefaults.standard.double(forKey: Defaults.pausedUntil)
        if isActive, saved > Date().timeIntervalSince1970 {
            setSnooze(until: Date(timeIntervalSince1970: saved))
        } else {
            snoozeUntil = nil
        }

        observeSleepAndLock()
        refresh()
        // Never empty, even if macOS reads the menu before asking it to update
        fill(statusMenu, forMainMenu: false)
    }

    // MARK: - State

    /// Works out what should be happening, starts/stops the camera to match, and updates the UI
    private func refresh() {
        let newStatus = computeStatus()
        if newStatus != status { log.info("Status: \(String(describing: newStatus), privacy: .public)") }
        let leftWatching = status == .watching && newStatus != .watching
        if (status == .watching) != (newStatus == .watching) {
            poseDetector.setEnabled(newStatus == .watching)
        }
        status = newStatus
        holdOffAppNap(newStatus == .watching)

        if newStatus == .watching || cameraCheckNeedsCamera {
            cameraManager.start()
        } else {
            cameraManager.stop()
            // Only a real change out of watching closes a reminder, so a practice reminder runs its full time.
            if leftWatching { OverlayWindowController.shared.dismissOverlay() }
        }

        // Check grants and revocation independently of capture-session notifications.
        if [.waitingForCamera, .cameraDenied, .cameraRestricted, .watching].contains(newStatus) {
            if permissionPollTimer == nil {
                permissionPollTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.computeStatus() != self.status else { return }
                        self.refresh()
                    }
                }
                permissionPollTimer?.tolerance = 0.5  // lets macOS fold it into other wakeups
                RunLoop.main.add(permissionPollTimer!, forMode: .common)
            }
        } else {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }

        // The camera can be busy (right after wake) or stalled (lid closed). Retry quietly:
        // status stays "unavailable" until frames really arrive, so it never flickers to Watching.
        // An open Check Camera retries too, even with detection off.
        if newStatus == .noCamera || (cameraCheck != nil && !cameraAvailable) {
            if cameraRetryTimer == nil {
                cameraRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cameraManager.retry() }
                }
            }
        } else {
            cameraRetryTimer?.invalidate()
            cameraRetryTimer = nil
        }

        updateIcon()
        buildMenu()
        NotificationCenter.default.post(name: .trichStatusDidChange, object: self)
    }

    private func computeStatus() -> Status {
        guard isActive else { return .off }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            if !hasRequestedCamera {
                hasRequestedCamera = true
                AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                    DispatchQueue.main.async {
                        // Permission can be reset while Trich runs, so a later reset can ask again.
                        self?.hasRequestedCamera = false
                        self?.refresh()
                    }
                }
            }
            return .waitingForCamera
        case .restricted:
            return .cameraRestricted
        default:
            return .cameraDenied
        }

        if let until = snoozeUntil {
            if until > Date() { return .snoozed(until: until) }
            setSnooze(until: nil)
        }
        if !pauseReasons.isEmpty { return .paused }
        if !cameraAvailable { return .noCamera }
        return .watching
    }

    // MARK: - UI

    private var statusLine: String { status.menuText(zones) }

    private func updateIcon() {
        let style = status.iconStyle, label = "Trich, \(statusLine)"
        if let drawnIcon, drawnIcon.style == style, drawnIcon.label == label { return }
        drawnIcon = (style, label)
        statusItem?.button?.image = MenuBarIcon.image(style, accessibilityDescription: label)
        statusItem?.button?.toolTip = "Trich: \(statusLine)"
        statusItem?.button?.setAccessibilityLabel(label)
    }

    private func holdOffAppNap(_ watching: Bool) {
        if watching, watchActivity == nil {
            watchActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching for hands")
        } else if !watching, let activity = watchActivity {
            ProcessInfo.processInfo.endActivity(activity)
            watchActivity = nil
        }
    }

    /// Briefly highlights the menu bar icon so onboarding can point at it.
    func highlightIcon() {
        statusItem?.button?.highlight(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.statusItem?.button?.highlight(false)
        }
    }

    /// Both Detection menus fill themselves as they open (see `menuNeedsUpdate`). This only hooks up
    /// the main menu's copy, which AppDelegate creates.
    func buildMenu() {
        guard let mainDetection = NSApp.mainMenu?.item(withTitle: "Detection")?.submenu,
              mainDetection.delegate !== self else { return }
        mainDetection.delegate = self
    }

    /// The status item gets "Turn On Detection"; the main menu's Detection menu keeps the docs' "Detection → Turn On".
    func fill(_ menu: NSMenu, forMainMenu: Bool) {
        menu.removeAllItems()

        let statusRow = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        menu.addItem(statusRow)
        if let hint = status.hint {
            let hintLine = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
            hintLine.isEnabled = false
            hintLine.indentationLevel = 1
            menu.addItem(hintLine)
        }
        if status == .cameraDenied {
            menu.addItem(item("Open Camera Settings…", #selector(openCameraSettings)))
        }

        menu.addItem(.separator())
        let toggleTitle = isActive ? "Turn Off" : "Turn On"
        menu.addItem(item(forMainMenu ? toggleTitle : "\(toggleTitle) Detection", #selector(toggleDetection)))
        if case .snoozed = status {
            menu.addItem(item("Resume Now", #selector(resumeNow)))
        } else if isActive {
            menu.addItem(item("Pause for 1 Hour", #selector(pauseForAnHour)))
        }

        let zonesItem = NSMenuItem(title: "Watch For", action: nil, keyEquivalent: "")
        let zonesMenu = NSMenu()
        for zone in PullZone.allCases {
            let zoneItem = item(zone.title, #selector(toggleZone(_:)))
            zoneItem.representedObject = zone.rawValue
            zoneItem.state = zones.contains(zone) ? .on : .off
            zonesMenu.addItem(zoneItem)
        }
        zonesMenu.addItem(.separator())
        let all = item("All", #selector(watchAllZones))
        all.state = zones.count == PullZone.allCases.count ? .on : .off
        zonesMenu.addItem(all)
        zonesItem.submenu = zonesMenu
        menu.addItem(zonesItem)
        if showsZonesTip {
            let tip = NSMenuItem(title: "Trich can watch eyebrows and scalp too.", action: nil, keyEquivalent: "")
            tip.isEnabled = false
            tip.indentationLevel = 1
            menu.addItem(tip)
        }

        let sensitivityItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        let sensitivityMenu = NSMenu()
        for level in Sensitivity.allCases {
            let levelItem = item(Self.sensitivityTitle(level), #selector(chooseSensitivity(_:)))
            levelItem.representedObject = level.rawValue
            levelItem.state = level == sensitivity ? .on : .off
            sensitivityMenu.addItem(levelItem)
        }
        sensitivityItem.submenu = sensitivityMenu
        menu.addItem(sensitivityItem)

        // Filled in when opened, so a camera plugged in later shows up.
        let cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        let cameraMenu = NSMenu(title: "Camera")
        cameraMenu.delegate = self
        cameraItem.submenu = cameraMenu
        menu.addItem(cameraItem)
        menu.addItem(item("Check Camera…", #selector(checkCamera)))

        menu.addItem(.separator())
        menu.addItem(item("Practice Reminder", #selector(practiceReminder)))
        let login = item("Start at Login", #selector(toggleOpenAtLogin))
        login.state = opensAtLogin ? .on : .off
        menu.addItem(login)

        // Kept apart from the settings above, so a slip can't reach it
        menu.addItem(.separator())
        menu.addItem(item("Clear Reminder History…", #selector(clearHistory)))

        // The app and Help menus already hold these.
        if !forMainMenu {
            menu.addItem(item("Open Dashboard", #selector(openDashboard), key: "d"))
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
            menu.addItem(item("Send Feedback…", #selector(sendFeedback)))
            menu.addItem(item("Trich Help", #selector(openHelp)))
            menu.addItem(item("Quit Trich", #selector(quitApp), key: "q"))
        }
    }

    /// People who set up Trich before it had areas hear about them once, the first time a Detection menu opens.
    private var showsZonesTip: Bool {
        !settings.hasChosenZones && UserDefaults.standard.bool(forKey: OnboardingWindowController.completionKey)
    }

    /// A filled copy, for tests and menu dumps.
    func makeMenu(forMainMenu: Bool) -> NSMenu {
        let menu = NSMenu(title: "Detection")
        fill(menu, forMainMenu: forMainMenu)
        return menu
    }

    static func sensitivityTitle(_ level: Sensitivity) -> String {
        switch level {
        case .low:    return "Low (fewer reminders)"
        case .medium: return "Medium"
        case .high:   return "High (more reminders)"
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Controls shared with the dashboard and onboarding

    var detectionIsOn: Bool { isActive }

    /// At least one zone always stays on.
    func setZones(_ newZones: Set<PullZone>) {
        guard !newZones.isEmpty else { return }
        if newZones == zones {
            // Saved anyway, so keeping beard counts as a choice
            settings.zones = newZones
        } else {
            zones = newZones
        }
    }

    func setDetection(_ on: Bool) {
        if isActive != on { isActive = on }
    }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns false if macOS refused, for example for a copy outside Applications.
    /// If the person turned Trich off in Login Items before, macOS needs their OK there, so that page opens.
    @discardableResult
    func setOpensAtLogin(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        defer { NotificationCenter.default.post(name: .trichStatusDidChange, object: self) }
        if on, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return true
        }
        return opensAtLogin == on
    }

    // MARK: - Actions

    @objc private func toggleDetection() {
        isActive.toggle()
    }

    @objc private func chooseSensitivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let level = Sensitivity(rawValue: raw) else { return }
        sensitivity = level
    }

    @objc private func toggleZone(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let zone = PullZone(rawValue: raw) else { return }
        var next = zones
        if next.contains(zone) { next.remove(zone) } else { next.insert(zone) }
        // Unticking the last zone would watch nothing
        if next.isEmpty { NSSound.beep(); return }
        setZones(next)
    }

    @objc private func watchAllZones() {
        setZones(Set(PullZone.allCases))
    }

    @objc private func pauseForAnHour() {
        setSnooze(until: Date().addingTimeInterval(Self.pauseLength))
        refresh()
    }

    @objc private func resumeNow() {
        setSnooze(until: nil)
        refresh()
    }

    /// Timers don't count time asleep, so wake, unlock and clock changes also refresh (see observeSleepAndLock).
    private func setSnooze(until: Date?) {
        snoozeUntil = until
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        guard let until else { return }
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        snoozeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func toggleOpenAtLogin() {
        let on = !opensAtLogin
        if setOpensAtLogin(on) { return }
        if on, MoveToApplications.isOutsideApplications {
            MoveToApplications.offerForLoginItem()
        } else {
            NSSound.beep()
        }
    }

    @objc func openCameraSettings() {
        NSWorkspace.shared.open(Self.cameraSettingsURL)
    }

    @objc private func openHelp() {
        NSWorkspace.shared.open(TrichLinks.help)
    }

    @objc private func checkForUpdates() {
        NSWorkspace.shared.open(TrichLinks.releases)
    }

    @objc private func sendFeedback() {
        NSWorkspace.shared.open(TrichLinks.feedback)
    }

    @objc private func checkCamera() {
        CameraCheckWindowController.shared.host = self
        CameraCheckWindowController.shared.show()
    }

    @objc private func chooseCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: Defaults.cameraID)
        cameraManager.selectCamera(id: id)
    }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear reminder history?"
        alert.informativeText = "This deletes all saved reminder times. It can't be undone."
        alert.addButton(withTitle: "Cancel")
        let clear = alert.addButton(withTitle: "Clear History")
        clear.hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn {
            PickStore.shared.clear()
            NotificationCenter.default.post(name: .trichHistoryDidChange, object: nil)
        }
    }

    @objc private func practiceReminder() {
        OverlayWindowController.shared.showReminder {}
    }

    @objc private func openDashboard() {
        DashboardWindowController.shared.show()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Sleep / lock

    /// Stop the camera while nobody can be at the Mac; start again afterwards
    private func observeSleepAndLock() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(String, Notification.Name, Notification.Name)] = [
            ("sleep",   NSWorkspace.willSleepNotification,          NSWorkspace.didWakeNotification),
            ("display", NSWorkspace.screensDidSleepNotification,    NSWorkspace.screensDidWakeNotification),
            ("session", NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        for (reason, pauseName, resumeName) in pairs {
            workspace.addObserver(forName: pauseName, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(true, reason: reason) }
            }
            workspace.addObserver(forName: resumeName, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(false, reason: reason) }
            }
        }

        // The pause end and the "until" time follow the wall clock and the time zone.
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(true, reason: "lock") }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(false, reason: "lock") }
        }
    }

    private func setPaused(_ paused: Bool, reason: String) {
        if paused {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
            // A missed unlock notification would otherwise leave Trich paused until restart.
            if !Self.screenIsLocked { pauseReasons.remove("lock") }
            cameraAvailable = true  // try the camera again after wake/unlock
        }
        refresh()
    }

    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

// MARK: - PoseDetectorDelegate

extension StatusBarController: PoseDetectorDelegate {
    nonisolated func poseDetector(_ detector: PoseDetector, didDetectPullingAt zone: PullZone) {
        // Always called on main thread (dispatched in PoseDetector)
        MainActor.assumeIsolated {
            // Check Camera asks for a hand near the face. That test is never a reminder or saved.
            if cameraCheck != nil {
                poseDetector.startCooldown()
                return
            }
            guard status == .watching, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                poseDetector.resume()
                refresh()
                return
            }
            let shown = OverlayWindowController.shared.showReminder { [weak self] in
                // Overlay dismissed by the user. Start cooldown before detection resumes
                self?.poseDetector.startCooldown()
            }
            if shown {
                PickStore.shared.record(zone)  // For the dashboard
                NotificationCenter.default.post(name: .trichHistoryDidChange, object: nil)
            } else {
                // A reminder (often a practice one) is already up, or no screen is available.
                // Wait as if one just closed, instead of re-detecting several times a second.
                poseDetector.startCooldown()
            }
        }
    }
}

// MARK: - DashboardDetection

extension StatusBarController: DashboardDetection {
    /// With camera access off, the dashboard shows an Open Settings button instead of the hint.
    var statusText: String {
        guard status != .cameraDenied, let hint = status.hint else { return statusLine }
        return "\(statusLine). \(hint)"
    }

    var dashboardState: DashboardState {
        switch status {
        case .off: return .off
        case .watching: return .watching
        case .cameraDenied: return .cameraDenied
        default: return .other
        }
    }
}

// MARK: - Menus

extension StatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu { fill(menu, forMainMenu: false); return }
        if menu === NSApp.mainMenu?.item(withTitle: "Detection")?.submenu { fill(menu, forMainMenu: true); return }
        guard menu.title == "Camera" else { return }
        menu.removeAllItems()
        let cameras = CameraManager.availableCameras()
        let chosen = CameraCandidate.choose(from: cameras,
                                            preferredID: UserDefaults.standard.string(forKey: Defaults.cameraID))
        for camera in cameras {
            let cameraItem = item(camera.name, #selector(chooseCamera(_:)))
            cameraItem.representedObject = camera.id
            cameraItem.state = camera.id == chosen?.id ? .on : .off
            cameraItem.isEnabled = !camera.isSuspended
            menu.addItem(cameraItem)
        }
        if cameras.isEmpty {
            let none = NSMenuItem(title: "No camera found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }

    /// Kept in the system log, so a click that "shows nothing" can be traced:
    /// `log show --last 10m --predicate 'subsystem == "io.github.ahmedkhudairr.trich" AND category == "status"'`.
    /// No line means the click never reached Trich (a reminder was up, or System Settings → Menu Bar
    /// hid the icon). An open and close within a second, with no choice, usually means the icon sat
    /// in the menu bar's overflow next to the notch.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu || menu === NSApp.mainMenu?.item(withTitle: "Detection")?.submenu else { return }
        if menu === statusMenu {
            statusMenuOpenedAt = Date()
            log.notice("Status menu opened (\(String(describing: self.status), privacy: .public))")
        }
        if showsZonesTip { settings.zones = zones }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu, let openedAt = statusMenuOpenedAt else { return }
        statusMenuOpenedAt = nil
        log.notice("Status menu closed after \(Date().timeIntervalSince(openedAt), format: .fixed(precision: 1), privacy: .public) s")
    }
}

// MARK: - CameraCheckHost

extension StatusBarController: CameraCheckHost {
    /// Runs the camera even with detection off, unless the Mac is asleep or locked or the camera failed.
    private var cameraCheckNeedsCamera: Bool {
        cameraCheck != nil && cameraAvailable && pauseReasons.isEmpty
            && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// The Check Camera window's check.
    func startCameraCheck(onChange: @escaping (CameraCheckState) -> Void) {
        startCameraCheck(owner: CameraCheckWindowController.shared, onChange: onChange)
    }

    func stopCameraCheck() {
        stopCameraCheck(owner: CameraCheckWindowController.shared)
    }

    /// Starts a check for `owner`. The camera keeps running until every owner has stopped.
    func startCameraCheck(owner: AnyObject, onChange: @escaping (CameraCheckState) -> Void) {
        let key = ObjectIdentifier(owner)
        cameraCheckHandlers[key] = onChange
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            onChange(.starting)
            AVCaptureDevice.requestAccess(for: .video) { [weak self, weak owner] _ in
                DispatchQueue.main.async {
                    guard let self, let owner, let handler = self.cameraCheckHandlers[ObjectIdentifier(owner)] else { return }
                    self.startCameraCheck(owner: owner, onChange: handler)
                }
            }
            return
        case .restricted:
            onChange(.blocked)
            return
        default:
            onChange(.noAccess)
            return
        }

        checkSawFace = -.infinity
        checkSawHand = -.infinity
        if cameraCheck == nil {
            let analyzer = CameraCheckAnalyzer { [weak self] face, hand in
                MainActor.assumeIsolated { self?.noteCheckReading(face: face, hand: hand) }
            }
            analyzer.next = poseDetector
            cameraManager.setDelegate(analyzer)
            cameraCheck = analyzer
        }
        if cameraAvailable {
            onChange(.starting)
        } else {
            onChange(.unavailable)
            cameraManager.retry()
        }
        refresh()
    }

    func stopCameraCheck(owner: AnyObject) {
        cameraCheckHandlers[ObjectIdentifier(owner)] = nil
        guard cameraCheckHandlers.isEmpty, cameraCheck != nil else { return }
        cameraCheck = nil
        cameraManager.setDelegate(poseDetector)
        refresh()
    }

    private func sendCheckState(_ state: CameraCheckState) {
        cameraCheckHandlers.values.forEach { $0(state) }
    }

    private func noteCheckReading(face: Bool, hand: Bool) {
        guard !cameraCheckHandlers.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if face { checkSawFace = now }
        if hand { checkSawHand = now }
        sendCheckState(.live(face: now - checkSawFace < Self.checkMemory, hand: now - checkSawHand < Self.checkMemory))
    }
}
