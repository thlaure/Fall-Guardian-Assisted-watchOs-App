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
            } else {
                viewModel.toggle()
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
            Image(systemName: "shield.fill")
                .font(.system(size: 36))
                .foregroundColor(.green)

            Text("Fall Guardian")
                .font(.headline)
                .foregroundColor(.white)

            Text(viewModel.isMonitoring ? "Monitoring active" : "Tap to start")
                .font(.caption)
                .foregroundColor(viewModel.isMonitoring ? .green : .gray)
        }
        .containerBackground(.black, for: .navigation)
    }
}

@Observable
class ContentViewModel {
    var isMonitoring: Bool = false
    var isAlertActive: Bool = false
    var remainingSeconds: Int = 30

    private var alertExpireTask: Task<Void, Never>?

    func startIfNeeded() {
        if !FallDetectionManager.shared.isRunning {
            FallDetectionManager.shared.start()
        }
        isMonitoring = FallDetectionManager.shared.isRunning
        FallDetectionManager.shared.onFallDetected = { [weak self] in
            DispatchQueue.main.async { self?.alertDidFire() }
        }
    }

    func toggle() {
        if FallDetectionManager.shared.isRunning {
            FallDetectionManager.shared.stop()
        } else {
            FallDetectionManager.shared.start()
        }
        isMonitoring = FallDetectionManager.shared.isRunning
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
