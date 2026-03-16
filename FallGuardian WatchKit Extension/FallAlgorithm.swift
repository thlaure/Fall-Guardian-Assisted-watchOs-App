import Foundation
import CoreMotion

/// PSP-optimized fall detection algorithm — Swift port of the Kotlin version.
///
/// Trigger: (FreeFall AND Impact) OR (Impact AND Tilt)
class FallAlgorithm {

    // MARK: - Configurable thresholds

    var freeFallThresholdG: Double = 0.5   // ||accel|| must drop below this (g)
    var impactThresholdG: Double = 2.5     // ||accel|| spike must exceed this (g)
    var tiltThresholdDeg: Double = 45.0    // angle from upright
    var freeFallMinMs: Double = 80.0       // minimum free-fall duration (ms)

    // MARK: - State

    private var freeFallStartMs: Double = 0
    private var freeFallActive = false
    private var impactDetected = false
    private var impactTimeMs: Double = 0

    // Low-pass filtered gravity vector
    private var gravityX: Double = 0
    private var gravityY: Double = 0
    private var gravityZ: Double = 0
    private let alpha: Double = 0.8

    // MARK: - API

    func reset() {
        freeFallActive = false
        freeFallStartMs = 0
        impactDetected = false
        impactTimeMs = 0
        gravityX = 0; gravityY = 0; gravityZ = 0
    }

    /// Process one accelerometer sample.
    /// - Parameters:
    ///   - data: CMAccelerometerData (values in g-units for CMMotionManager)
    ///   - nowMs: current time in milliseconds
    /// - Returns: true if a fall was just detected
    func processSample(ax: Double, ay: Double, az: Double, nowMs: Double) -> Bool {
        // Low-pass filter for gravity isolation
        gravityX = alpha * gravityX + (1 - alpha) * ax
        gravityY = alpha * gravityY + (1 - alpha) * ay
        gravityZ = alpha * gravityZ + (1 - alpha) * az

        // CMMotionManager returns values in g — no division by 9.81 needed
        let normG = norm(ax, ay, az)

        // Phase 1: Free-fall
        if normG < freeFallThresholdG {
            if !freeFallActive {
                freeFallActive = true
                freeFallStartMs = nowMs
            }
        } else {
            freeFallActive = false
        }
        let freeFallQualified = freeFallActive && (nowMs - freeFallStartMs >= freeFallMinMs)

        // Phase 2: Impact
        if normG > impactThresholdG {
            impactDetected = true
            impactTimeMs = nowMs
        }
        let impactActive = impactDetected && (nowMs - impactTimeMs < 2000)

        // Phase 3: Tilt
        let tilt = tiltAngleDeg()
        let tiltActive = tilt > tiltThresholdDeg

        // Trigger
        return (freeFallQualified && impactActive) || (impactActive && tiltActive)
    }

    // MARK: - Helpers

    private func tiltAngleDeg() -> Double {
        let gNorm = norm(gravityX, gravityY, gravityZ)
        guard gNorm > 0.01 else { return 0 }
        let cosAngle = max(-1, min(1, gravityZ / gNorm))
        return (acos(cosAngle) * 180) / .pi
    }

    private func norm(_ x: Double, _ y: Double, _ z: Double) -> Double {
        (x * x + y * y + z * z).squareRoot()
    }
}
