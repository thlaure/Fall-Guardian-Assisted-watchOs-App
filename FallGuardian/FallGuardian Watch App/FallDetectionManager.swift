import Foundation
import CoreMotion

/// Runs the PSP fall detection algorithm using CMMotionManager at 50 Hz.
/// Uses WKExtendedRuntimeSession for background sensor access.
class FallDetectionManager: NSObject {

    static let shared = FallDetectionManager()

    private let motionManager = CMMotionManager()
    private let algorithm = FallAlgorithm()
    private var extendedSession: AnyObject? // WKExtendedRuntimeSession (weakly typed to avoid WatchKit import here)

    var onFallDetected: (() -> Void)?

    private var lastFallMs: Double = 0
    private let cooldownMs: Double = 5_000

    private let sampleRateHz: Double = 50
    var isRunning: Bool { motionManager.isAccelerometerActive }

    private override init() {
        super.init()
    }

    // MARK: - Public

    func start() {
        guard !motionManager.isAccelerometerActive else { return }
        guard motionManager.isAccelerometerAvailable else { return }

        motionManager.accelerometerUpdateInterval = 1.0 / sampleRateHz
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data, error == nil else { return }
            self.process(data: data)
        }

        WatchSessionManager.shared.startSession()
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
        algorithm.reset()
    }

    func updateThresholds(
        freeFall: Double? = nil,
        impact: Double? = nil,
        tilt: Double? = nil,
        freeFallMs: Double? = nil
    ) {
        if let v = freeFall { algorithm.freeFallThresholdG = v }
        if let v = impact   { algorithm.impactThresholdG = v }
        if let v = tilt     { algorithm.tiltThresholdDeg = v }
        if let v = freeFallMs { algorithm.freeFallMinMs = v }
    }

    // MARK: - Private

    private func process(data: CMAccelerometerData) {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let ax = data.acceleration.x
        let ay = data.acceleration.y
        let az = data.acceleration.z

        let detected = algorithm.processSample(ax: ax, ay: ay, az: az, nowMs: nowMs)

        if detected && (nowMs - lastFallMs > cooldownMs) {
            lastFallMs = nowMs
            algorithm.reset()
            WatchSessionManager.shared.sendFallEvent()
            onFallDetected?()
        }
    }
}
