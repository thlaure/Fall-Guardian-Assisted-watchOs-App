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

    private var defaultsObserver: NSObjectProtocol?

    private override init() {
        super.init()
    }

    // MARK: - Public

    func start() {
        guard !motionManager.isAccelerometerActive else { return }

        // Start WCSession before the accelerometer guard — communication with the
        // phone is independent of sensor availability (e.g. works in the simulator).
        WatchSessionManager.shared.startSession()

        guard motionManager.isAccelerometerAvailable else { return }

        loadThresholdsFromDefaults()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadThresholdsFromDefaults()
        }

        motionManager.accelerometerUpdateInterval = 1.0 / sampleRateHz
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data, error == nil else { return }
            self.process(data: data)
        }
    }

    func stop() {
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        motionManager.stopAccelerometerUpdates()
        algorithm.reset()
    }

    // MARK: - Private

    private func loadThresholdsFromDefaults() {
        let d = UserDefaults.standard
        algorithm.freeFallThresholdG = d.object(forKey: "thresh_freefall") != nil ? d.double(forKey: "thresh_freefall") : 0.5
        algorithm.impactThresholdG   = d.object(forKey: "thresh_impact")   != nil ? d.double(forKey: "thresh_impact")   : 2.5
        algorithm.tiltThresholdDeg   = d.object(forKey: "thresh_tilt")     != nil ? d.double(forKey: "thresh_tilt")     : 45.0
        algorithm.freeFallMinMs      = d.object(forKey: "thresh_freefall_ms") != nil ? d.double(forKey: "thresh_freefall_ms") : 80.0
    }

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
