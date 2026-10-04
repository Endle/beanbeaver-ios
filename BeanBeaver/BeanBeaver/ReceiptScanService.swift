import Foundation
import BBReceiptKit

struct ReceiptScanRequest {
    let imageData: Data
    let creditCardAccount: String
    let currency: String
    let taxAccount: String
    let options: ParseOptions
    var useOrientationCls = OcrSessionProvider.useOrientationCls
}

/// Both camera and batch scans use the same serial worker. Loading the models
/// and running synchronous Rust OCR happen off the main actor. An async actor
/// method alone would not serialize work across an await.
protocol ReceiptScanning {
    func scan(_ request: ReceiptScanRequest) async throws -> ReceiptResult
}

final class ReceiptScanService: ReceiptScanning, @unchecked Sendable {
    static let shared = ReceiptScanService()
    private static let queue = DispatchQueue(label: "com.beanbeaver.scan", qos: .userInitiated)
    private let perform: (ReceiptScanRequest) throws -> ReceiptResult

    init(perform: @escaping (ReceiptScanRequest) throws -> ReceiptResult = { request in
        let session = try OcrSessionProvider.loaded(useOrientationCls: request.useOrientationCls)
        return try session.scan(imageData: request.imageData,
                                creditCardAccount: request.creditCardAccount,
                                currency: request.currency, taxAccount: request.taxAccount,
                                options: request.options)
    }) {
        self.perform = perform
    }

    func scan(_ request: ReceiptScanRequest) async throws -> ReceiptResult {
        // Once synchronous OCR has started it runs to completion. Its owner
        // decides whether the result still belongs to a live request/draft.
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try self.perform(request) })
            }
        }
    }
}

/// Accessed only by ReceiptScanService's serial queue.
enum OcrSessionProvider {
    private static var session: OcrSession?
    private static var loadedWithOrientationCls: Bool?

    static var useOrientationCls: Bool {
        !UserDefaults.standard.bool(forKey: "skipOrientationCheck")
    }

    fileprivate static func loaded(useOrientationCls: Bool) throws -> OcrSession {
        if let session, loadedWithOrientationCls == useOrientationCls { return session }
        guard let dir = Bundle.main.resourceURL else {
            throw NSError(domain: "BeanBeaver", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No app resource bundle"])
        }
        let loaded = try OcrSession.load(modelsDirectory: dir, useOrientationCls: useOrientationCls)
        session = loaded
        loadedWithOrientationCls = useOrientationCls
        return loaded
    }
}
