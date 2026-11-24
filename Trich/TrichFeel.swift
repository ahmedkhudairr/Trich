import AudioToolbox
import Cocoa

/// Soft sounds and trackpad haptics for onboarding.
///
/// Every sound is synthesized here: small mallet and glass tones, no samples. They play as
/// system sounds, so they follow the alert volume and the "Play sound effects through" device,
/// only when the Mac's "Play user interface sound effects" setting is on, and never after the
/// person mutes them.
@MainActor
enum TrichFeel {
    enum Sound: Hashable, Sendable {
        /// Moving to a step. Each step has its own note, so the setup plays a rising tune.
        case step(Int)
        case toggleOn, toggleOff
        /// A Shift key going down in the practice.
        case key
        /// Can't do that, softly.
        case nope
        /// The Shift practice or the practice reminder finished.
        case practiceDone
        /// Detection turned on.
        case success

        static let all: [Sound] = (0..<8).map(Sound.step) + [.toggleOn, .toggleOff, .key, .nope, .practiceDone, .success]

        var name: String {
            switch self {
            case .step(let n): return "step-\(n + 1)"
            case .toggleOn: return "toggle-on"
            case .toggleOff: return "toggle-off"
            case .key: return "key"
            case .nope: return "nope"
            case .practiceDone: return "practice-done"
            case .success: return "success"
            }
        }
    }

    static let mutedKey = "soundEffectsMuted"
    /// Where the mute choice lives. Tests point it at a private suite.
    static var defaults: UserDefaults = .standard
    /// Test hook: no sound and no haptics at all.
    static var silent = false

    /// The Mac's Sound settings → "Play user interface sound effects".
    static var systemAllowsSounds: Bool {
        (UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool) ?? true
    }

    static var muted: Bool {
        get { defaults.bool(forKey: mutedKey) }
        set { defaults.set(newValue, forKey: mutedKey) }
    }

    static var soundsOn: Bool { !silent && !muted && systemAllowsSounds }

    private static var soundIDs: [Sound: SystemSoundID] = [:]
    private static var preparing = false

    /// The WAVs live in the app's Caches folder; macOS may clear them, and they are rebuilt.
    private static var soundFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Trich").appendingPathComponent("sounds")
    }

    /// Synthesizes and registers every sound on a utility queue, so the first click never waits.
    static func prepare() {
        guard !silent, soundIDs.isEmpty, !preparing else { return }
        preparing = true
        let folder = soundFolder
        DispatchQueue.global(qos: .utility).async {
            var made: [Sound: SystemSoundID] = [:]
            for sound in Sound.all {
                if let id = SoundSynth.register(sound, in: folder) { made[sound] = id }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    soundIDs.merge(made) { current, _ in current }
                    preparing = false
                }
            }
        }
    }

    static func play(_ sound: Sound) {
        guard soundsOn else { return }
        // While prepare() is writing the files, skip this sound rather than write the same file twice
        if soundIDs[sound] == nil, !preparing, let id = SoundSynth.register(sound, in: soundFolder) { soundIDs[sound] = id }
        guard let id = soundIDs[sound] else { return }
        AudioServicesPlaySystemSoundWithCompletion(id, nil)
    }

    /// Felt only on a Force Touch trackpad, and only while a finger rests on it.
    static func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic) {
        guard !silent else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// Writes every sound as a WAV at playback level, so the set can be listened to outside the app.
    static func exportSounds(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for sound in Sound.all {
            try SoundSynth.wav(for: sound).write(to: folder.appendingPathComponent("\(sound.name).wav"))
        }
    }
}

// MARK: - Synthesis

/// Builds the sounds. Free of the main actor so it can run on a utility queue.
private enum SoundSynth {
    /// Writes one sound to `folder` and registers it as a system sound.
    static func register(_ sound: TrichFeel.Sound, in folder: URL) -> SystemSoundID? {
        let url = folder.appendingPathComponent("\(sound.name).wav")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try wav(for: sound).write(to: url, options: .atomic)
        } catch {
            return nil
        }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        return id
    }

    private static let rate = 44_100.0

    /// One struck tone. Partials are (ratio to the fundamental, level, how much faster they fade).
    private struct Voice {
        var partials: [(Double, Double, Double)]
        var decay: Double

        /// Wooden bar: a strong fourth-ish overtone that dies fast, like a soft marimba mallet.
        static let mallet = Voice(partials: [(1, 1, 1), (3.93, 0.22, 3.2), (9.6, 0.04, 7)], decay: 0.22)
        /// Small glass bell: slightly inharmonic, rings longer.
        static let glass = Voice(partials: [(1, 1, 1), (2.32, 0.16, 1.7), (4.18, 0.07, 2.6), (6.1, 0.025, 4)], decay: 0.55)
        /// A tiny dry tick for keys.
        static let tick = Voice(partials: [(1, 1, 1), (2.7, 0.3, 2)], decay: 0.035)
    }

    /// C major pentatonic from C5, one note per step.
    private static let stepNotes = [523.25, 587.33, 659.26, 783.99, 880.0, 1046.5, 1174.66, 1318.51]

    static func wav(for sound: TrichFeel.Sound) -> Data {
        var notes: [(freq: Double, at: Double, voice: Voice, level: Double)] = []
        var length = 0.5
        var peak = 0.5
        switch sound {
        case .step(let n):
            let f = stepNotes[min(max(n, 0), stepNotes.count - 1)]
            notes = [(f, 0, .mallet, 1), (f * 2, 0, .glass, 0.12)]
        case .toggleOn:
            notes = [(1567.98, 0, .glass, 1)]
            length = 0.45; peak = 0.32
        case .toggleOff:
            notes = [(1174.66, 0, .glass, 1)]
            length = 0.35; peak = 0.24
        case .key:
            notes = [(2093, 0, .tick, 1)]
            length = 0.12; peak = 0.18
        case .nope:
            notes = [(261.63, 0, .mallet, 1), (246.94, 0.09, .mallet, 0.8)]
            length = 0.5; peak = 0.3
        case .practiceDone:
            notes = [(783.99, 0, .mallet, 0.9), (1046.5, 0.11, .mallet, 1), (2093, 0.11, .glass, 0.18)]
            length = 0.8; peak = 0.5
        case .success:
            // A gentle rolled chord: C, E, G, C.
            notes = [(523.25, 0, .glass, 0.8), (659.26, 0.07, .glass, 0.75), (783.99, 0.14, .glass, 0.7), (1046.5, 0.21, .glass, 0.8)]
            length = 1.0; peak = 0.55
        }

        let count = Int(length * rate)
        var samples = [Double](repeating: 0, count: count)
        for note in notes {
            let start = Int(note.at * rate)
            for i in start..<count {
                let t = Double(i - start) / rate
                // 4 ms raised-cosine attack, so nothing clicks
                let attack = t < 0.004 ? 0.5 - 0.5 * cos(.pi * t / 0.004) : 1
                var value = 0.0
                for (ratio, level, fade) in note.voice.partials {
                    value += level * sin(2 * .pi * note.freq * ratio * t) * exp(-t * fade / note.voice.decay)
                }
                samples[i] += note.level * attack * value
            }
        }

        // A little room: two quiet early reflections.
        for (delay, gain) in [(0.031, 0.16), (0.067, 0.09)] {
            let offset = Int(delay * rate)
            for i in stride(from: count - 1, through: offset, by: -1) { samples[i] += gain * samples[i - offset] }
        }
        // Round off the top end, then a short fade out so the tail never cuts.
        var smoothed = 0.0
        let alpha = 1 - exp(-2 * .pi * 7000 / rate)
        for i in 0..<count {
            smoothed += alpha * (samples[i] - smoothed)
            let tail = Double(count - i) / (0.03 * rate)
            samples[i] = smoothed * min(1, tail)
        }
        // Peaks near -24 dBFS at full alert volume, a quiet UI level.
        let maximum = samples.map(abs).max() ?? 1
        let gain = maximum > 0 ? peak * 0.4 * 0.32 / maximum : 0
        return encode(samples.map { $0 * gain })
    }

    /// 16-bit mono PCM WAV.
    private static func encode(_ samples: [Double]) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32_767))) }
        return data
    }
}
