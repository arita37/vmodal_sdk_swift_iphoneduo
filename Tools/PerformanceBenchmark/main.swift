import Foundation
import VModalSDK

actor BenchmarkControlTransport: VModalTransport {
    private var sequence = 0
    func send(_ request: VModalRequest) async throws -> VModalResponse {
        sequence += 1
        let isPresign = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "ttl" }) == true
        let body = isPresign
            ? "{\"url\":\"http://localhost:9090/put/\(sequence)\",\"key\":\"key-\(sequence)\"}"
            : "{\"dest_path\":\"benchmark/item-\(sequence)\"}"
        let data = Data(body.utf8)
        return VModalResponse(statusCode: 200, declaredLength: Int64(data.count), body: AsyncThrowingStream {
            $0.yield(data); $0.finish()
        })
    }
    func close() async {}
}

actor BenchmarkSignedTransport: SignedUploadTransport {
    private var active = 0
    private(set) var peakActive = 0
    private(set) var putCount = 0
    private(set) var uploadedBytes: Int64 = 0

    func put(
        source: UploadSource, range: Range<Int64>?, url: URL, headers: [String: String],
        timeout: Duration, cancellation: CancellationToken,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> SignedUploadResult {
        active += 1
        peakActive = max(peakActive, active)
        putCount += 1
        defer { active -= 1 }
        let selected = range ?? 0 ..< source.length
        var sent: Int64 = 0
        for try await chunk in try source.open(
            offset: selected.lowerBound, length: selected.upperBound - selected.lowerBound
        ) {
            try await cancellation.throwIfCanceled()
            sent += Int64(chunk.count)
            await progress(sent)
            try await Task.sleep(for: .milliseconds(1))
        }
        uploadedBytes += sent
        return SignedUploadResult(statusCode: 200, etag: "benchmark", md5: "benchmark")
    }
    func close() async {}
}

func benchmarkSource(index: Int, length: Int64) throws -> UploadSource {
    try UploadSource(
        filename: "benchmark-\(index).mp4", length: length,
        sourceID: "benchmark:\(index):\(length)", versionTag: "1"
    ) {
        AsyncThrowingStream { continuation in
            Task {
                var left = length
                while left > 0 {
                    let count = Int(min(64 * 1_024, left))
                    continuation.yield(Data(repeating: UInt8(index % 251), count: count))
                    left -= Int64(count)
                }
                continuation.finish()
            }
        }
    }
}

let args = Array(ProcessInfo.processInfo.arguments.dropFirst())
let itemCount = args.first.flatMap(Int.init) ?? 4
let itemBytes = args.dropFirst().first.flatMap(Int64.init) ?? 1_024 * 1_024
guard itemCount > 0, itemBytes > 0, itemBytes <= VideoUploadOptions.maxVideoUploadBytes else {
    throw ValidationError("Usage: PerformanceBenchmark [ITEM_COUNT] [ITEM_BYTES]")
}
let control = BenchmarkControlTransport()
let signed = BenchmarkSignedTransport()
let config = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "benchmark")
let collections = CollectionsResource(http: HTTPClient(config: config, transport: control), signedUploadTransport: signed)
let sources = try (0 ..< itemCount).map { try benchmarkSource(index: $0, length: itemBytes) }
let start = ContinuousClock.now
let upload = collections.videoUploadBulk(
    sources, collectionName: "benchmark__collection", subCollectionName: "stream",
    options: .init(maxConcurrency: min(4, itemCount))
)
let observer = Task {
    var count = 0
    for await _ in upload.progress { count += 1 }
    return count
}
let result = try await upload.result
let progressEvents = await observer.value
let elapsed = start.duration(to: .now)
let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
let bytes = await signed.uploadedBytes
let peak = await signed.peakActive
let puts = await signed.putCount
print("items=\(result.total) bytes=\(bytes) seconds=\(seconds) throughput_bytes_per_second=\(Int(Double(bytes) / max(seconds, 0.000_001))) source_chunk_bytes=65536 progress_events=\(progressEvents) active_put_peak=\(peak) puts=\(puts)")
