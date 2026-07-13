import SwiftUI

/// The third-party notices, shown from Settings. `THIRD_PARTY_NOTICES.md` is
/// bundled verbatim (it's the same file that sits at the repo root, generated
/// from the real dependency graph), so the licenses that require their text to
/// travel with the binary — Apache-2.0 for the PP-OCRv5 models, MIT for ONNX
/// Runtime, and the crates behind them — actually ship inside the app.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private var notices: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Third-party notices are unavailable in this build. "
                + "They can be read at https://github.com/Endle/beanbeaver-ios"
        }
        return text
    }

    var body: some View {
        ScrollView {
            Text(notices)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { AcknowledgementsView() }
}
