import Foundation

/// Device facts and preflight checks shared by capture providers.
/// (`BroadcastPipeline` keeps private copies of these until it moves onto
/// `FramePipeline` after the ReplayKit device validation.)
enum DeviceInfo {
    static let minimumFreeBytes: Int64 = 500 * 1_048_576

    struct LowStorageError: LocalizedError {
        var freeBytes: Int64
        var errorDescription: String? {
            "Not enough free storage to start coaching (\(freeBytes / 1_048_576) MB free, 500 MB needed)."
        }
    }

    /// Hardware identifier, e.g. "iPhone16,1".
    static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func checkFreeStorage(at url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < minimumFreeBytes {
            throw LowStorageError(freeBytes: free)
        }
    }
}
