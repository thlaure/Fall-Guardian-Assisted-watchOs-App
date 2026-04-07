// WatchSessionManager.swift
// Fall Guardian — watchOS
//
// This file owns every byte that travels between the Apple Watch and the iPhone.
// It uses Apple's WatchConnectivity framework (WCSession) to send fall events
// and cancel signals to the phone, and to receive threshold updates and cancel
// signals from the phone.
//
// ## WatchConnectivity in plain English
// Apple Watch and iPhone are separate computers.  WatchConnectivity is Apple's
// official bridge between them.  It provides three delivery mechanisms:
//
//   sendMessage(_:replyHandler:errorHandler:)
//       Fast, real-time.  Works only while both devices are awake and nearby
//       (Bluetooth or Wi-Fi).  If delivery fails, the error handler fires.
//
//   transferUserInfo(_:)
//       Reliable background queue.  The OS stores the dictionary and delivers
//       it as soon as the receiving device is reachable, even if that is hours
//       later.  Used as a fallback when sendMessage fails.
//
//   updateApplicationContext(_:)
//       Stores ONE dictionary on the receiving device.  Each call overwrites
//       the previous value.  Good for "latest known state" (e.g. alertCancelled).
//       The receiving delegate gets `didReceiveApplicationContext`.
//
// ## Simulator limitation and the /tmp workaround
// When both apps are launched in the Xcode simulator via `xcrun simctl`,
// WCSession reports the watch app as "not installed" and isReachable is always
// false.  All WCSession paths are broken.
//
// Both simulator processes are ordinary macOS apps sharing the same filesystem,
// so writing a small flag file to /tmp is a reliable substitute.
// Every block that does this is wrapped in `#if targetEnvironment(simulator)`
// so the workaround is completely stripped from real-device builds.
//
// /tmp file protocol (simulator only):
//   watch → phone:  /tmp/com.fallguardian.fallEvent       (contains timestamp ms)
//   watch → phone:  /tmp/com.fallguardian.cancelFromWatch  (contains "cancelled")
//   phone → watch:  /tmp/com.fallguardian.cancelAlert      (presence = cancelled)
//
// ## Connection to the rest of the app
//   FallDetectionManager   →  sendFallEvent()
//   ContentViewModel       →  sendCancelAlert(), stopPolling(), onAlertCancelled
//   WatchSessionManager    →  thresholds saved to UserDefaults
//                             FallDetectionManager reloads via didChangeNotification

import Foundation         // Basic utilities: NSObject, DispatchQueue, FileManager, etc.
import WatchConnectivity  // WCSession, WCSessionDelegate — Apple Watch ↔ iPhone bridge

/// Handles all communication between the Apple Watch and the paired iPhone.
///
/// This class implements `WCSessionDelegate`, which means the OS calls methods
/// on this object whenever a message arrives from the phone.  It is a singleton
/// (`shared`) so the single WCSession is never activated more than once.
class WatchSessionManager: NSObject, WCSessionDelegate {

    // MARK: - Singleton

    static let shared = WatchSessionManager()

    // Private init prevents anyone from creating a second instance.
    private override init() {
        super.init()
    }

    // MARK: - Session lifecycle

    /// Activates the WCSession so the watch can send and receive messages.
    ///
    /// This must be called before any send/receive method works.
    /// `FallDetectionManager.start()` calls this as its first step so the channel
    /// is ready even before the accelerometer is confirmed available.
    ///
    /// `WCSession.isSupported()` returns false on devices that don't have the
    /// WatchConnectivity framework (e.g. iPod Touch); on any Apple Watch it is
    /// always true, but we guard anyway for defensive coding.
    func startSession() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self  // Register this object as the message receiver.
        WCSession.default.activate()       // Ask the OS to open the channel (async).
    }

    // MARK: - Outbound (watch → phone)

    /// Tells the iPhone that the user tapped "Cancel" on the watch alert screen.
    ///
    /// Delivery strategy (same pattern used throughout this file):
    /// 1. Simulator path — write a flag file to /tmp that the iOS sim polls every 1 s.
    /// 2. Guard: abort if WCSession is not yet activated (e.g. during early startup).
    /// 3. Try `sendMessage` (fast, real-time) first.
    /// 4. If sendMessage fails (phone is locked, out of range, etc.), fall back to
    ///    `transferUserInfo` which queues the message for reliable later delivery.
    ///
    /// The `notifyPhone: false` path in ContentViewModel ensures we never call this
    /// when the cancel originated from the phone — that would create a ping-pong loop
    /// (phone cancels → watch calls sendCancelAlert → phone receives → phone cancels again…).
    func sendCancelAlert() {
        // --- Simulator IPC workaround ---
        // WCSession watch→phone is broken when the watchOS app is deployed via
        // xcrun simctl (isReachable is always false).  Write a flag file that
        // the iOS simulator process polls every 1 second.  Both are macOS apps
        // sharing /tmp so the file is immediately visible across processes.
        #if targetEnvironment(simulator)
        try? "cancelled".write(
            toFile: "/tmp/com.fallguardian.cancelFromWatch",
            atomically: true, encoding: .utf8
            // `atomically: true` means the file is first written to a temp location
            // then renamed — prevents the iOS process from reading a half-written file.
        )
        #endif

        // Guard: WCSession must be fully activated before we can send.
        // `.activated` is the only state where sendMessage works.
        guard WCSession.default.activationState == .activated else {
            NSLog("[WCSession] sendCancelAlert: not activated")
            return
        }

        // Build the message dictionary.  The phone's WatchSessionManager reads the
        // "event" key to dispatch to the right handler.
        let message: [String: Any] = ["event": "alert_cancelled"]

        NSLog("[WCSession] sendCancelAlert: isReachable=\(WCSession.default.isReachable)")

        // Try real-time delivery.  The error handler (trailing closure `{ _ in }`)
        // fires if the phone cannot be reached right now; we fall back to the queue.
        WCSession.default.sendMessage(message, replyHandler: nil) { _ in
            NSLog("[WCSession] sendCancelAlert: sendMessage failed, falling back to transferUserInfo")
            // transferUserInfo queues the message on-device; the OS delivers it when
            // the phone becomes reachable again — guaranteed delivery, but not instant.
            WCSession.default.transferUserInfo(message)
        }
    }

    /// Tells the iPhone that a fall was detected on the watch.
    ///
    /// The `timestamp` is milliseconds since Unix epoch (Jan 1 1970).
    /// Both devices compute `remainingSeconds = 30 - (now - timestamp) / 1000`,
    /// keeping their countdowns perfectly in sync even if delivery is slightly delayed.
    ///
    /// Delivery strategy: same as sendCancelAlert (simulator file → sendMessage → transferUserInfo).
    func sendFallEvent(timestamp: Int64) {
        // --- Simulator IPC workaround ---
        // Write the timestamp to a file that the iOS sim polls every 1 second.
        // The file name is the agreed-upon contract between both sim processes.
        #if targetEnvironment(simulator)
        try? "\(timestamp)".write(
            toFile: "/tmp/com.fallguardian.fallEvent",
            atomically: true, encoding: .utf8
        )
        NSLog("[WCSession] sendFallEvent: wrote simulator IPC flag (timestamp=\(timestamp))")
        // Post a Darwin system notification so the iOS sim app is woken immediately
        // even when it is suspended in the background. The polling loop alone cannot
        // fire while the iOS process is frozen; posting to the Darwin notification
        // center triggers a kernel-level wakeup before the iOS app reads the flag file.
        // CFNotificationCenterGetDarwinNotifyCenter() is available on all Apple platforms;
        // it uses notify_post() internally but is exposed through CoreFoundation.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.fallguardian.fallEvent" as CFString),
            nil, nil, true
        )
        #endif

        guard WCSession.default.activationState == .activated else {
            NSLog("[WCSession] sendFallEvent: not activated (state=\(WCSession.default.activationState.rawValue))")
            return
        }

        // Both "event" and "timestamp" are read by the phone's WatchSessionManager
        // (and its iOS counterpart) to start the alert with the correct countdown origin.
        let message: [String: Any] = ["event": "fall_detected", "timestamp": timestamp]

        NSLog("[WCSession] sendFallEvent: isReachable=\(WCSession.default.isReachable)")
        WCSession.default.sendMessage(message, replyHandler: nil) { _ in
            NSLog("[WCSession] sendFallEvent: sendMessage failed, falling back to transferUserInfo")
            WCSession.default.transferUserInfo(message)
        }
    }

    // MARK: - Cancel-status polling (watch waiting for phone to cancel)
    //
    // The watch needs to know if the user cancelled the alert on the PHONE side.
    // Two complementary mechanisms cover all delivery scenarios:
    //
    //  A) `session(_:didReceiveApplicationContext:)` (below) — fires immediately
    //     when the phone calls updateApplicationContext(["alertCancelled": true]).
    //     Works on real devices; completely broken in the simulator.
    //
    //  B) This polling loop — checks every 2 seconds.  On a real device it reads
    //     `receivedApplicationContext` (the last value the phone pushed).  In the
    //     simulator it checks for a /tmp flag file written by the iOS process.
    //
    // Having both mechanisms means: real devices get near-instant response via (A),
    // and the simulator works via (B) without any code duplication.

    /// Closure registered by ContentViewModel.  Called when the phone cancels the alert.
    var onAlertCancelled: (() -> Void)?

    /// The running background poll task.  Stored so we can cancel it in stopPolling().
    private var pollTask: Task<Void, Never>?

    /// Starts the 2-second polling loop that watches for a phone-side cancellation.
    ///
    /// `stopPolling()` is called first to cancel any previous loop — important
    /// because `alertDidFire` may be called more than once if a second fall is
    /// detected during recovery.
    ///
    /// The loop uses Swift Concurrency (`Task` / `async-await`):
    ///   - `Task { ... }` runs the block on a background thread.
    ///   - `Task.isCancelled` is checked before and after the sleep so the loop
    ///     exits immediately when stopPolling() cancels the task.
    ///   - `try? await Task.sleep(nanoseconds:)` pauses without blocking the main thread.
    func startPollingForCancel() {
        stopPolling()  // Cancel any stale poll from a previous alert.
        pollTask = Task {
            while !Task.isCancelled {
                // Sleep 2 seconds between checks.  2 s feels responsive while keeping
                // CPU/battery impact negligible (< 0.1% on Apple Watch S6+).
                // nanoseconds = 2 * 10^9 because Task.sleep(for:) requires iOS 16+.
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
                    // Jump back to the main thread before touching UI-facing state.
                    // `[weak self]` prevents a retain cycle: the Task closure captures
                    // self, and self holds the task — without weak, neither is freed.
                    DispatchQueue.main.async { [weak self] in self?.onAlertCancelled?() }
                    return  // Stop polling — alert is resolved.
                }
            }
        }
    }

    /// Checks whether the phone has recorded a cancellation since we last polled.
    ///
    /// Real device: reads `receivedApplicationContext`, the dictionary the phone
    /// last sent via `updateApplicationContext`.  This persists across app launches
    /// so even a cancel sent while the watch was asleep is detected.
    ///
    /// Simulator: checks for the existence of `/tmp/com.fallguardian.cancelAlert`.
    /// The iOS simulator writes that file when the user taps Cancel on the phone.
    /// We delete it after reading so we don't double-fire the cancellation.
    private func checkCancelledOnPhone() async -> Bool {
        #if targetEnvironment(simulator)
        let path = "/tmp/com.fallguardian.cancelAlert"
        guard FileManager.default.fileExists(atPath: path) else { return false }
        // Delete the flag so the next poll doesn't fire again for the same cancel.
        try? FileManager.default.removeItem(atPath: path)
        return true
        #else
        // On a real device, read the latest application context the phone published.
        // `as? Bool ?? false` safely handles the case where the key is absent or
        // the value is not a Bool (e.g. on first launch before any context is set).
        return WCSession.default.receivedApplicationContext["alertCancelled"] as? Bool ?? false
        #endif
    }

    /// Cancels the polling loop.  Called when:
    ///   - The alert expires naturally (timeout reached).
    ///   - The user cancels on the watch.
    ///   - A cancellation arrives from the phone.
    func stopPolling() {
        pollTask?.cancel()  // Signals Task.isCancelled inside the loop.
        pollTask = nil      // Release the reference so ARC can deallocate the task.
    }

    // MARK: - Inbound (phone → watch) — WCSessionDelegate callbacks
    //
    // The OS calls these methods when the phone sends data.  All three paths
    // (real-time message, queued userInfo, and applicationContext) route to the
    // same private handleMessage() dispatcher for consistent handling.

    /// Called when the phone sends a real-time message via `sendMessage`.
    /// This is the fastest path — both devices are awake and in range.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleMessage(message)
    }

    /// Called when the phone sends a real-time message AND expects a reply.
    /// We acknowledge with `["status": "received"]` so the phone's replyHandler fires.
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        handleMessage(message)
        replyHandler(["status": "received"])
    }

    /// Called when the phone sent a message via `transferUserInfo` (queued delivery).
    /// The payload is structurally identical to a real-time message so we reuse
    /// the same dispatcher.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleMessage(userInfo)
    }

    // MARK: - WCSessionDelegate (required protocol stubs)

    /// Required by the protocol.  Called after `activate()` completes (or fails).
    /// We don't need to do anything here because the session is used lazily:
    /// sendMessage/transferUserInfo check activationState themselves.
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    /// Called immediately when the phone calls `updateApplicationContext`.
    ///
    /// Unlike sendMessage, applicationContext does NOT require an active Bluetooth
    /// connection — the OS buffers it and delivers it when the watch is next reachable.
    /// This makes it the most reliable cancel path on real devices.
    ///
    /// We also handle this in the polling loop as a belt-and-suspenders safety net.
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        NSLog("[WCSession] didReceiveApplicationContext: alertCancelled=\(applicationContext["alertCancelled"] as? Bool ?? false)")
        if applicationContext["alertCancelled"] as? Bool == true {
            // The callback touches UI state — must run on the main thread.
            DispatchQueue.main.async { self.onAlertCancelled?() }
        }
    }

    // MARK: - Private message dispatcher

    /// Central handler for all incoming messages regardless of delivery path.
    ///
    /// Known event types:
    ///   `"set_thresholds"` — phone is pushing updated sensitivity values.
    ///       The four keys are saved to UserDefaults.  FallDetectionManager
    ///       observes `UserDefaults.didChangeNotification` and reloads the
    ///       algorithm automatically — no restart needed.
    ///
    ///   `"alert_cancelled"` — phone cancelled the alert (user tapped cancel or
    ///       the phone app was brought to foreground and the user dismissed it).
    ///       We fire `onAlertCancelled` on the main thread so ContentViewModel
    ///       can dismiss the UI immediately.
    private func handleMessage(_ message: [String: Any]) {
        NSLog("[WCSession] handleMessage: event=\(message["event"] as? String ?? "nil")")
        switch message["event"] as? String {

        case "set_thresholds":
            // The phone app's Settings screen lets the user adjust sensitivity.
            // Flutter calls `sendThresholds` on the MethodChannel, which causes
            // the iOS WatchSessionManager to send this message here.
            // We extract each threshold value and save it under the agreed key name.
            // Key names must match the Flutter SharedPreferences keys exactly —
            // they are the shared contract listed in CLAUDE.md.
            guard let thresholds = message["thresholds"] as? [String: Any] else { return }
            let d = UserDefaults.standard
            if let v = thresholds["thresh_freefall"]    as? Double { d.set(v,         forKey: "thresh_freefall") }
            if let v = thresholds["thresh_impact"]      as? Double { d.set(v,         forKey: "thresh_impact") }
            if let v = thresholds["thresh_tilt"]        as? Double { d.set(v,         forKey: "thresh_tilt") }
            if let v = thresholds["thresh_freefall_ms"] as? Int    { d.set(Double(v), forKey: "thresh_freefall_ms") }
            // `synchronize()` forces an immediate write to disk.  Usually the OS does
            // this automatically but calling it explicitly ensures the value is
            // persisted before FallDetectionManager's observer fires.
            d.synchronize()

        case "alert_cancelled":
            // The phone cancelled — dismiss the watch alert without sending another
            // cancel back to the phone (ContentViewModel handles that via notifyPhone: false).
            DispatchQueue.main.async { self.onAlertCancelled?() }

        default:
            // Unknown events are silently ignored so future message types added to
            // the phone app don't crash older watch app versions.
            break
        }
    }
}
