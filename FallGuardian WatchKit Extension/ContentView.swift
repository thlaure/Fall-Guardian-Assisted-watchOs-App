import SwiftUI

struct ContentView: View {

    @StateObject private var viewModel = ContentViewModel()

    var body: some View {
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
        .containerBackground(.black, for: .watch)
        .onTapGesture {
            viewModel.toggle()
        }
        .onAppear {
            viewModel.startIfNeeded()
        }
    }
}

class ContentViewModel: ObservableObject {
    @Published var isMonitoring: Bool = false

    func startIfNeeded() {
        if !FallDetectionManager.shared.isRunning {
            FallDetectionManager.shared.start()
        }
        isMonitoring = FallDetectionManager.shared.isRunning
    }

    func toggle() {
        if FallDetectionManager.shared.isRunning {
            FallDetectionManager.shared.stop()
        } else {
            FallDetectionManager.shared.start()
        }
        isMonitoring = FallDetectionManager.shared.isRunning
    }
}
