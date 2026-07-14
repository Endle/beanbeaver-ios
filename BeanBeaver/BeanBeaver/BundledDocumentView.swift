import SwiftUI

/// Reads a Markdown document that ships inside the app bundle.
///
/// `PRIVACY.md` and `THIRD_PARTY_NOTICES.md` live at the repo root and are
/// *referenced* by the Xcode target (`path = ../PRIVACY.md`, `sourceTree =
/// SOURCE_ROOT`) rather than copied into it, so the file a reader sees in the
/// repo and the file the app displays are the same file — they can't drift.
/// Bundling them also means both are readable with no network, which matters for
/// an app whose whole pitch is that it works offline: a privacy policy you can
/// only read by leaving the app to visit GitHub is a poor promise.
enum BundledDocument {
    static func text(_ resource: String) -> String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
    }
}

/// The privacy policy. Rendered with light Markdown styling — it's prose, and a
/// wall of monospace would read like a licence file.
struct PrivacyPolicyView: View {
    var body: some View {
        MarkdownProseView(
            resource: "PRIVACY",
            fallback: "The privacy policy is unavailable in this build. It can be read at "
                + "https://github.com/Endle/beanbeaver-ios/blob/main/PRIVACY.md")
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The third-party notices, shown verbatim in monospace. This one is a legal
/// document — every crate in the graph plus the full text of the licences — and
/// the licences that require their text to travel with the binary (Apache-2.0
/// for the PP-OCRv5 models, MIT for ONNX Runtime, MPL-2.0 for UniFFI) are only
/// satisfied if it actually ships. Showing it raw is the point: it should look
/// exactly like the file.
struct AcknowledgementsView: View {
    private var notices: String {
        BundledDocument.text("THIRD_PARTY_NOTICES")
            ?? "Third-party notices are unavailable in this build. "
                + "They can be read at https://github.com/Endle/beanbeaver-ios"
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

/// A deliberately small Markdown renderer: enough for the headings, bullets,
/// bold and links in `PRIVACY.md`, and nothing more. SwiftUI's `Text` already
/// renders inline Markdown (bold, links, code) when handed a `LocalizedStringKey`,
/// so only the block level — headings, bullets, blank lines — is handled here.
private struct MarkdownProseView: View {
    let resource: String
    let fallback: String

    private enum Block: Identifiable {
        case title(String)
        case heading(String)
        /// `marker` is the bullet glyph or the list number ("1."), kept so an
        /// ordered list renders as one.
        case item(marker: String, text: String)
        case paragraph(String)

        var id: String {
            switch self {
            case .title(let s): return "t\(s)"
            case .heading(let s): return "h\(s)"
            case .item(let m, let s): return "i\(m)\(s)"
            case .paragraph(let s): return "p\(s)"
            }
        }
    }

    /// Markdown wraps prose across source lines and only starts a new paragraph
    /// at a blank line, so consecutive prose lines are joined. Rendering one
    /// source line per paragraph (the obvious implementation) shreds a
    /// hard-wrapped file into fragments broken mid-sentence.
    ///
    /// A wrapped line inside a list item continues that item, but only when it
    /// directly follows it — otherwise the first paragraph after a list would be
    /// swallowed into the last bullet.
    private var blocks: [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var afterBlankLine = true

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for line in (BundledDocument.text(resource) ?? fallback).components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { afterBlankLine = trimmed.isEmpty }

            if trimmed.isEmpty {
                flush()
            } else if let heading = trimmed.strippingPrefix("## ") {
                flush()
                blocks.append(.heading(heading))
            } else if let title = trimmed.strippingPrefix("# ") {
                flush()
                blocks.append(.title(title))
            } else if let bullet = trimmed.strippingPrefix("- ") {
                flush()
                blocks.append(.item(marker: "•", text: bullet))
            } else if let (number, rest) = trimmed.splittingOrderedMarker() {
                flush()
                blocks.append(.item(marker: number, text: rest))
            } else if case .item(let marker, let previous) = blocks.last,
                      paragraph.isEmpty, !afterBlankLine {
                blocks[blocks.count - 1] = .item(marker: marker, text: previous + " " + trimmed)
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return blocks
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(blocks) { block in
                    view(for: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .title(let text):
            Text(text).font(.title2.bold())
        case .heading(let text):
            Text(text).font(.headline).padding(.top, 8)
        case .item(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).monospacedDigit()
                Text(.init(text))
            }
            .font(.subheadline)
        case .paragraph(let text):
            Text(.init(text)).font(.subheadline)
        }
    }
}

private extension String {
    /// The remainder after `prefix`, or nil when the string doesn't start with it.
    func strippingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    /// Splits an ordered-list line ("2. Some text") into its marker and text.
    /// Nil for anything else — including prose that merely starts with a number,
    /// since that needs the "N. " shape to match.
    func splittingOrderedMarker() -> (marker: String, text: String)? {
        let digits = prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return (marker: "\(digits).", text: String(rest.dropFirst(2)))
    }
}

#Preview("Privacy") {
    NavigationStack { PrivacyPolicyView() }
}

#Preview("Acknowledgements") {
    NavigationStack { AcknowledgementsView() }
}
