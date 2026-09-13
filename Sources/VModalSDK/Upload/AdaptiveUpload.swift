import Foundation

public enum UploadNetworkType: Sendable { case wifi, cellular, unknown }
public enum UploadNetworkSpeed: Sendable { case slow, standard, fast, unknown }
public enum UploadDeviceMemory: Sendable { case low, standard, high }

public struct UploadConditions: Sendable {
    public let networkType: UploadNetworkType; public let networkSpeed: UploadNetworkSpeed; public let deviceMemory: UploadDeviceMemory
    public init(networkType: UploadNetworkType = .unknown, networkSpeed: UploadNetworkSpeed = .unknown, deviceMemory: UploadDeviceMemory = .standard) {
        self.networkType = networkType; self.networkSpeed = networkSpeed; self.deviceMemory = deviceMemory
    }
}
public struct AdaptiveUploadPreset: Sendable, Equatable {
    public let name: String; public let partSizeBytes: Int64; public let maxConcurrency, maxPartAttempts: Int; public let partTimeout: Duration
}

public enum AdaptiveUploadPolicy {
    public static func select(_ sizeBytes: Int64, conditions: UploadConditions) throws -> AdaptiveUploadPreset {
        guard sizeBytes >= 0 else { throw ValidationError("size_bytes must not be negative") }
        let mib: Int64 = 1_024 * 1_024; let gib = 1_024 * mib
        let tier: String; let row: Int
        if sizeBytes < 100 * mib { tier = "small"; row = 0 }
        else if sizeBytes < gib { tier = "medium"; row = 1 }
        else if sizeBytes < 8 * gib { tier = "large"; row = 2 }
        else { tier = "huge"; row = 3 }
        let profile: String; let column: Int
        if conditions.deviceMemory == .low || conditions.networkSpeed == .slow { profile = "conservative"; column = 0 }
        else if conditions.networkType == .cellular { profile = "cellular"; column = 1 }
        else if conditions.networkType == .wifi && conditions.networkSpeed == .fast && conditions.deviceMemory == .high { profile = "fast"; column = 3 }
        else if conditions.networkType == .wifi { profile = "balanced"; column = 2 }
        else { profile = "conservative"; column = 0 }
        let table = [
            [[5, 1, 6, 360], [8, 2, 5, 300], [16, 3, 4, 240], [32, 4, 3, 180]],
            [[8, 1, 6, 480], [16, 2, 5, 360], [32, 3, 4, 300], [64, 4, 3, 240]],
            [[16, 1, 7, 720], [32, 2, 6, 600], [64, 3, 5, 480], [128, 4, 4, 360]],
            [[32, 1, 8, 900], [64, 2, 7, 720], [128, 3, 6, 600], [256, 4, 5, 480]],
        ]
        let values = table[row][column]
        let minimum = max(5 * mib, ((max(1, sizeBytes) + 9_999) / 10_000 + mib - 1) / mib * mib)
        return AdaptiveUploadPreset(name: "\(tier)_\(profile)", partSizeBytes: max(Int64(values[0]) * mib, minimum), maxConcurrency: values[1], maxPartAttempts: values[2], partTimeout: .seconds(values[3]))
    }
}
