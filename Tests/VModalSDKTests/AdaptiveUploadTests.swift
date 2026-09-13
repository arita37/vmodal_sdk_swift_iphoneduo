import XCTest
@testable import VModalSDK

final class AdaptiveUploadTests: XCTestCase {
    func testSharedVectors() throws {
        let mib: Int64 = 1_024 * 1_024; let gib = 1_024 * mib
        let values: [(Int64, UploadConditions, String, Int64, Int, Int, Duration)] = [
            (10 * mib, .init(deviceMemory: .low), "small_conservative", 5 * mib, 1, 6, .seconds(360)),
            (100 * mib, .init(networkType: .cellular, networkSpeed: .standard), "medium_cellular", 16 * mib, 2, 5, .seconds(360)),
            (gib, .init(networkType: .wifi, networkSpeed: .standard), "large_balanced", 64 * mib, 3, 5, .seconds(480)),
            (8 * gib, .init(networkType: .wifi, networkSpeed: .fast, deviceMemory: .high), "huge_fast", 256 * mib, 4, 5, .seconds(480)),
        ]
        for item in values {
            let preset = try AdaptiveUploadPolicy.select(item.0, conditions: item.1)
            XCTAssertEqual(preset.name, item.2); XCTAssertEqual(preset.partSizeBytes, item.3)
            XCTAssertEqual(preset.maxConcurrency, item.4); XCTAssertEqual(preset.maxPartAttempts, item.5); XCTAssertEqual(preset.partTimeout, item.6)
        }
    }

    func testPartCeilingAndSingleModeNoAdaptation() throws {
        let mib: Int64 = 1_024 * 1_024
        let preset = try AdaptiveUploadPolicy.select(10_001 * 5 * mib, conditions: .init())
        XCTAssertLessThanOrEqual((10_001 * 5 * mib + preset.partSizeBytes - 1) / preset.partSizeBytes, 10_000)
        let options = VideoUploadOptions(adaptiveConditions: .init(networkType: .wifi, networkSpeed: .fast, deviceMemory: .high))
        XCTAssertEqual(try options.resolvedFor(10 * mib).partSizeBytes, options.partSizeBytes)
    }
}
