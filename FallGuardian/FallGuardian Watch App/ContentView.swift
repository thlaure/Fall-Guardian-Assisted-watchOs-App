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
                    .fill(Color(red: 0.137, green: 0.145, blue: 0.290))
                    .frame(width: 52, height: 52)
                Image(systemName: "shield.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Color(red: 0.365, green: 0.922, blue: 0.722))
            }

            Text("Fall Guardian")
                .font(.headline)
                .foregroundColor(.white)

            Text("Monitoring active")
                .font(.caption)
                .foregroundColor(Color(red: 0.365, green: 0.922, blue: 0.722))

            #if DEBUG
            Button("Simulate Fall (debug)") {
                viewModel.simulateFall()
            }
            .font(.system(size: 11))
            .foregroundColor(Color(red: 1.0, green: 0.67, blue: 0.25))
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

    deinit {
        alertExpireTask?.cancel()
    }

    func startIfNeeded() {
        if !FallDetectionManager.shared.isRunning {
            FallDetectionManager.shared.start()
        }
        FallDetectionManager.shared.onFallDetected = { [weak self] in
            DispatchQueue.main.async { self?.alertDidFire() }
        }
        WatchSessionManager.shared.onAlertCancelled = { [weak self] in
            self?.cancelAlert()
        }
    }

    func simulateFall() {
        alertDidFire()
        WatchSessionManager.shared.sendFallEvent()
    }

    func cancelAlert() {
        alertExpireTask?.cancel()
        isAlertActive = false
        remainingSeconds = 30
        WatchSessionManager.shared.sendCancelAlert()
    }

    private func alertDidFire() {
        isAlertActive = true
        remainingSeconds = 30
        alertExpireTask?.cancel()
        alertExpireTask = Task {
            for i in stride(from: 29, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                await MainActor.run { remainingSeconds = i }
            }
            await MainActor.run { isAlertActive = false }
        }
    }
}
