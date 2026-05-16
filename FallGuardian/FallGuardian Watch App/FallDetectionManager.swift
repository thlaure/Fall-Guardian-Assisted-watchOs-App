// FallDetectionManager.swift
// Fall Guardian — watchOS
//
// This file is the "sensor driver": it owns the accelerometer hardware,
// feeds raw samples into FallAlgorithm, and fires a callback when a fall
// is confirmed.  It also coordinates the startup sequence so that the
// phone communication channel (WatchSessionManager) is ready before any
// fall event could possibly occur.
//
// Position in the data pipeline:
//   Apple Watch hardware accelerometer
//       ↓  50 samples/second via CMMotionManager
//   FallDetectionManager.process(data:)  ← YOU ARE HERE
//       ↓  passes (ax, ay, az, nowMs) to the algorithm
//   FallAlgorithm.processSample()  →  returns Bool
//       ↓  on true: fires onFallDetected callback AND calls WatchSessionManager
//   ContentViewModel.alertDidFire()  →  shows UI countdown
//   WatchSessionManager.sendFallEvent()  →  notifies iPhone

import Foundation  // Date, NotificationCenter, UserDefaults, NSObjectProtocol
import CoreMotion  // CMMotionManager and CMAccelerometerData — Apple's accelerometer API

/// Manages the accelerometer session and drives the fall-detection algorithm at 50 Hz.
///
/// ## Why 50 Hz?
/// A free-fall event during a human fall typically lasts 80–300 ms.  Sampling at
/// 50 Hz (one sample every 20 ms) gives us 4–15 samples during free-fall, which
/// is enough for the duration filter in FallAlgorithm to work reliably.  Higher
/// rates (100+ Hz) would consume more battery without meaningful accuracy gains.
///
/// ## Singleton (`shared`)
/// Only one accelerometer session should exist at a time.  The singleton pattern
/// ensures ContentView, background tasks, and the debug debug simulator all share
/// the same session rather than competing for the hardware.
///
/// ## Background sensor access
/// watchOS suspends apps that leave the foreground.  `WKExtendedRuntimeSession`
/// (referenced below as `extendedSession`) asks the OS for extra CPU and sensor
/// time so detection keeps running when the user lowers their wrist.  The session
/// type is stored as `AnyObject?` to avoid importing WatchKit in this file, which
/// keeps the file compilable in unit-test targets that mock WatchKit.
class FallDetectionManager: NSObject {

    // MARK: - Singleton

    /// The one shared instance used by the entire app.
    /// `NSObject` subclass + private `init()` enforces the singleton.
    static let shared = FallDetectionManager()

    // MARK: - Dependencies

    /// Apple's motion framework object.  Once started, it pushes new accelerometer
    /// samples to our closure at the requested interval on the specified queue.
    private let motionManager = CMMotionManager()

    /// The stateless algorithm that processes each sample.
    /// Stateless here means: the algorithm only depends on data you hand it, not
    /// on any global state — making it deterministic and easy to test.
    private let algorithm = FallAlgorithm()

    /// Holds a WKExtendedRuntimeSession so the OS does not suspend the app while
    /// the watch face is off.  Typed as AnyObject to avoid a WatchKit import in
    /// this file (WatchKit transitively pulls in UIKit, which breaks pure-logic targets).
    private var extendedSession: AnyObject?

    // MARK: - Callbacks and rate control

    /// The UI registers a closure here.  When a fall is confirmed this closure is
    /// called with the millisecond timestamp of the detection.
    /// ContentViewModel sets this in `startIfNeeded()`.
    var onFallDetected: ((Int64) -> Void)?

    /// Timestamp of the most recent confirmed fall, used to enforce the cooldown.
    private var lastFallMs: Double = 0

    /// Minimum time (ms) that must elapse before a second fall can be reported.
    /// 5 seconds prevents the same fall from firing the alarm multiple times
    /// while the person is still hitting the ground and bouncing.
    private let cooldownMs: Double = 5_000

    // MARK: - Configuration

    /// How many accelerometer readings per second we request.
    /// The actual sample rate delivered by the OS may be slightly different.
    private let sampleRateHz: Double = 50

    /// Read-only property that lets callers check whether the accelerometer is
    /// currently streaming.  Delegates directly to CMMotionManager's own flag.
    var isRunning: Bool { motionManager.isAccelerometerActive }

    // MARK: - UserDefaults observation

    /// Token returned by NotificationCenter when we subscribe to settings changes.
    /// Holding it allows us to unsubscribe cleanly in `stop()`, preventing memory
    /// leaks and phantom callbacks after the manager is stopped.
    private var defaultsObserver: NSObjectProtocol?

    // Private init enforces singleton usage via `FallDetectionManager.shared`.
    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Starts the full detection pipeline.
    ///
    /// Call order matters:
    /// 1. Start WatchSessionManager first (phone comm channel is independent of sensors).
    /// 2. Guard: bail if the accelerometer hardware is unavailable (e.g. on a Mac
    ///    running the Watch simulator without sensor injection).
    /// 3. Load sensitivity thresholds from UserDefaults into the algorithm.
    /// 4. Subscribe to UserDefaults change notifications so future threshold updates
    ///    from the phone propagate to the algorithm without restarting the session.
    /// 5. Start the accelerometer stream at 50 Hz.
    func start() {
        // Guard against calling start() twice — avoids duplicated sensor callbacks.
        guard !motionManager.isAccelerometerActive else { return }

        // Step 1: Open the phone communication channel.
        // We do this before the accelerometer guard so that even in the simulator
        // (where the accelerometer may be unavailable) WCSession is still activated
        // and the watch can receive threshold updates or cancel events from the phone.
        WatchSessionManager.shared.startSession()

        // Step 2: Bail early if no accelerometer hardware is present.
        // On a real Apple Watch this is always available; on a Mac/Xcode preview it is not.
        guard motionManager.isAccelerometerAvailable else { return }

        // Step 3: Apply the latest thresholds stored on this device.
        // The phone may have pushed updated values while this app was not running;
        // reading from UserDefaults ensures we pick them up.
        loadThresholdsFromDefaults()

        // Step 4: Watch for future threshold changes pushed by the phone.
        // When WatchSessionManager.handleMessage() saves new thresholds via
        // UserDefaults.set(...), the OS posts UserDefaults.didChangeNotification.
        // Our observer re-reads all four keys and updates the algorithm live,
        // with no restart of the accelerometer needed.
        // `[weak self]` prevents a retain cycle: the closure holds a reference
        // to `self`, and `self` holds the observer token — without `weak` they
        // would prevent each other from being deallocated.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadThresholdsFromDefaults()
        }

        // Step 5: Configure and start the accelerometer stream.
        // `accelerometerUpdateInterval` is expressed in seconds, so 1/50 = 0.02 s.
        // The trailing closure runs on `.main` (the main UI thread) which is safe
        // because FallAlgorithm does no heavy work — each call takes < 0.1 ms.
        motionManager.accelerometerUpdateInterval = 1.0 / sampleRateHz
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            // Silently skip bad samples — the algorithm is robust to occasional gaps.
            guard let self = self, let data = data, error == nil else { return }
            self.process(data: data)
        }
    }

    /// Stops the accelerometer, removes the UserDefaults observer, and resets the
    /// algorithm so no stale state leaks into the next session.
    func stop() {
        // Unsubscribe from threshold-change notifications first.
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        motionManager.stopAccelerometerUpdates()
        // Clear all phase latches so the next `start()` begins cleanly.
        algorithm.reset()
    }

    // MARK: - Private

    /// Reads the four sensitivity threshold keys from UserDefaults and writes them
    /// to the algorithm's corresponding properties.
    ///
    /// Why check `d.object(forKey:) != nil` before reading?
    /// `UserDefaults.double(forKey:)` returns 0.0 when the key has never been set,
    /// not the algorithm's default value.  The nil-check lets us fall back to the
    /// hard-coded defaults for any key the phone has not yet sent, preventing the
    /// detection thresholds from silently being zeroed out on first launch.
    ///
    /// Key names must stay identical to those used in the Flutter phone app and the
    /// Wear OS app — they are the shared contract defined in CLAUDE.md.
    private func loadThresholdsFromDefaults() {
        let d = UserDefaults.standard
        algorithm.freeFallThresholdG = clampedDouble(d, key: "thresh_freefall", defaultValue: 0.5, range: 0.1...1.0)
        algorithm.impactThresholdG   = clampedDouble(d, key: "thresh_impact", defaultValue: 2.5, range: 1.5...5.0)
        algorithm.tiltThresholdDeg   = clampedDouble(d, key: "thresh_tilt", defaultValue: 45.0, range: 20.0...90.0)
        algorithm.freeFallMinMs      = clampedDouble(d, key: "thresh_freefall_ms", defaultValue: 80.0, range: 40.0...200.0)
    }

    private func clampedDouble(
        _ defaults: UserDefaults,
        key: String,
        defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        let value = defaults.double(forKey: key)
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Called on every accelerometer tick (50 times per second).
    ///
    /// Workflow:
    /// 1. Convert the current wall-clock time to milliseconds for the algorithm.
    /// 2. Extract the three axis values (in g) from the CMAccelerometerData struct.
    /// 3. Hand them to FallAlgorithm.processSample().
    /// 4. If a fall is detected AND the cooldown has elapsed:
    ///    a. Stamp the detection time to start the cooldown.
    ///    b. Reset the algorithm so it is ready to detect the next fall.
    ///    c. Notify the iPhone via WatchSessionManager.
    ///    d. Fire the onFallDetected callback so ContentViewModel shows the alert.
    private func process(data: CMAccelerometerData) {
        // `timeIntervalSince1970` is in seconds (fractional); multiply by 1000 for ms.
        // The algorithm uses ms internally so timestamps match those on the phone.
        let nowMs = Date().timeIntervalSince1970 * 1000

        // CMAccelerometerData.acceleration contains x, y, z all in g-units.
        let ax = data.acceleration.x
        let ay = data.acceleration.y
        let az = data.acceleration.z

        // Run the 3-phase PSP algorithm.  Returns true at most once per fall event.
        let detected = algorithm.processSample(ax: ax, ay: ay, az: az, nowMs: nowMs)

        // Only act on a detection if enough time has passed since the last one.
        // The cooldown prevents the same physical fall from generating multiple alerts
        // (the wearer might bounce or thrash on the ground, causing repeated spikes).
        if detected && (nowMs - lastFallMs > cooldownMs) {
            lastFallMs = nowMs  // Start the cooldown clock.
            algorithm.reset()  // Clear latch state — ready for next fall.

            let timestamp = Int64(nowMs)  // Int64 matches the phone's Long type exactly.

            // Tell the phone.  WatchSessionManager handles the real/simulator split.
            WatchSessionManager.shared.sendFallEvent(timestamp: timestamp)

            // Tell the UI.  The `?` means "only call if someone has registered a closure".
            // ContentViewModel registers its closure in startIfNeeded().
            onFallDetected?(timestamp)
        }
    }
}
