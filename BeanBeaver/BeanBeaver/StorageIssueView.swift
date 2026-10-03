import SwiftUI

/// Stays visible until retry succeeds. Dismissing an alert must not make an
/// unsaved receipt look durable. The same notice is shown above scan results.
struct StorageIssueView: View {
    let message: String?
    let retry: () -> Void

    var body: some View {
        if let message {
            VStack(alignment: .leading, spacing: 6) {
                Label("Storage needs attention", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message).font(.caption)
                Button("Retry", action: retry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.regularMaterial)
        }
    }
}
