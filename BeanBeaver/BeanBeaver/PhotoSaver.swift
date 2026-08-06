import Photos

/// Saves a receipt photo to the user's photo library (camera roll).
///
/// Every save is something the user asked for by name (Receipts → a receipt →
/// "Save to Camera Roll"), so this reports back rather than failing silently:
/// the two ways it goes wrong — permission refused, and the write itself
/// failing — look identical from the outside otherwise, and the first is
/// something only the user can fix.
enum PhotoSaver {
    enum Failure: LocalizedError {
        /// Add-only access wasn't granted. Not recoverable in-app: once iOS has
        /// a decision on file it stops re-prompting, so the fix is in Settings.
        case notAuthorized
        case readFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "BeanBeaver can't add to your photo library. Allow \"Add Photos Only\" (or full access) for BeanBeaver in Settings → Privacy & Security → Photos."
            case .readFailed:
                return "This receipt's photo is no longer on this device."
            case .writeFailed(let message):
                return message
            }
        }
    }

    /// Copy the photo at `url` into Photos. Throws `Failure` on every path that
    /// doesn't end with the image in the library.
    static func save(imageAt url: URL) async throws {
        guard let data = try? Data(contentsOf: url) else { throw Failure.readFailed }
        try await save(imageData: data)
    }

    /// Save encoded image bytes (JPEG/PNG) to Photos using add-only access —
    /// the narrowest permission that can do this, and one that never gives the
    /// app sight of anything already in the library.
    static func save(imageData: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAuthorized }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: imageData, options: nil)
            }
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }
}
