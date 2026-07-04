import Foundation

// Thin, hand-written conveniences over the generated UniFFI glue (OcrSession,
// ReceiptResult, DateYmd, ScanError — all `public` from Generated/).

public extension OcrSession {
    /// Load the OCR session from a directory holding the three PP-OCRv5
    /// `.onnx` models (their fixed filenames are baked into the Rust side).
    ///
    /// `useOrientationCls` controls whether the textline-orientation classifier
    /// is loaded/run (default true). Passing false skips the per-crop classify
    /// pass — faster, at the cost of not correcting 180°-flipped lines.
    static func load(modelsDirectory: URL, useOrientationCls: Bool = true) throws -> OcrSession {
        try OcrSession(modelDir: modelsDirectory.path, useOrientationCls: useOrientationCls)
    }

    /// Scan encoded image bytes (JPEG/PNG) using the current local date for
    /// date inference / the placeholder date.
    func scan(imageData: Data, creditCardAccount: String) throws -> ReceiptResult {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = DateYmd(
            year: Int32(c.year ?? 1970),
            month: UInt32(c.month ?? 1),
            day: UInt32(c.day ?? 1)
        )
        return try scan(imageBytes: imageData, today: today, creditCardAccount: creditCardAccount)
    }
}
