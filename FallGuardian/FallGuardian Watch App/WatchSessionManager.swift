import Foundation
import WatchConnectivity

/// Sends fall event messages to the paired iPhone via WCSession.
class WatchSessionManager: NSObject, WCSessionDelegate {

    static let shared = WatchSessionManager()

    private override init() {
        super.init()
    }

    func startSession() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Send a cancel alert message to the iPhone.
    func sendCancelAlert() {
        guard WCSession.default.activationState == .activated else { return }
        let message: [String: Any] = ["event": "alert_cancelled"]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { _ in
                // Phone became unreachable mid-send — fall back to guaranteed delivery
                WCSession.default.transferUserInfo(message)
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    /// Send a fall event to the iPhone.
    func sendFallEvent() {
        guard WCSession.default.activationState == .activated else { return }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let message: [String: Any] = [
            "event": "fall_detected",
            "timestamp": timestamp
        ]

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { _ in
                WCSession.default.transferUserInfo(message)
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    // MARK: - WCSessionDelegate

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    /// Called when the phone sends a real-time message.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleMessage(message)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        handleMessage(message)
        replyHandler(["status": "received"])
    }

    /// Called when the phone sends via transferUserInfo() (watch was not reachable).
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleMessage(userInfo)
    }

    // MARK: - Private

    var onAlertCancelled: (() -> Void)?

    private func handleMessage(_ message: [String: Any]) {
        switch message["event"] as? String {
        case "set_thresholds":
            guard let thresholds = message["thresholds"] as? [String: Any] else { return }
            let d = UserDefaults.standard
            if let v = thresholds["thresh_freefall"] as? Double { d.set(v, forKey: "thresh_freefall") }
            if let v = thresholds["thresh_impact"]   as? Double { d.set(v, forKey: "thresh_impact") }
            if let v = thresholds["thresh_tilt"]     as? Double { d.set(v, forKey: "thresh_tilt") }
            if let v = thresholds["thresh_freefall_ms"] as? Int { d.set(Double(v), forKey: "thresh_freefall_ms") }
            // FallDetectionManager observes UserDefaults.didChangeNotification and reloads automatically
            d.synchronize()
        case "alert_cancelled":
            DispatchQueue.main.async { self.onAlertCancelled?() }
        default:
            break
        }
    }
}
