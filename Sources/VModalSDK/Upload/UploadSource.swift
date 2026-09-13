import Foundation

public struct UploadSource: Sendable {
    public typealias StreamOpener = @Sendable () throws -> AsyncThrowingStream<Data, Error>
    public typealias RangeOpener = @Sendable (Int64) throws -> AsyncThrowingStream<Data, Error>

    public let length: Int64
    public let filename: String
    public let contentType: String
    public let sourceID: String
    public let versionTag: String
    public let localFile: URL?
    private let opener: StreamOpener
    private let rangeOpener: RangeOpener?

    public init(
        filename: String, length: Int64, contentType: String = "application/octet-stream",
        sourceID: String? = nil, versionTag: String = "", localFile: URL? = nil,
        opener: @escaping StreamOpener, rangeOpener: RangeOpener? = nil
    ) throws {
        try uploadString(filename, field: "file name", max: 1_024)
        try uploadString(contentType, field: "content type", max: 255)
        try uploadString(sourceID ?? filename, field: "source id", max: 4_096)
        guard length >= 0 else { throw ValidationError("content_length must be known for a signed upload") }
        self.filename = filename; self.length = length; self.contentType = contentType
        self.sourceID = sourceID ?? filename; self.versionTag = versionTag; self.localFile = localFile
        self.opener = opener; self.rangeOpener = rangeOpener
    }

    public init(fileURL: URL, filename: String? = nil, contentType: String? = nil) throws {
        guard fileURL.isFileURL else { throw ValidationError("file URL is required") }
        let url = fileURL.standardizedFileURL
        let info = try fileInfo(url)
        try self.init(
            filename: filename ?? url.lastPathComponent, length: info.size,
            contentType: contentType ?? mimeType(for: url), sourceID: url.path,
            versionTag: info.version, localFile: url,
            opener: { try fileRangeStream(url, offset: 0, length: info.size, version: info.version) },
            rangeOpener: { offset in try fileRangeStream(url, offset: offset, length: info.size - offset, version: info.version) }
        )
    }

    public func open(offset: Int64 = 0, length wanted: Int64? = nil) throws -> AsyncThrowingStream<Data, Error> {
        let count = wanted ?? (length - offset)
        guard offset >= 0, count >= 0, offset + count <= length else { throw ValidationError("upload source range is invalid") }
        let stream = try rangeOpener?(offset) ?? opener()
        let directRange = rangeOpener != nil
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var skip = directRange ? 0 : offset
                    var left = count
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        var start = 0
                        if skip > 0 {
                            if skip >= chunk.count { skip -= Int64(chunk.count); continue }
                            start = Int(skip); skip = 0
                        }
                        if left == 0 { break }
                        let take = min(Int64(chunk.count - start), left)
                        if take > 0 { continuation.yield(chunk.subdata(in: start ..< start + Int(take))); left -= take }
                    }
                    guard skip == 0, left == 0 else { throw TransportError("upload source ended early") }
                    continuation.finish()
                } catch is CancellationError { continuation.finish(throwing: OperationCanceledError()) }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private func uploadString(_ value: String, field: String, max: Int) throws {
    guard !value.isEmpty, value.count <= max,
          !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { throw ValidationError("invalid \(field)") }
}

private func fileInfo(_ url: URL) throws -> (size: Int64, version: String) {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
    guard values.isRegularFile == true, let size = values.fileSize, let date = values.contentModificationDate else {
        throw ValidationError("upload source file does not exist")
    }
    return (Int64(size), "\(size):\(Int64((date.timeIntervalSince1970 * 1_000).rounded()))")
}

private func fileRangeStream(_ url: URL, offset: Int64, length: Int64, version: String) throws -> AsyncThrowingStream<Data, Error> {
    guard try fileInfo(url).version == version else { throw TransportError("upload source changed during upload") }
    return AsyncThrowingStream { continuation in
        let task = Task.detached {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                var left = length
                while left > 0, !Task.isCancelled {
                    let data = try handle.read(upToCount: min(64 * 1_024, Int(left))) ?? Data()
                    guard !data.isEmpty else { throw TransportError("upload source ended early") }
                    left -= Int64(data.count); continuation.yield(data)
                }
                guard !Task.isCancelled else { throw OperationCanceledError() }
                guard left == 0 else { throw TransportError("upload source ended early") }
                guard try fileInfo(url).version == version else { throw TransportError("upload source changed during upload") }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
