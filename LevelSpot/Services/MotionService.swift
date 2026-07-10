import Foundation
import CoreMotion
import Observation

/// Where a tilt reading can come from. The live scan renders the same regardless of source —
/// a paired spare device (phase 2, BLE) just becomes a different implementation of this.
protocol SensorSource {
    var rollDeg: Double { get }
    var pitchDeg: Double { get }
    var isSteady: Bool { get }
}

@Observable
final class MotionService: SensorSource {
    /// Vehicle-frame angles after calibration. Conventions match LevelSpotCore:
    /// roll > 0 = left side high, pitch > 0 = front high. Mounting instruction: phone flat
    /// (screen up), top of the phone toward the front of the vehicle.
    private(set) var rollDeg: Double = 0
    private(set) var pitchDeg: Double = 0
    /// False while the vehicle is moving/being rocked — the scan shows lower confidence.
    private(set) var isSteady: Bool = true
    private(set) var isRunning = false

    private let manager = CMMotionManager()
    private let defaults = UserDefaults.standard

    // Flat-surface calibration offsets. Small-angle subtraction is adequate at the tilts a
    // parked vehicle sees (<6°); a full attitude-matrix calibration is a later refinement.
    private var rollOffset: Double {
        get { defaults.double(forKey: "calib.rollOffset") }
        set { defaults.set(newValue, forKey: "calib.rollOffset") }
    }
    private var pitchOffset: Double {
        get { defaults.double(forKey: "calib.pitchOffset") }
        set { defaults.set(newValue, forKey: "calib.pitchOffset") }
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !isRunning else { return }
        isRunning = true
        manager.deviceMotionUpdateInterval = 1.0 / 10.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            // Device flat, screen up, top toward vehicle front:
            //   attitude.pitch = rotation about device x (left-right axis) = vehicle pitch
            //   attitude.roll  = rotation about device y (front-back axis) = vehicle roll
            let rawPitch = m.attitude.pitch * 180 / .pi
            let rawRoll = -(m.attitude.roll * 180 / .pi) // device roll right-high positive -> vehicle left-high positive
            self.pitchDeg = rawPitch - self.pitchOffset
            self.rollDeg = rawRoll - self.rollOffset
            let rotation = abs(m.rotationRate.x) + abs(m.rotationRate.y) + abs(m.rotationRate.z)
            self.isSteady = rotation < 0.15
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
    }

    /// Whether the phone has ever been zeroed on flat ground. Stored (not computed) so the UI
    /// updates the moment calibration happens. Essential on modern phones — the camera bump means
    /// a phone laid face-up on a flat surface reads a constant few-degree tilt until it's zeroed.
    private(set) var isCalibrated = UserDefaults.standard.object(forKey: "calib.rollOffset") != nil

    /// Flat-surface calibration: whatever the sensor reads right now becomes zero, cancelling the
    /// phone/camera-bump/mounting offset. Call it on ground you KNOW is flat.
    func calibrateHere() {
        rollOffset += rollDeg
        pitchOffset += pitchDeg
        rollDeg = 0
        pitchDeg = 0
        isCalibrated = true
    }

    /// Undo a calibration (e.g. one saved on a slope by mistake) — back to the raw sensor.
    func resetCalibration() {
        defaults.removeObject(forKey: "calib.rollOffset")
        defaults.removeObject(forKey: "calib.pitchOffset")
        isCalibrated = false
    }

    #if targetEnvironment(simulator) || DEBUG
    /// Drive the scan without hardware (simulator previews, demo walkthroughs).
    func simulate(rollDeg: Double, pitchDeg: Double) {
        self.rollDeg = rollDeg
        self.pitchDeg = pitchDeg
        self.isSteady = true
    }
    #endif
}
