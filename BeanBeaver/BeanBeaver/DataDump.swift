import Foundation

/// A point-in-time snapshot of everything BeanBeaver has written to disk or the
/// Keychain. Backs the debug "Dump All Data" screen — today a developer tool,
/// eventually a user-facing way to verify the "nothing leaves your device, and
/// here's exactly what we keep" promise. Keychain values and file contents are
/// never included, only their names/sizes, so the dump itself can't leak a
/// token or a receipt photo.
struct DataDump {
    struct Entry: Identifiable {
        let id = UUID()
        let key: String
        let value: String
    }

    struct FileEntry: Identifiable {
        let id = UUID()
        let relativePath: String
        let byteCount: Int
        let modified: Date?
    }

    let userDefaults: [Entry]
    let keychain: [Entry]
    let files: [FileEntry]
    let generatedAt: Date

    static func capture() -> DataDump {
        DataDump(
            userDefaults: captureUserDefaults(),
            keychain: captureKeychain(),
            files: captureFiles(),
            generatedAt: Date())
    }

    // MARK: - UserDefaults

    /// Every key BeanBeaver itself writes to `UserDefaults.standard`, kept as an
    /// explicit list rather than dumping the whole domain — `dictionaryRepresentation()`
    /// also surfaces iOS's own housekeeping keys (`AppleLanguages`, `NSInterfaceStyle`,
    /// …), which would drown out the handful of settings this app actually owns.
    /// Update this list whenever a new `UserDefaults.standard.set(forKey:)` call
    /// is added elsewhere in the app.
    private static let knownDefaultsKeys = [
        "saveScansToPhotos",
        "ledgerInboxBookmark",
        "ledgerInboxName",
        "githubOwner",
        "githubRepo",
        "storeDetailedDebugInfo",
    ]

    private static func captureUserDefaults() -> [Entry] {
        let d = UserDefaults.standard
        return knownDefaultsKeys.compactMap { key in
            guard let value = d.object(forKey: key) else { return nil }
            return Entry(key: key, value: describe(value))
        }
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let data as Data:
            return "<\(data.count) bytes>"
        default:
            return String(describing: value)
        }
    }

    // MARK: - Keychain

    private static func captureKeychain() -> [Entry] {
        Keychain.allItems().map {
            Entry(key: $0.account, value: "<\($0.byteCount) bytes>")
        }
    }

    // MARK: - Files

    /// Walk every directory the app can write to: Documents, Library (incl.
    /// Caches, Application Support), and tmp. This is where a captured receipt
    /// photo would still be sitting if it were ever left uncleaned — the whole
    /// point of this screen is to make that visible rather than assumed.
    private static func captureFiles() -> [FileEntry] {
        let fm = FileManager.default
        let roots: [(String, URL)] = [
            ("Documents", fm.urls(for: .documentDirectory, in: .userDomainMask).first),
            ("Library", fm.urls(for: .libraryDirectory, in: .userDomainMask).first),
            ("tmp", fm.temporaryDirectory),
        ].compactMap { name, url in url.map { (name, $0) } }

        var entries: [FileEntry] = []
        for (label, root) in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
                if values?.isDirectory == true { continue }
                let relative = label + "/" + url.path.replacingOccurrences(of: root.path + "/", with: "")
                entries.append(FileEntry(
                    relativePath: relative,
                    byteCount: values?.fileSize ?? 0,
                    modified: values?.contentModificationDate))
            }
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }
}

extension DataDump {
    /// Flat text export for sharing off-device (AirDrop/Files/Mail) so the dump
    /// can be inspected outside the app too.
    var plainText: String {
        var lines: [String] = []
        lines.append("BeanBeaver data dump — \(ISO8601DateFormatter().string(from: generatedAt))")

        lines.append("\n== UserDefaults (\(userDefaults.count)) ==")
        if userDefaults.isEmpty { lines.append("(empty)") }
        for e in userDefaults { lines.append("\(e.key) = \(e.value)") }

        lines.append("\n== Keychain (\(keychain.count)) ==")
        if keychain.isEmpty { lines.append("(empty)") }
        for e in keychain { lines.append("\(e.key): \(e.value)") }

        lines.append("\n== Files on disk (\(files.count)) ==")
        if files.isEmpty { lines.append("(empty)") }
        for f in files {
            let size = ByteCountFormatter.string(fromByteCount: Int64(f.byteCount), countStyle: .file)
            lines.append("\(f.relativePath) — \(size)")
        }

        lines.append("\n== Photos library ==")
        lines.append("BeanBeaver only writes here if \"Save a copy to Photos\" is on; "
            + "current setting: \(UserDefaults.standard.bool(forKey: "saveScansToPhotos") ? "ON" : "off").")

        return lines.joined(separator: "\n")
    }
}
