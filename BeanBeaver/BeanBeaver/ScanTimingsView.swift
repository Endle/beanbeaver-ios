import SwiftUI
import BBReceiptKit

extension Phase {
    /// Short row label for the debug timing readout. Names come from the core's
    /// shared `Phase` taxonomy, so they match Android's breakdown verbatim.
    var label: String {
        switch self {
        case .acquire: return "acquire"
        case .encode: return "encode"
        case .decode: return "decode"
        case .prep: return "prep"
        case .detect: return "detect"
        case .classify: return "classify"
        case .recognize: return "recognize"
        case .parse: return "parse"
        case .render: return "render"
        @unknown default: return "?"
        }
    }
}

/// Compact per-stage latency readout under a result, for the real-device test.
/// `wallMs` is the Swift-observed total (incl. decode + FFI); the stage rows are
/// the Rust `ScanTimings` phase spans (decode → prep → detect → … → parse).
/// DEBUG-only diagnostic — never shown in a release build.
struct ScanTimingsView: View {
    let timings: ScanTimings
    var wallMs: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Debug: scan time").font(.caption).foregroundStyle(.secondary)
            if let wallMs { row("total (wall)", wallMs, emphasized: true) }
            // Ordered phase spans straight from the core's shared taxonomy — new
            // phases (e.g. app-side spans) appear here with no change to this view.
            ForEach(Array(timings.spans.enumerated()), id: \.offset) { _, span in
                row(span.phase.label, span.ms)
            }
            row("rust total", timings.totalMs)
            if let wallMs { row("other (wall−Σ)", wallMs - timings.totalMs) }
        }
        .font(.system(.caption2, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ ms: Double, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(Int(ms.rounded())) ms").fontWeight(emphasized ? .bold : .regular)
        }
    }
}

// MARK: - Previews
