import SwiftUI

/// Renders `DataDump.capture()` — every UserDefaults key, Keychain account, and
/// file BeanBeaver has on disk. Reached from Settings › Debug for now; the
/// intent is to eventually surface this (or a simplified version of it) as a
/// regular, non-debug screen so a user can verify nothing beyond what's listed
/// here is being kept.
struct DataDumpView: View {
    @State private var dump = DataDump.capture()

    var body: some View {
        List {
            Section {
                if dump.userDefaults.isEmpty {
                    Text("Nothing stored").foregroundStyle(.secondary)
                }
                ForEach(dump.userDefaults) { entry in
                    LabeledContent(entry.key, value: entry.value)
                }
            } header: {
                Text("UserDefaults (\(dump.userDefaults.count))")
            } footer: {
                Text("App settings: export toggles, GitHub repo config. No receipt data.")
            }

            Section {
                if dump.keychain.isEmpty {
                    Text("Nothing stored").foregroundStyle(.secondary)
                }
                ForEach(dump.keychain) { entry in
                    LabeledContent(entry.key, value: entry.value)
                }
            } header: {
                Text("Keychain (\(dump.keychain.count))")
            } footer: {
                Text("Secret values are never shown here — only which accounts exist and their size.")
            }

            Section {
                if dump.files.isEmpty {
                    Text("Nothing stored").foregroundStyle(.secondary)
                }
                ForEach(dump.files) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.relativePath)
                            .font(.system(.footnote, design: .monospaced))
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Files on disk (\(dump.files.count))")
            } footer: {
                Text("Documents, Library, and tmp. A captured receipt photo shows up here as receipt_capture_*.jpg until the OS clears tmp.")
            }
        }
        .navigationTitle("Data Dump")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: dump.plainText) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dump = DataDump.capture()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
}

#Preview {
    NavigationStack { DataDumpView() }
}
