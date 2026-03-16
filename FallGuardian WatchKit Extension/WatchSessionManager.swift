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

    /// Send a fall event to the iPhone.
    func sendFallEvent() {
        guard WCSession.default.activationState == .activated else { return }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let message: [String: Any] = [
            "event": "fall_detected",
            "timestamp": timestamp
        ]

        if WCSession.default.isReachable {
            // Phone is reachable — send immediately with reply handler
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
        } else {
            // Phone not reachable — use transferUserInfo for guaranteed delivery
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
