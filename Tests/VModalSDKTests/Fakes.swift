import Foundation
@testable import VModalSDK

actor FakeTransport: VModalTransport {
    var responses: [Result<VModalResponse, Error>]
    private(set) var requests: [VModalRequest] = []
    private(set) var closeCount = 0

    init(_ responses: [Result<VModalResponse, Error>]) { self.responses = responses }

    func send(_ request: VModalRequest) async throws -> VModalResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw TransportError("missing fake response") }
        return try responses.removeFirst().get()
    }

    func close() async { closeCount += 1 }
}

func fakeResponse(_ status: Int = 200, body: String = "{}", declaredLength: Int64? = nil) -> VModalResponse {
    let data = Data(body.utf8)
    return VModalResponse(
        statusCode: status,
        headers: ["Content-Type": "application/json"],
        declaredLength: declaredLength ?? Int64(data.count),
        body: AsyncThrowingStream { stream in stream.yield(data); stream.finish() }
    )
}

actor FakeSignedTransport: SignedUploadTransport {
    private(set) var closeCount = 0
    private(set) var puts: [(UploadSource, Range<Int64>?, URL, [String: String])] = []
    func put(source: UploadSource, range: Range<Int64>?, url: URL, headers: [String: String], timeout: Duration, cancellation: CancellationToken, progress: @escaping @Sendable (Int64) async -> Void) async throws -> SignedUploadResult {
        puts.append((source, range, url, headers))
        await progress(range.map { $0.upperBound - $0.lowerBound } ?? source.length)
        return SignedUploadResult(statusCode: 200, etag: "md5", md5: "md5")
    }
    func close() async { closeCount += 1 }
}
