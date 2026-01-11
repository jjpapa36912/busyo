import SwiftUI

final class DebugCounter: ObservableObject {
    static let shared = DebugCounter()
    @Published var requests = 0
    @Published var errors = 0
    @Published var lastReloadMs: Int = 0
}

struct DebugHUD: View {
    @ObservedObject var d = DebugCounter.shared
    var body: some View {
        VStack(alignment:.leading, spacing: 4) {
            Text("🔧 DEBUG").font(.caption2).bold()
            Text("req: \(d.requests)  err: \(d.errors)  reload: \(d.lastReloadMs)ms")
                .font(.caption2).monospacedDigit()
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 2)
    }
}
