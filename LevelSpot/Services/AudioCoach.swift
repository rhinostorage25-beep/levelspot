import Foundation
import AVFoundation
import Observation

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
    private var beep: AVAudioPCMBuffer?
    private var levelBeep: AVAudioPCMBuffer?
    private var lowBeep: AVAudioPCMBuffer?

    private var ticker: Timer?
    private var started = false

    // Live state, written by update(); read by the fixed-rate ticker so cadence never depends on
    // how often the sensor fires (rescheduling a timer every sensor frame would starve the beep).
    private var enabled = true
    private var isLevelState = false
    private var beyondState = false
    private var offMM: Double = 0
    private var tolMM: Double = 20
    private var accum: Double = 0
    private var announcedLevel = false

    private static let tickInterval = 0.05

    func start() {
        guard !started else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            beep = Self.tone(freq: 880, ms: 70, format: format)
            levelBeep = Self.tone(freq: 1_320, ms: 200, format: format)
            lowBeep = Self.tone(freq: 220, ms: 180, format: format)
            try engine.start()
            node.play()
            started = true
            let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)   // keep ticking during scroll/interaction
            ticker = t
        } catch {
            started = false   // fail silent
        }
    }

    func stop() {
        ticker?.invalidate(); ticker = nil
        node.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        started = false
        accum = 0
        announcedLevel = false
    }

    /// Push the current scan state. `offMM` is how un-level the van is (corner spread);
    /// `toleranceMM` is the "level enough" band. Cheap to call every sensor frame.
    func update(offMM: Double, toleranceMM: Double, isLevel: Bool, beyond: Bool, enabled: Bool) {
        self.offMM = offMM
        self.tolMM = max(toleranceMM, 1)
        self.isLevelState = isLevel
        self.beyondState = beyond
        self.enabled = enabled
    }

    private func tick() {
        guard started, enabled else { accum = 0; return }
        if isLevelState {
            if !announcedLevel {                 // rising two-note chime, once, on reaching level
                announcedLevel = true
                schedule(levelBeep)
                schedule(levelBeep)
            }
            accum = 0
            return
        }
        announcedLevel = false
        accum += Self.tickInterval
        // Far off = slow (~1.2s), near the tolerance band = fast (~0.15s).
        let ratio = min(max(offMM / (tolMM * 8), 0), 1)
        let target = beyondState ? 1.4 : (0.15 + ratio * 1.05)
        if accum >= target {
            accum = 0
            schedule(beyondState ? lowBeep : beep)
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
