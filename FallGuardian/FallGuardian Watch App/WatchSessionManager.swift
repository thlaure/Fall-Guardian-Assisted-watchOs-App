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

    // MARK: - Outbound (watch → phone)

    /// Send a cancel alert message to the iPhone.
    func sendCancelAlert() {
        // Simulator IPC: WCSession watch→phone is broken when the watchOS app is
        // deployed via xcrun simctl (isReachable is always false).  Write a flag
        // file that the iOS sim process polls — both are macOS apps sharing /tmp.
        #if targetEnvironment(simulator)
        try? "cancelled".write(
            toFile: "/tmp/com.fallguardian.cancelFromWatch",
            atomically: true, encoding: .utf8
        )
        #endif
        guard WCSession.default.activationState == .activated else {
            NSLog("[WCSession] sendCancelAlert: not activated")
            return
        }
        let message: [String: Any] = ["event": "alert_cancelled"]
        NSLog("[WCSession] sendCancelAlert: isReachable=\(WCSession.default.isReachable)")
        WCSession.default.sendMessage(message, replyHandler: nil) { _ in
            NSLog("[WCSession] sendCancelAlert: sendMessage failed, falling back to transferUserInfo")
            WCSession.default.transferUserInfo(message)
        }
    }

    /// Send a fall event to the iPhone using the provided detection timestamp.
    func sendFallEvent(timestamp: Int64) {
        #if targetEnvironment(simulator)
        // WCSession watch→phone is broken in the simulator when deployed via xcrun simctl.
        // Write a flag file that the iOS simulator process polls — both share /tmp.
        try? "\(timestamp)".write(
            toFile: "/tmp/com.fallguardian.fallEvent",
            atomically: true, encoding: .utf8
        )
        NSLog("[WCSession] sendFallEvent: wrote simulator IPC flag (timestamp=\(timestamp))")
        #endif
        guard WCSession.default.activationState == .activated else {
            NSLog("[WCSession] sendFallEvent: not activated (state=\(WCSession.default.activationState.rawValue))")
            return
        }

        let message: [String: Any] = ["event": "fall_detected", "timestamp": timestamp]

        NSLog("[WCSession] sendFallEvent: isReachable=\(WCSession.default.isReachable)")
        WCSession.default.sendMessage(message, replyHandler: nil) { _ in
            NSLog("[WCSession] sendFallEvent: sendMessage failed, falling back to transferUserInfo")
            WCSession.default.transferUserInfo(message)
        }
    }

    // MARK: - Cancel-status polling
    //
    // Phone→watch sendMessage/replyHandler is broken in the iOS simulator (WCSession
    // reports the watch app as "not installed" when deployed via xcrun simctl).
    // We use two complementary mechanisms that work without an active connection:
    //
    // 1. session(_:didReceiveApplicationContext:) — fires immediately when the phone
    //    calls updateApplicationContext(["alertCancelled": true]).
    // 2. A lightweight poll that reads receivedApplicationContext directly — catches
    //    any context that arrived before the delegate was registered or was missed.

    var onAlertCancelled: (() -> Void)?
    private var pollTask: Task<Void, Never>?

    func startPollingForCancel() {
        stopPolling()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                // In the simulator WCSession is never activated, but checkCancelledOnPhone()
                // uses the /tmp flag file path which doesn't require an active session.
                #if !targetEnvironment(simulator)
                guard WCSession.default.activationState == .activated else { continue }
                #endif
                let cancelled = await checkCancelledOnPhone()
                NSLog("[WCSession] poll: cancelled=\(cancelled)")
                if cancelled {
                    DispatchQueue.main.async { [weak self] in self?.onAlertCancelled?() }
                    return
                }
            }
        }
    }

    /// Returns true if the phone has recorded a cancel.
    ///
    /// In the simulator, all phone→watch WCSession paths are broken and isReachable is
    /// false (phone sees the watch app as "not installed" when deployed via xcrun
    /// simctl). Instead we read a flag file that the phone writes to /tmp — both
    /// simulator processes are macOS apps sharing the same filesystem.
    ///
    /// On real devices we read receivedApplicationContext, which the phone updates via
    /// updateApplicationContext whenever it cancels the alert.
    private func checkCancelledOnPhone() async -> Bool {
        #if targetEnvironment(simulator)
        let path = "/tmp/com.fallguardian.cancelAlert"
        guard FileManager.default.fileExists(atPath: path) else { return false }
        try? FileManager.default.removeItem(atPath: path)
        return true
        #else
        return WCSession.default.receivedApplicationContext["alertCancelled"] as? Bool ?? false
        #endif
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Inbound (phone → watch)

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

    // MARK: - WCSessionDelegate (required)

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    /// Called immediately when the phone calls updateApplicationContext.
    /// This fires even when the phone is not reachable (no active BT connection needed).
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        NSLog("[WCSession] didReceiveApplicationContext: alertCancelled=\(applicationContext["alertCancelled"] as? Bool ?? false)")
        if applicationContext["alertCancelled"] as? Bool == true {
            DispatchQueue.main.async { self.onAlertCancelled?() }
        }
    }

    // MARK: - Private

    private func handleMessage(_ message: [String: Any]) {
        NSLog("[WCSession] handleMessage: event=\(message["event"] as? String ?? "nil")")
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
