import Foundation

public struct TranscodeResult: Sendable {
    public let output: URL; public let reused: Bool
    public init(output: URL, reused: Bool = false) { self.output = output; self.reused = reused }
}
public protocol VideoTranscoder: Sendable {
    var isPassthrough: Bool { get }
    func reduce(_ input: URL) async throws -> TranscodeResult
}
public struct PassthroughVideoTranscoder: VideoTranscoder {
    public let isPassthrough = true
    public init() {}
    public func reduce(_ input: URL) async throws -> TranscodeResult { TranscodeResult(output: input) }
}
