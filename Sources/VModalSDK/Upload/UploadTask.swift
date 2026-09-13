import Foundation

public enum UploadState: Sendable, Equatable { case running, succeeded, failed, canceled }

public struct UploadProgress: Sendable, Equatable {
    public let uploadedBytes: Int64
    public let totalBytes: Int64
    public var percent: Int { totalBytes <= 0 ? 0 : min(100, Int(uploadedBytes * 100 / totalBytes)) }
    public init(uploadedBytes: Int64, totalBytes: Int64) { self.uploadedBytes = uploadedBytes; self.totalBytes = totalBytes }
}

public final class UploadTask<Result: Sendable>: Sendable {
    public typealias Runner = @Sendable (CancellationToken, @escaping @Sendable (UploadProgress) async -> Void) async throws -> Result
    private let work: Task<Result, Error>
    private let cancellation: CancellationToken
    private let status: UploadStatus
    private let progressHub: UploadProgressHub
    public var progress: AsyncStream<UploadProgress> { progressHub.stream() }

    init(runner: @escaping Runner) {
        let token = CancellationToken(); let status = UploadStatus()
        let hub = UploadProgressHub()
        cancellation = token; self.status = status; progressHub = hub
        work = Task {
            do {
                let value = try await runner(token) { value in await status.emit(value, to: hub) }
                try Task.checkCancellation()
                try await token.throwIfCanceled(); await status.finish(.succeeded, progress: hub)
                return value
            } catch is CancellationError {
                await status.finish(.canceled, progress: hub); throw OperationCanceledError()
            } catch let error as OperationCanceledError {
                await status.finish(.canceled, progress: hub); throw error
            } catch {
                await status.finish(.failed, progress: hub); throw error
            }
        }
    }

    public var result: Result { get async throws { try await work.value } }
    public var state: UploadState { get async { await status.value } }
    public func cancel() { work.cancel(); Task { await cancellation.cancel() } }
}

private actor UploadStatus {
    private(set) var value: UploadState = .running
    private var seen: Int64 = 0; private var emitted: Int64 = 0
    private var emittedAt: ContinuousClock.Instant?; private var terminal = false

    func emit(_ item: UploadProgress, to progress: UploadProgressHub) {
        guard value == .running else { return }
        let safe = max(seen, min(item.uploadedBytes, item.totalBytes)); seen = safe
        let isTerminal = item.totalBytes > 0 && safe == item.totalBytes
        let now = ContinuousClock.now
        if isTerminal, !terminal { terminal = true; emitted = safe; emittedAt = now; progress.emit(.init(uploadedBytes: safe, totalBytes: item.totalBytes)); return }
        guard safe > emitted else { return }
        let first = emittedAt == nil
        let byteReady = item.totalBytes > 0 && (safe - emitted) * 100 >= item.totalBytes
        let timeReady = emittedAt.map { now - $0 >= .milliseconds(250) } ?? false
        guard first || byteReady || timeReady else { return }
        emitted = safe; emittedAt = now; progress.emit(.init(uploadedBytes: safe, totalBytes: item.totalBytes))
    }

    func finish(_ state: UploadState, progress: UploadProgressHub) {
        guard value == .running else { return }
        value = state; progress.finish()
    }
}

private final class UploadProgressHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<UploadProgress>.Continuation] = [:]
    private var last: UploadProgress?
    private var finished = false

    func stream() -> AsyncStream<UploadProgress> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            if let last { continuation.yield(last) }
            if finished { continuation.finish() }
            else { continuations[id] = continuation }
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    func emit(_ value: UploadProgress) {
        lock.lock()
        last = value
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets { target.yield(value) }
    }

    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for target in targets { target.finish() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
