import Foundation

/// Persists reminder times across launches using UserDefaults, one list per zone.
/// Each entry is a Date recorded when a detected reminder shows.
@MainActor
final class PickStore {
    static let shared = PickStore()

    /// The beard keeps the key it had before zones, so earlier history still counts.
    static let baseKey = "trich.pickEvents"
    static func key(for zone: PullZone) -> String {
        zone == .beard ? baseKey : "\(baseKey).\(zone.rawValue)"
    }

    private let defaults: UserDefaults
    private(set) var byZone: [PullZone: [Date]] = [:]

    /// Every zone's reminders, oldest first
    private(set) var events: [Date] = []

    private static let retention: TimeInterval = 90 * 86400

    // Events stamped up to a day ahead (the clock ran fast, then was corrected) are kept
    // and moved to now. Anything further ahead is treated as bad data.
    private static let futureTolerance: TimeInterval = 86400
    private static let capacity = 10000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let now = Date().timeIntervalSince1970
        for zone in PullZone.allCases {
            // Read entries one by one, so a single bad value can't wipe the whole history
            let raw = (defaults.array(forKey: Self.key(for: zone)) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            let kept = Self.normalized(raw, now: now)
            if !kept.isEmpty { byZone[zone] = kept.map { Date(timeIntervalSince1970: $0) } }
            save(zone)
        }
        merge()
    }

    func record(_ zone: PullZone = .beard) {
        let now = Date().timeIntervalSince1970
        let times = (byZone[zone] ?? []).map(\.timeIntervalSince1970)
        let kept = Self.normalized(times, now: now).suffix(Self.capacity - 1)
        byZone[zone] = (kept + [now]).map { Date(timeIntervalSince1970: $0) }
        save(zone)
        merge()
    }

    /// Reminders per zone at or after `start`, leaving out zones with none.
    func counts(since start: Date) -> [PullZone: Int] {
        byZone.compactMapValues { dates in
            let count = dates.filter { $0 >= start }.count
            return count > 0 ? count : nil
        }
    }

    /// Finite, within retention, future stamps clamped to now, sorted, capped.
    static func normalized(_ times: [Double], now: TimeInterval) -> [Double] {
        let kept = times.compactMap { time -> Double? in
            guard time.isFinite, time >= now - retention, time <= now + futureTolerance else { return nil }
            return min(time, now)
        }
        return Array(kept.sorted().suffix(capacity))
    }

    func clear() {
        byZone.removeAll()
        events.removeAll()
        for zone in PullZone.allCases { defaults.removeObject(forKey: Self.key(for: zone)) }
    }

    private func merge() {
        events = byZone.values.flatMap { $0 }.sorted()
    }

    /// Zones with no history leave no key behind.
    private func save(_ zone: PullZone) {
        let times = (byZone[zone] ?? []).map(\.timeIntervalSince1970)
        if times.isEmpty {
            defaults.removeObject(forKey: Self.key(for: zone))
        } else {
            defaults.set(times, forKey: Self.key(for: zone))
        }
    }
}
