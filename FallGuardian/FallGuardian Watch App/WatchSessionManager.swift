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

    // UserInfo delivery (when phone was not reachable)
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {}
}
