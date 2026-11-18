import Foundation
import Darwin

public struct SizeMeasurement: Equatable, Sendable {
    public let bytes: Int64
    public let isComplete: Bool
    public let inaccessibleCount: Int

    public init(bytes: Int64, isComplete: Bool, inaccessibleCount: Int) {
        self.bytes = bytes
        self.isComplete = isComplete
        self.inaccessibleCount = inaccessibleCount
    }
}

/// Complete, cancellable logical-size measurement. Counts regular file lengths, including hidden
/// files; does not claim allocated disk space or bytes that would actually be reclaimed by removal.
/// Hard-linked names are counted individually. Symbolic links and special files are not followed.
public enum SizeService {
    public static func measure(_ urls: [URL]) async -> [String: SizeMeasurement] {
        if Task.isCancelled { return measureSynchronously(urls, isCancelled: { true }) }
        let worker = Task.detached(priority: .utility) {
            measureSynchronously(urls, isCancelled: { Task.isCancelled })
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func measureSynchronously(_ urls: [URL], isCancelled: () -> Bool) -> [String: SizeMeasurement] {
        var results: [String: SizeMeasurement] = [:]
        for url in urls {
            let key = url.standardizedFileURL.path
            if results[key] != nil { continue }
            results[key] = measureOne(url, isCancelled: isCancelled)
        }
        return results
    }

    private static func measureOne(_ url: URL, isCancelled: () -> Bool) -> SizeMeasurement {
        if isCancelled() { return SizeMeasurement(bytes: 0, isComplete: false, inaccessibleCount: 0) }
        guard url.isFileURL else { return SizeMeasurement(bytes: 0, isComplete: false, inaccessibleCount: 1) }
        var path = url.standardizedFileURL.path
        // Accept the two well-known OS aliases, but never resolve arbitrary user symlinks.
        for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if path == alias || path.hasPrefix(alias + "/"),
               let link = try? FileManager.default.destinationOfSymbolicLink(atPath: alias),
               link == String(target.dropFirst()) || link == target {
                path = target + path.dropFirst(alias.count)
                break
            }
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return SizeMeasurement(bytes: 0, isComplete: false, inaccessibleCount: 1) }
        let components = path.split(separator: "/").map(String.init)
        for component in components {
            if isCancelled() { Darwin.close(descriptor); return SizeMeasurement(bytes: 0, isComplete: false, inaccessibleCount: 0) }
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            Darwin.close(descriptor)
            guard next >= 0 else { return SizeMeasurement(bytes: 0, isComplete: false, inaccessibleCount: 1) }
            descriptor = next
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            Darwin.close(descriptor)
            return SizeMeasurement(bytes: 0, isComplete: false, inaccessibleCount: 1)
        }
        let type = metadata.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFREG) {
            Darwin.close(descriptor)
            return SizeMeasurement(bytes: max(0, metadata.st_size), isComplete: !isCancelled(), inaccessibleCount: 0)
        }
        guard type == mode_t(S_IFDIR) else {
            Darwin.close(descriptor)
            return SizeMeasurement(bytes: 0, isComplete: true, inaccessibleCount: 0)
        }

        var bytes: Int64 = 0
        var inaccessible = 0
        var complete = true
        var stack: [UnsafeMutablePointer<DIR>] = []
        guard let root = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            return SizeMeasurement(bytes: 0, isComplete: false, inaccessibleCount: 1)
        }
        stack.append(root)
        defer { for directory in stack { closedir(directory) } }
        while let directory = stack.last {
            if isCancelled() { complete = false; break }
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { inaccessible += 1; complete = false }
                closedir(directory); stack.removeLast()
                continue
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var item = stat()
            let parentFD = dirfd(directory)
            guard fstatat(parentFD, name, &item, AT_SYMLINK_NOFOLLOW) == 0 else {
                inaccessible += 1; complete = false; continue
            }
            let itemType = item.st_mode & mode_t(S_IFMT)
            if itemType == mode_t(S_IFREG) {
                let addition = bytes.addingReportingOverflow(max(0, item.st_size))
                if addition.overflow { complete = false; inaccessible += 1; break }
                bytes = addition.partialValue
            } else if itemType == mode_t(S_IFDIR) {
                let childFD = Darwin.openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else { inaccessible += 1; complete = false; continue }
                if let child = fdopendir(childFD) { stack.append(child) }
                else { Darwin.close(childFD); inaccessible += 1; complete = false }
            }
        }
        return SizeMeasurement(bytes: bytes, isComplete: complete, inaccessibleCount: inaccessible)
    }
}
