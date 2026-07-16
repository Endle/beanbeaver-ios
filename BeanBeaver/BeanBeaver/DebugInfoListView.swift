import SwiftUI

/// Settings › Debug › "Stored Debug Info" — lists what `DebugInfoStore` has
/// written to disk, which is only ever non-empty while "Store detailed debug
/// info" has been on, so it can be reviewed, shared with support, or wiped.
struct DebugInfoListView: View {
    @State private var entries = DebugInfoStore.allEntries()

    var body: some View {
        List {
            Section {
                if entries.isEmpty {
                    Text("Nothing stored").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    NavigationLink {
                        DebugInfoDetailView(entry: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.modified?.formatted(date: .abbreviated, time: .standard) ?? entry.id)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Only written while \"Store detailed debug info\" is on. Each entry is a full copy of one scan's parsed contents, including receipt items and prices.")
            }
        }
        .navigationTitle("Stored Debug Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        DebugInfoStore.clearAll()
                        entries = DebugInfoStore.allEntries()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }
}

private struct DebugInfoDetailView: View {
    let entry: DebugInfoStore.StoredEntry

    private var text: String {
        (try? String(contentsOf: entry.url, encoding: .utf8)) ?? "Unable to read."
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(entry.modified?.formatted(date: .abbreviated, time: .standard) ?? "Debug Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: text) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }
}

#Preview {
    NavigationStack { DebugInfoListView() }
}
