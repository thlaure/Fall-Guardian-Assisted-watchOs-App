import SwiftUI
import Observation
import WatchKit

struct ContentView: View {

    @State private var viewModel = ContentViewModel()

    var body: some View {
        Group {
            if viewModel.isAlertActive {
                alertView
            } else {
                idleView
            }
        }
        .onTapGesture {
            if viewModel.isAlertActive {
                viewModel.cancelAlert()
            }
        }
        .onAppear {
            viewModel.startIfNeeded()
        }
        .onChange(of: viewModel.remainingSeconds) { _, newValue in
            guard viewModel.isAlertActive, newValue > 0 else { return }
            WKInterfaceDevice.current().play(newValue <= 10 ? .notification : .click)
        }
    }

    // MARK: - Alert: full screen, big number, flash under 10 s

    private var alertView: some View {
        ZStack {
            Color(red: 0.1, green: 0, blue: 0).ignoresSafeArea()

            if viewModel.remainingSeconds <= 10 {
                Color.red.opacity(0.3).ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true),
                               value: viewModel.remainingSeconds)
            }

            VStack(spacing: 6) {
                Text("\(viewModel.remainingSeconds)")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundColor(.white)
                Text("Tap anywhere to cancel")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .containerBackground(.red.opacity(0.1), for: .navigation)
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.0, green: 0.247, blue: 0.235))
                    .frame(width: 52, height: 52)
                Image(systemName: "shield.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Color(red: 0.898, green: 0.412, blue: 0.290))
            }

            Text("Fall Guardian")
                .font(.headline)
                .foregroundColor(.white)

            Text("Monitoring active")
                .font(.caption)
                .foregroundColor(Color(red: 0.820, green: 0.878, blue: 0.843))

            #if DEBUG
            Button("Simulate Fall (debug)") {
                viewModel.simulateFall()
            }
            .font(.system(size: 11))
            .foregroundColor(Color(red: 0.898, green: 0.412, blue: 0.290))
            #endif
        }
        .containerBackground(.black, for: .navigation)
    }
}

@Observable
class ContentViewModel {
    var isAlertActive: Bool = false
    var remainingSeconds: Int = 30

    private var alertExpireTask: Task<Void, Never>?
    private var fallTimestamp: Int64 = 0   // ms since epoch when fall was detected

    deinit {
        alertExpireTask?.cancel()
    }

    func startIfNeeded() {
        if !FallDetectionManager.shared.isRunning {
            FallDetectionManager.shared.start()
        }
        FallDetectionManager.shared.onFallDetected = { [weak self] timestamp in
            DispatchQueue.main.async { self?.alertDidFire(timestamp: timestamp) }
        }
        WatchSessionManager.shared.onAlertCancelled = { [weak self] in
            self?.cancelAlert(notifyPhone: false)
        }
        #if DEBUG && targetEnvironment(simulator)
        startDebugTriggerPolling()
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Polls flag files written by the E2E test script so tests don't need UI taps.
    ///   /tmp/com.fallguardian.debugSimulateFall  → simulateFall()
    ///   /tmp/com.fallguardian.debugCancelWatch   → cancelAlert()
    private func startDebugTriggerPolling() {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let fm = FileManager.default
                let fallPath   = "/tmp/com.fallguardian.debugSimulateFall"
                let cancelPath = "/tmp/com.fallguardian.debugCancelWatch"
                if fm.fileExists(atPath: fallPath) {
                    try? fm.removeItem(atPath: fallPath)
                    NSLog("[Debug] debugSimulateFall trigger received")
                    await MainActor.run { self.simulateFall() }
                } else if fm.fileExists(atPath: cancelPath) {
                    try? fm.removeItem(atPath: cancelPath)
                    NSLog("[Debug] debugCancelWatch trigger received")
                    await MainActor.run { self.cancelAlert() }
                }
            }
        }
    }
    #endif

    func simulateFall() {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        alertDidFire(timestamp: timestamp)
        WatchSessionManager.shared.sendFallEvent(timestamp: timestamp)
    }

    /// Cancel the alert. Pass `notifyPhone: false` when the cancel originated from the phone.
    func cancelAlert(notifyPhone: Bool = true) {
        alertExpireTask?.cancel()
        WatchSessionManager.shared.stopPolling()
        isAlertActive = false
        remainingSeconds = 30
        if notifyPhone {
            WatchSessionManager.shared.sendCancelAlert()
        }
    }

    private func alertDidFire(timestamp: Int64) {
        fallTimestamp = timestamp
        isAlertActive = true
        remainingSeconds = max(0, 30 - Int((Int64(Date().timeIntervalSince1970 * 1000) - timestamp) / 1000))
        alertExpireTask?.cancel()
        WatchSessionManager.shared.startPollingForCancel()
        // Poll at 0.5 s so display stays in sync with the phone countdown
        alertExpireTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                let remaining = max(0, 30 - Int((now - fallTimestamp) / 1000))
                await MainActor.run { remainingSeconds = remaining }
                if remaining <= 0 {
                    await MainActor.run {
                        WatchSessionManager.shared.stopPolling()
                        isAlertActive = false
                    }
                    return
                }
            }
        }
    }
}
