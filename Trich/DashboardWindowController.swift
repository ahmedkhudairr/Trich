import Cocoa
import SwiftUI
import Charts

/// Which empty-state line the dashboard shows.
enum DashboardState { case off, watching, cameraDenied, other }

/// What the dashboard header needs. StatusBarController provides it; tests use a fake.
@MainActor
protocol DashboardDetection: AnyObject {
    var detectionIsOn: Bool { get }
    var statusText: String { get }
    var dashboardState: DashboardState { get }
    func setDetection(_ on: Bool)
    func openCameraSettings()
}

/// Everything the dashboard view draws. The controller keeps it current.
@MainActor
final class DashboardModel: ObservableObject {
    @Published var events: [Date] = []
    /// Reminders per area over the same 7 days as the "Last 7 days" figure
    @Published var weekByZone: [PullZone: Int] = [:]
    @Published var now = Date()
    @Published var statusText = ""
    @Published var detectionIsOn = false
    @Published var state = DashboardState.off
    var setDetection: (Bool) -> Void = { _ in }
    var openCameraSettings: () -> Void = {}
}

@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowController()

    weak var detection: DashboardDetection? {
        didSet { updateStatus() }
    }

    /// Lazy so tests can swap in a store with isolated defaults first.
    lazy var store: PickStore = .shared

    private(set) var window: NSWindow?
    private let model = DashboardModel()

    private override init() {
        super.init()
        model.setDetection = { [weak self] on in self?.detection?.setDetection(on) }
        model.openCameraSettings = { [weak self] in self?.detection?.openCameraSettings() }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(statusChanged), name: .trichStatusDidChange, object: nil)
        center.addObserver(self, selector: #selector(reload), name: .trichHistoryDidChange, object: nil)
        // The day-change note can come late or off the main thread, so coming back to the window reloads too.
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reload()
    }

    /// Harnesses render the window far off screen, without taking focus.
    static var offscreenForTesting = false

    func show() {
        if window == nil { makeWindow() }
        guard let window else { return }
        updateStatus()
        reload()
        if Self.offscreenForTesting {
            window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
            window.orderFrontRegardless()
            return
        }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reload() {
        let now = Date()
        let calendar = Calendar.current
        let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        model.events = store.events
        model.weekByZone = store.counts(since: weekStart)
        model.now = now
    }

    @objc private func statusChanged() {
        updateStatus()
    }

    private func updateStatus() {
        guard let detection else { return }
        model.statusText = detection.statusText
        model.detectionIsOn = detection.detectionIsOn
        model.state = detection.dashboardState
    }

    // MARK: - Window

    private func makeWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 576),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Trich"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 440, height: 520)
        win.setFrameAutosaveName("Dashboard")
        win.delegate = self
        window = win
        buildContent()
    }

    /// Glass behind a SwiftUI view. The glass is rebuilt when light or dark mode switches;
    /// SwiftUI redraws itself.
    private func buildContent() {
        guard let win = window else { return }
        let root = TrichStyle.applyGlass(to: win) { [weak self] in self?.buildContent() }
        let hosting = NSHostingView(rootView: DashboardView(model: model))
        hosting.sizingOptions = []  // the window keeps its own size
        hosting.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: root.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }
}

// MARK: - View

private struct Palette {
    let text, muted, hairline, surface, background, cobalt: Color

    @MainActor init(_ scheme: ColorScheme) {
        let dark = scheme == .dark
        text = Color(nsColor: TrichStyle.text(dark: dark))
        muted = Color(nsColor: TrichStyle.muted(dark: dark))
        hairline = Color(nsColor: TrichStyle.hairline(dark: dark))
        surface = Color(nsColor: TrichStyle.surface(dark: dark))
        background = Color(nsColor: TrichStyle.background(dark: dark))
        cobalt = Color(nsColor: TrichStyle.cobalt)
    }
}

private struct Day: Identifiable {
    let date: Date
    let count: Int
    let isToday: Bool
    var id: Date { date }
}

/// A whole number that counts when its value animates.
private struct CountText: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text("\(Int(value.rounded()))") }
}

private struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 to 1 while the first open of a launch counts up the numbers and grows the bars.
    @State private var bars: Double = 1
    @State private var counts: Double = 1
    private static var playedEntrance = false

    private var palette: Palette { Palette(scheme) }
    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: model.now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 24)
            Rectangle().fill(palette.hairline).frame(height: 1)
            if model.events.isEmpty {
                emptyState
            } else {
                history.padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: playEntrance)
    }

    /// Once per launch, with Reduce Motion off: numbers count up in 700 ms, bars grow in 400 ms.
    private func playEntrance() {
        guard !Self.playedEntrance, !reduceMotion, !DashboardWindowController.offscreenForTesting,
              !model.events.isEmpty else { return }
        Self.playedEntrance = true
        bars = 0
        counts = 0
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.4)) { bars = 1 }
        withAnimation(.easeOut(duration: 0.7)) { counts = 1 }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            TrichMarkImage()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trich")
                    .font(TrichFont.swiftUI(17, weight: .semibold))
                    .foregroundStyle(palette.text)
                Text(model.statusText)
                    .font(TrichFont.swiftUI(13))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if model.state == .cameraDenied {
                Button("Open Settings") { model.openCameraSettings() }
                    .buttonStyle(PillButtonStyle(fill: palette.text, label: palette.background, reduceMotion: reduceMotion))
                    .accessibilityLabel("Open Camera Settings")
            } else if model.detectionIsOn {
                Button("Turn Off") { model.setDetection(false) }
                    .buttonStyle(QuietButtonStyle(color: palette.text))
                    .padding(.trailing, -12)
                    .accessibilityLabel("Turn Off Detection")
            } else {
                Button("Turn On") { model.setDetection(true) }
                    .buttonStyle(PillButtonStyle(fill: palette.text, label: palette.background, reduceMotion: reduceMotion))
                    .accessibilityLabel("Turn On Detection")
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        let message: String
        switch model.state {
        case .off: message = "No reminders yet. Turn on detection to start."
        case .watching: message = "No reminders yet. Trich is watching."
        case .cameraDenied, .other: message = "No reminders yet."
        }
        return Text(message)
            .font(TrichFont.swiftUI(14))
            .foregroundStyle(palette.muted)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: History

    private var days: [Day] {
        (0..<14).map { offset in
            let date = calendar.date(byAdding: .day, value: offset - 13, to: today) ?? today
            let count = model.events.filter { calendar.isDate($0, inSameDayAs: date) }.count
            return Day(date: date, count: count, isToday: offset == 13)
        }
    }

    private var history: some View {
        let days = self.days
        let todayCount = days.last?.count ?? 0
        let weekCount = days.suffix(7).reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 32) {
                stat(todayCount, "Today")
                stat(weekCount, "Last 7 days")
            }
            if let split = zoneSplit {
                Text(split)
                    .font(TrichFont.swiftUI(13))
                    .foregroundStyle(palette.muted)
                    .padding(.top, 8)
            }
            chartPanel(days)
                .padding(.top, 24)
            if let peak = peakHour {
                Text("Most often around \(Text(peak).foregroundColor(palette.text).fontWeight(.medium))")
                    .foregroundStyle(palette.muted)
                    .font(TrichFont.swiftUI(13))
                    .padding(.top, 16)
            }
            Text("Saved only on this Mac, for 90 days.")
                .font(TrichFont.swiftUI(12))
                .foregroundStyle(palette.muted)
                .padding(.top, 16)
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CountText(value: Double(value) * counts)
                .font(TrichFont.swiftUI(32, weight: .semibold, width: 108))
                .foregroundStyle(palette.text)
            Text(label)
                .font(TrichFont.swiftUI(13))
                .foregroundStyle(palette.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }

    private func chartPanel(_ days: [Day]) -> some View {
        let top = Double(max(1, days.map(\.count).max() ?? 1))
        return VStack(alignment: .leading, spacing: 16) {
            Text("Last 14 days")
                .font(TrichFont.swiftUI(13, weight: .medium))
                .foregroundStyle(palette.muted)
            Chart(days) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Reminders", (day.count == 0 ? top * 0.015 : Double(day.count)) * bars),
                    width: .ratio(0.6)
                )
                .foregroundStyle(day.count == 0 ? palette.hairline : day.isToday ? palette.cobalt : palette.muted.opacity(0.5))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                .annotation(position: .top, spacing: 4) {
                    if day.count > 0 {
                        Text("\(day.count)")
                            .font(TrichFont.swiftUI(12))
                            .foregroundStyle(day.isToday ? palette.text : palette.muted)
                            .opacity(bars)
                    }
                }
                .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .accessibilityValue(day.count == 1 ? "1 reminder" : "\(day.count) reminders")
            }
            .chartYScale(domain: 0...(top * 1.25))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: days.map(\.date)) { value in
                    if let date = value.as(Date.self) {
                        let isToday = calendar.isDate(date, inSameDayAs: today)
                        AxisValueLabel(centered: true) {
                            Text("\(calendar.component(.day, from: date))")
                                .font(TrichFont.swiftUI(12, weight: isToday ? .semibold : .regular))
                                .foregroundStyle(isToday ? palette.text : palette.muted)
                        }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.overlay(alignment: .bottom) { Rectangle().fill(palette.hairline).frame(height: 1) }
            }
            .frame(height: 160)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: model.events)
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.hairline))
    }

    /// "Beard 12, Eyebrows 3 in the last 7 days", once more than one area has reminders.
    private var zoneSplit: String? {
        let counts = PullZone.allCases.compactMap { zone in model.weekByZone[zone].map { "\(zone.title) \($0)" } }
        guard counts.count > 1 else { return nil }
        return counts.joined(separator: ", ") + " in the last 7 days"
    }

    /// The most common hour, once there are at least 10 reminders over 3 days.
    private var peakHour: String? {
        let events = model.events
        let distinctDays = Set(events.map { calendar.startOfDay(for: $0) }).count
        guard events.count >= 10, distinctDays >= 3 else { return nil }
        var hours = Array(repeating: 0, count: 24)
        for event in events { hours[calendar.component(.hour, from: event)] += 1 }
        guard let peak = hours.indices.max(by: { hours[$0] < hours[$1] }),
              let date = calendar.date(bySettingHour: peak, minute: 0, second: 0, of: today) else { return nil }
        return date.formatted(.dateTime.hour())
    }
}

/// The primary button: text color behind background-colored text, 16:1 in both modes.
/// Presses scale to 0.97; with Reduce Motion they dim instead.
private struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let label: Color
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TrichFont.swiftUI(14, weight: .semibold))
            .foregroundStyle(label)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.85 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct QuietButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TrichFont.swiftUI(14))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The vector tt. mark, drawn by AppKit at the window's backing scale.
private struct TrichMarkImage: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView(image: TrichMark.image(small: true))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {}
}
