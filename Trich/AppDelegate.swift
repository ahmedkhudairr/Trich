import Cocoa
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?
    private var launchedAtLogin = false

    // @main requires a static entry point, so NSApplication is set up by hand
    // so we can keep AppDelegate as the @main type without @NSApplicationMain
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A second copy would run a second camera session and icon. Hand over to the copy already
        // running and bring its window forward, unless this copy is newer: then the old one steps aside.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if let first = others.first {
            if Self.version(of: first.bundleURL) >= Self.version(of: Bundle.main.bundleURL), let url = first.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                NSApp.terminate(nil)
                return
            }
            others.forEach { $0.terminate() }
        }
        TrichFont.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The launch Apple event only exists from here on.
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchedAtLogin = event.eventID == kAEOpenApplication
                && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        }
        // Login items started by SMAppService may not say so in the event. A launch within two
        // minutes of logging in, with Start at Login on, counts as one too.
        if !launchedAtLogin, let since = Self.secondsSinceLogin(), since < 120 {
            launchedAtLogin = SMAppService.mainApp.status == .enabled
        }

        if !launchedAtLogin, MoveToApplications.offerIfNeeded() {
            NSApp.terminate(nil)
            return
        }

        // The menu bar provides detection controls.
        let statusBar = StatusBarController()
        statusBarController = statusBar
        configureMenu()
        statusBar.buildMenu()
        DashboardWindowController.shared.detection = statusBar
        OnboardingWindowController.shared.host = self
        CameraCheckWindowController.shared.host = statusBar

        if UserDefaults.standard.bool(forKey: OnboardingWindowController.completionKey) {
            // Stay quiet in the menu bar at login or while already watching. Opening Trich again shows the dashboard.
            if !launchedAtLogin && !statusBar.detectionIsOn { DashboardWindowController.shared.show() }
        } else if !launchedAtLogin {
            showIntroduction(startOver: true)
        }
    }

    /// CFBundleVersion of the app at `url`, compared as a number.
    private static func version(of url: URL?) -> Int {
        guard let url, let value = Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String else { return 0 }
        return Int(value) ?? 0
    }

    /// How long ago this user logged in at the console, from the login records.
    private static func secondsSinceLogin() -> TimeInterval? {
        setutxent()
        defer { endutxent() }
        let user = NSUserName()
        var latest: TimeInterval?
        while let entry = getutxent() {
            var record = entry.pointee
            guard record.ut_type == USER_PROCESS else { continue }
            let name = withUnsafeBytes(of: &record.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let line = withUnsafeBytes(of: &record.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == user, line == "console" else { continue }
            let time = TimeInterval(record.ut_tv.tv_sec) + TimeInterval(record.ut_tv.tv_usec) / 1_000_000
            latest = max(latest ?? 0, time)
        }
        return latest.map { Date().timeIntervalSince1970 - $0 }
    }

    // MARK: - Menus

    private func configureMenu() {
        let menu = NSMenu()

        let appMenu = NSMenu(title: "Trich")
        appMenu.addItem(withTitle: "About Trich", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d").target = self
        appMenu.addItem(withTitle: "Show Introduction", action: #selector(showIntroductionFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Practice Reminder", action: #selector(practiceReminder), keyEquivalent: "r").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Trich", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Trich", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: menu)

        // StatusBarController fills this one in.
        addSubmenu(NSMenu(title: "Detection"), to: menu)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        addSubmenu(windowMenu, to: menu)
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Trich Help", action: #selector(openHelp), keyEquivalent: "?").target = self
        helpMenu.addItem(withTitle: "Trich on GitHub", action: #selector(openWebsite), keyEquivalent: "").target = self
        helpMenu.addItem(withTitle: "Send Feedback…", action: #selector(sendFeedback), keyEquivalent: "").target = self
        addSubmenu(helpMenu, to: menu)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = menu
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    // MARK: - Actions

    private func showIntroduction(startOver: Bool) {
        OnboardingWindowController.shared.show(startOver: startOver, onComplete: {
            DashboardWindowController.shared.show()
        }, onSkip: {
            DashboardWindowController.shared.show()
        })
    }

    @objc private func showIntroductionFromMenu() {
        showIntroduction(startOver: true)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openDashboard() {
        DashboardWindowController.shared.show()
    }

    @objc private func practiceReminder() {
        OverlayWindowController.shared.showReminder {}
    }

    @objc private func checkForUpdates() { NSWorkspace.shared.open(TrichLinks.releases) }
    @objc private func openHelp() { NSWorkspace.shared.open(TrichLinks.help) }
    @objc private func openWebsite() { NSWorkspace.shared.open(TrichLinks.website) }
    @objc private func sendFeedback() { NSWorkspace.shared.open(TrichLinks.feedback) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if OverlayWindowController.shared.isShowing { return true }
        if !UserDefaults.standard.bool(forKey: OnboardingWindowController.completionKey) {
            if !OnboardingWindowController.shared.bringToFrontIfVisible() { showIntroduction(startOver: false) }
        } else {
            DashboardWindowController.shared.show()
        }
        return true
    }

    // Keep detection available when the dashboard closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Onboarding

extension AppDelegate: OnboardingHost {
    var cameraAccess: CameraAccess { CameraAccess.current }
    var detectionIsOn: Bool { statusBarController?.detectionIsOn ?? false }
    var opensAtLogin: Bool { statusBarController?.opensAtLogin ?? false }
    var pullZones: Set<PullZone> { statusBarController?.zones ?? [.beard] }
    func setPullZones(_ zones: Set<PullZone>) { statusBarController?.setZones(zones) }

    func openCameraSettings() { statusBarController?.openCameraSettings() }

    func startPracticeReminder(onClose: @escaping () -> Void) -> Bool {
        OverlayWindowController.shared.showReminder(onDismiss: onClose)
    }

    func highlightMenuBarIcon() { statusBarController?.highlightIcon() }
    func turnOnDetection() { statusBarController?.setDetection(true) }
    func setOpensAtLogin(_ on: Bool) -> Bool { statusBarController?.setOpensAtLogin(on) ?? false }

    func startCameraCheck(onChange: @escaping (CameraCheckState) -> Void) {
        statusBarController?.startCameraCheck(owner: OnboardingWindowController.shared, onChange: onChange)
    }
    func stopCameraCheck() { statusBarController?.stopCameraCheck(owner: OnboardingWindowController.shared) }
}
