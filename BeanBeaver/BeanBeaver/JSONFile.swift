import Foundation
import Observation

/// A failed read must never become an empty store that overwrites the source.
/// Atomic writes preserve the last successful snapshot; ordered writes keep a
/// slower, older snapshot from replacing a newer one. Stores own retry policy.
@Observable
@MainActor
final class JSONFile<Value: Codable> {
    let url: URL
    private(set) var issue: String?
    private(set) var loadFailed = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let writer = Writer()

    private final class Writer: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.beanbeaver.JSONFile", qos: .utility)
        // Accessed only on queue, including the synchronous flush barrier.
        var lastError: String?
    }

    init(url: URL) { self.url = url }

    func load() -> Value? {
        do {
            let value = try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
            loadFailed = false
            issue = nil
            return value
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                loadFailed = false
                issue = nil
            } else {
                loadFailed = true
                issue = "Could not open \(url.lastPathComponent). Existing data has been kept; changes are paused. \(error.localizedDescription)"
            }
            return nil
        }
    }

    /// Returns false immediately for a blocked store or a synchronous failure.
    /// Background completion publishes an observable issue, also applied by flush.
    @discardableResult
    func save(_ value: Value, background: Bool = false) -> Bool {
        guard !loadFailed else { return false }
        generation += 1
        let current = generation
        let url = url
        let writer = writer
        let write = {
            do {
                let data = try JSONEncoder().encode(value)
                try data.write(to: url, options: .atomic)
                writer.lastError = nil
            } catch {
                writer.lastError = "Could not save \(url.lastPathComponent). Changes are only in memory. Retry before closing the app. \(error.localizedDescription)"
            }
        }
        if background {
            writer.queue.async { [weak self] in
                write()
                let message = writer.lastError
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current else { return }
                    self.issue = message
                }
            }
            return true
        }
        writer.queue.sync(execute: write)
        issue = writer.queue.sync { writer.lastError }
        return issue == nil
    }

    func flush() {
        guard !loadFailed else { return }
        issue = writer.queue.sync { writer.lastError }
    }
}
