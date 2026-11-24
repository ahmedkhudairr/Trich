import Cocoa

/// Which physical Shift keys are down. Built only from the two device-side Shift bits.
struct ShiftKeys: Equatable {
    var left = false
    var right = false
    var both: Bool { left && right }

    init(left: Bool = false, right: Bool = false) {
        self.left = left
        self.right = right
    }

    init(flags: UInt64) {
        left = flags & ShiftKeys.leftMask != 0
        right = flags & ShiftKeys.rightMask != 0
    }

    static let leftMask: UInt64 = 0x00000002
    static let rightMask: UInt64 = 0x00000004
}

/// Samples only the two physical Shift keys while a reminder is visible.
/// No event tap, typed-character observation, or keyboard-event recording.
@MainActor
final class KeyMonitor {
    var onUnlockGestureCompleted: (() -> Void)?

    /// Called when a key goes down or up, and once per whole second of a two-key hold.
    /// The interval is how long both keys have been held (0 unless both are down).
    var onShiftKeysChanged: ((ShiftKeys, TimeInterval) -> Void)?

    static let requiredHoldDuration: TimeInterval = 3

    private var holdTimer: Timer?
    private var hold = ShiftHoldState()
    private var lastKeys = ShiftKeys()
    private var lastWholeSeconds = 0
    private let modifierFlags: () -> UInt64
    private let uptime: () -> TimeInterval

    init(
        modifierFlags: @escaping () -> UInt64 = { CGEventSource.flagsState(.hidSystemState).rawValue },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.modifierFlags = modifierFlags
        self.uptime = uptime
    }

    func startMonitoring() {
        guard holdTimer == nil else { return }
        hold = ShiftHoldState()
        lastKeys = ShiftKeys()
        lastWholeSeconds = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHold() }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        checkHold()
    }

    func stopMonitoring() {
        holdTimer?.invalidate()
        holdTimer = nil
        hold = ShiftHoldState()
    }

    private func checkHold() {
        // One consistent snapshot; retain only the physical Shift bits.
        let flags = modifierFlags() & (ShiftKeys.leftMask | ShiftKeys.rightMask)
        let now = uptime()
        hold.update(flags: flags, at: now)

        let keys = ShiftKeys(flags: flags)
        let held = hold.heldDuration(at: now)
        let wholeSeconds = Int(held)
        if keys != lastKeys || wholeSeconds != lastWholeSeconds {
            lastKeys = keys
            lastWholeSeconds = wholeSeconds
            onShiftKeysChanged?(keys, held)
        }

        guard hold.isComplete(at: now, duration: Self.requiredHoldDuration) else { return }
        stopMonitoring()
        onUnlockGestureCompleted?()
    }
}

/// Pure timing state shared by the live monitor and regression tests.
struct ShiftHoldState {
    private var started: TimeInterval?
    var isHoldingBoth: Bool { started != nil }

    mutating func update(flags: UInt64, at time: TimeInterval) {
        if ShiftKeys(flags: flags).both {
            if started == nil { started = time }
        } else {
            started = nil
        }
    }

    func heldDuration(at time: TimeInterval) -> TimeInterval {
        guard let started else { return 0 }
        return max(0, time - started)
    }

    func isComplete(at time: TimeInterval, duration: TimeInterval) -> Bool {
        guard started != nil else { return false }
        return heldDuration(at: time) >= duration
    }
}
