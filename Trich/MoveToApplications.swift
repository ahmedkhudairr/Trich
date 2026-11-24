import Cocoa
import os

private let log = Logger(subsystem: "io.github.ahmedkhudairr.trich", category: "move")

/// Offers once to move Trich into /Applications when it first runs from somewhere else,
/// such as Downloads or the disk image. Start at Login and updates work best from there.
@MainActor
enum MoveToApplications {
    static let offeredKey = "hasOfferedMoveToApplications"

    /// True when the copy at `path` should be offered a move.
    static func shouldOffer(bundlePath path: String, alreadyOffered: Bool) -> Bool {
        guard !alreadyOffered else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let installed = ["/Applications/", home + "/Applications/"]
        if installed.contains(where: path.hasPrefix) { return false }
        // Builds from Xcode or the command line stay where they are.
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") { return false }
        return true
    }

    /// True when this copy runs from somewhere other than an Applications folder.
    static var isOutsideApplications: Bool {
        shouldOffer(bundlePath: Bundle.main.bundleURL.path, alreadyOffered: false)
    }

    /// Asks once. Returns true if Trich is relaunching from /Applications and this copy should stop.
    static func offerIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        let source = Bundle.main.bundleURL
        guard shouldOffer(bundlePath: source.path, alreadyOffered: defaults.bool(forKey: offeredKey)) else { return false }
        defaults.set(true, forKey: offeredKey)
        return ask(message: "Move Trich to Applications?",
                   info: "Trich works best from your Applications folder.",
                   cancel: "Not Now")
    }

    /// Start at Login failed because Trich isn't in Applications. Offers the move, and quits this copy if it moved.
    static func offerForLoginItem() {
        if ask(message: "Move Trich to Applications first.",
               info: "Start at Login needs Trich in your Applications folder.",
               cancel: "Cancel") {
            NSApp.terminate(nil)
        }
    }

    /// True inside the App Sandbox, where Trich can't move its own bundle.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Returns true if the move worked and the new copy is relaunching.
    private static func ask(message: String, info: String, cancel: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        if isSandboxed {
            offerDrag(info: info, cancel: cancel)
            return false
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: cancel).keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        guard quitOtherCopies(at: destination) else {
            let busy = NSAlert()
            busy.messageText = "Quit the other Trich first, then try again."
            busy.runModal()
            return false
        }
        do {
            try move(from: source, to: destination)
        } catch {
            log.error("Move failed: \(error.localizedDescription, privacy: .public)")
            offerDrag(info: "Trich couldn't move itself. Drag it there in Finder.", cancel: "Not Now")
            return false
        }
        relaunch(at: destination)
        return true
    }

    /// Asks the person to drag Trich over themselves, and shows this copy in Finder if they want.
    private static func offerDrag(info: String, cancel: String) {
        let alert = NSAlert()
        alert.messageText = "Drag Trich to Applications"
        alert.informativeText = info
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: cancel).keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Quits a Trich running from `destination` so the move never trashes a running app. Gives them 3 seconds; returns false if one is still running.
    private static func quitOtherCopies(at destination: URL) -> Bool {
        let others = NSWorkspace.shared.runningApplications.filter { app in
            app != .current && app.bundleURL?.standardizedFileURL == destination.standardizedFileURL
        }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return others.allSatisfy(\.isTerminated)
    }

    /// Copies, then trashes the old copy. A copy that can't be trashed (a disk image) is left alone.
    private static func move(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            try files.trashItem(at: destination, resultingItemURL: nil)
        }
        try files.copyItem(at: source, to: destination)
        // App Translocation runs a read-only copy, so there is nothing to trash there.
        if !source.path.contains("/AppTranslocation/") {
            try? files.trashItem(at: source, resultingItemURL: nil)
        }
    }

    /// Opens the new copy once this one has quit, so the single-instance check doesn't stop it.
    /// The quarantine flag comes off first: Gatekeeper already approved these bytes for this launch,
    /// and a flagged copy could ask again or run from a random read-only place (App Translocation).
    private static func relaunch(at app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; "
            + "/usr/bin/xattr -d -r com.apple.quarantine \"$0\" 2>/dev/null; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, app.path]
        try? process.run()
    }
}
