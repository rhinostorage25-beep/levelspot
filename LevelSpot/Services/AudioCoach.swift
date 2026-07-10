import Foundation
import AVFoundation
import Observation
import UIKit

/// Audio levelling guidance so you don't have to watch the screen while you drive up the ramp
/// (the phone sits flat in the cab; you're outside). A "parking-sensor" idiom: the proximity
/// beep speeds up as the van approaches level, a rising chime confirms level, and a slow low
/// tone means the tilt is beyond what a ramp can fix (reposition). It plays over the silent
/// switch (.playback) and ducks music rather than stopping it.
///
/// Fail-silent by design: any audio-session/engine error just disables the beeps — audio is an
/// aid, it must never block or crash the levelling flow.
@MainActor
@Observable
final class AudioCoach {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var tones: [AVAudioPCMBuffer] = []   // low→high pitch, chosen by how close to level
    private var levelBeep: AVAudioPCMBuffer?
    private var lowBeep: AVAudioPCMBuffer?

    private var ticker: Timer?
    private var started = false
    private var observers: [NSObjectProtocol] = []

    // Live state, written by update(); read by the fixed-rate ticker so cadence never depends on
    // how often the sensor fires (rescheduling a timer every sensor frame would starve the beep).
    private var enabled = true
    private var coaching = false   // only true once update() feeds live state — keeps the tick silent
    private var isLevelState = false
    private var beyondState = false
    private var offMM: Double = 0
    private var tolMM: Double = 20
    private var accum: Double = 0
    private var announcedLevel = false

    private static let tickInterval = 0.05

    func start() {
        guard !started else { return }
        guard configureEngine() else { return }   // fail silent
        started = true
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // keep ticking during scroll/interaction
        ticker = t
        registerObservers()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        ticker?.invalidate(); ticker = nil
        node.stop()
        engine.stop()
        // notifyOthersOnDeactivation lets music/other audio resume, and hands the session cleanly
        // to whatever comes next (e.g. the AR camera measure) instead of leaving it wedged.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        started = false
        accum = 0
        announcedLevel = false
    }

    /// Stand up (or re-stand-up) the playback session + engine. Idempotent enough to call again
    /// after an interruption without tearing everything down.
    @discardableResult
    private func configureEngine() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return false }
            if node.engine == nil { engine.attach(node) }
            engine.connect(node, to: engine.mainMixerNode, format: format)
            if tones.isEmpty {
                // 12 notes across ~1.8 octaves — the closer to level, the higher the note.
                let ladder: [Double] = [440, 494, 554, 622, 698, 784, 880, 988, 1109, 1245, 1397, 1568]
                tones = ladder.compactMap { Self.tone(freq: $0, ms: 110, format: format) }
                levelBeep = Self.tone(freq: 1_760, ms: 240, format: format)   // the "you're there" chime
                lowBeep = Self.tone(freq: 196, ms: 200, format: format)       // the "can't level" low tone
            }
            if !engine.isRunning { try engine.start() }
            node.play()
            return true
        } catch {
            return false
        }
    }

    /// The camera measure, a phone call, unplugging headphones, or the engine's hardware config
    /// changing all knock the beeps out. These notifications are the "you're clear again" signal —
    /// re-claim the playback session so the coach doesn't stay silent until the app is relaunched.
    private func registerObservers() {
        let nc = NotificationCenter.default
        let recover: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in if self?.started == true { self?.configureEngine() } }
        }
        var tokens: [NSObjectProtocol] = []
        // Only re-claim when an interruption ENDS, not when it begins.
        tokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor in if self?.started == true { self?.configureEngine() } }
        })
        tokens.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main, using: recover))
        tokens.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main, using: recover))
        tokens.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: recover))
        observers = tokens
    }

    /// A single loud "you're LEVEL" alert — a rising triple chime. For the live dial, where the
    /// engine's running: one unmistakable hit, not a stream of quiet beeps.
    func alertLevel() {
        guard started else { return }
        schedule(levelBeep); schedule(levelBeep); schedule(levelBeep)
    }

    /// Push the current scan state. `offMM` is how un-level the van is (corner spread);
    /// `toleranceMM` is the "level enough" band. Cheap to call every sensor frame.
    func update(offMM: Double, toleranceMM: Double, isLevel: Bool, beyond: Bool, enabled: Bool) {
        self.offMM = offMM
        self.tolMM = max(toleranceMM, 1)
        self.isLevelState = isLevel
        self.beyondState = beyond
        self.enabled = enabled
        self.coaching = true
    }

    private func tick() {
        guard started, coaching, enabled else { accum = 0; return }
        accum += Self.tickInterval

        if isLevelState {
            if !announcedLevel {                          // rising two-note chime, once, on reaching level
                announcedLevel = true
                schedule(levelBeep); schedule(levelBeep)
                accum = 0
                return
            }
            // A slow steady top-note pulse so you KNOW you're still level (not just silence).
            if accum >= 0.6 { accum = 0; schedule(tones.last) }
            return
        }
        announcedLevel = false

        if beyondState {                                  // can't level here — slow, low, ominous
            if accum >= 1.4 { accum = 0; schedule(lowBeep) }
            return
        }

        // Directional by pitch: as you drive up and approach level the note RISES up the ladder
        // and the beeps quicken; past level it falls again — so you can level entirely by ear.
        // Mapped across ~400mm of corner spread (≈0–7° on a typical van) so the pitch AUDIBLY
        // tracks the angle across the whole range, not just the last half-degree before level.
        let ratio = min(max(offMM / 400, 0), 1)           // 0 ≈ at level, 1 = ~7°+ off
        let proximity = 1 - ratio
        let interval = 0.5 - proximity * 0.4              // far ~0.5s → near ~0.1s
        if accum >= interval {
            accum = 0
            let idx = min(tones.count - 1, max(0, Int((proximity * Double(tones.count - 1)).rounded())))
            if !tones.isEmpty { schedule(tones[idx]) }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer?) {
        guard started, let buffer else { return }
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    /// A single sine tone with a short attack/decay envelope so it doesn't click.
    private static func tone(freq: Double, ms: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(sr * Double(ms) / 1_000)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buf.floatChannelData else { return nil }
        buf.frameLength = frames
        let n = Int(frames)
        let attack = sr * 0.005
        let release = sr * 0.02
        for i in 0..<n {
            let t = Double(i) / sr
            let env = min(1, Double(i) / attack) * min(1, Double(n - i) / release)
            channel[0][i] = Float(sin(2 * .pi * freq * t) * 0.6 * env)
        }
        return buf
    }
}
