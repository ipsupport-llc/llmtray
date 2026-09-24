import Foundation

/// Model folder sizes and free disk space.
public enum DiskUsage {
    /// Allocated size of every file under `path` (a symlinked model folder
    /// is measured where it points; links inside aren't followed, so
    /// nothing is counted twice).
    public static func directorySize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// The folder may not exist yet (nothing downloaded): the nearest
    /// existing parent is on the same volume.
    public static func freeSpace(at path: String) -> Int64? {
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
