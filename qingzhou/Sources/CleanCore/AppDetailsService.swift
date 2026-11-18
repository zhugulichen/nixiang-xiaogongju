import Foundation
import CoreServices
import Darwin
import MachO.dyld.utils

public enum AppCompatibilityStatus: String, CaseIterable, Sendable {
    case native = "基本条件匹配"
    case requiresTranslation = "需要系统转译"
    case incompatible = "发现不兼容条件"
    case unknown = "尚不能判断"
}

public struct AppDetails: Identifiable, Sendable {
    public var id: String { app.id }
    public let app: AppRecord
    public var buildVersion: String?
    public var executableURL: URL?
    public var architectures: [String] = []
    public var minimumSystemVersion: String?
    public var minimumByArchitecture: [String: String] = [:]
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var lastUsedAt: Date?
    public var compatibility: AppCompatibilityStatus = .unknown
    public var message = "缺少可核对的应用资料。"

    public init(app: AppRecord) { self.app = app }
}

struct DetailsHost: Sendable {
    let architecture: String
    let system: OperatingSystemVersion
    static let current: Self = {
        var supportsARM: Int32 = 0
        var size = MemoryLayout.size(ofValue: supportsARM)
        let arm = sysctlbyname("hw.optional.arm64", &supportsARM, &size, nil, 0) == 0 && supportsARM == 1
        return Self(architecture: arm ? "arm64" : "x86_64", system: ProcessInfo.processInfo.operatingSystemVersion)
    }()
}

struct AppExecutableSlice {
    let name: String
    let desktop: Bool?
    let minimum: String?
}

public enum AppDetailsService {
    // This nonisolated async service runs outside the UI actor. Cancellation travels
    // with the caller, including the reads between items in an overview scan.
    public static func inspect(app: AppRecord) async throws -> AppDetails {
        try read(app: app, host: .current, includeLastUsed: true)
    }

    public static func compatibility(for app: AppRecord) async throws -> AppDetails {
        try read(app: app, host: .current, includeLastUsed: false)
    }

    static func read(app: AppRecord, host: DetailsHost, includeLastUsed: Bool) throws -> AppDetails {
        try Task.checkCancellation()
        let url = app.url.standardizedFileURL
        var result = AppDetails(app: app)
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host),
              url.pathExtension.lowercased() == "app", !app.url.pathComponents.contains("..") else { return result }
        // Refuse symlinks in every component at open time, including a replaced parent.
        let dir = open(systemAliasPath(url.path), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard dir >= 0 else {
            result.message = "应用路径已改变、没有读取许可或经过符号链接。"
            return result
        }
        defer { close(dir) }
        if let attrs = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
            result.createdAt = attrs.creationDate
            result.modifiedAt = attrs.contentModificationDate
        }
        if includeLastUsed, let indexed = MDItemCreateWithURL(nil, url as CFURL) {
            result.lastUsedAt = MDItemCopyAttribute(indexed, kMDItemLastUsedDate) as? Date
        }
        try Task.checkCancellation()
        var wrapper = stat()
        if fstatat(dir, "WrappedBundle", &wrapper, AT_SYMLINK_NOFOLLOW) == 0 {
            result.message = "此应用使用手机应用包装格式，运行条件由系统评估。"
            return result
        }
        guard let info = readInfo(in: dir) else {
            result.message = "无法读取主程序的信息文件。"
            return result
        }
        if !app.bundleID.isEmpty, info["CFBundleIdentifier"] as? String != app.bundleID {
            result.message = "此位置的应用身份缺失或已经更换，请重新扫描。"
            return result
        }
        result.buildVersion = info["CFBundleVersion"] as? String
        result.minimumSystemVersion = info["LSMinimumSystemVersion"] as? String
        let perArch = info["LSMinimumSystemVersionByArchitecture"] as? [String: Any] ?? [:]
        result.minimumByArchitecture = perArch.compactMapValues { $0 as? String }
        if info["LSRequiresIPhoneOS"] as? Bool == true || (info["CFBundleSupportedPlatforms"] as? [String])?.contains(where: { $0.lowercased() == "macosx" }) == false {
            result.message = "应用声明了其他运行平台，其运行条件由系统评估。"
            return result
        }
        guard let name = info["CFBundleExecutable"] as? String,
              !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\0") else {
            result.message = "应用未声明可核对的主程序文件名。"
            return result
        }
        let relative = "Contents/MacOS/" + name
        let fd = openat(dir, relative, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            result.message = "主程序无法读取，或主程序路径经过符号链接。"
            return result
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_mode & 0o111 != 0 else {
            result.message = "主程序不是可执行的普通文件。"
            return result
        }
        result.executableURL = url.appendingPathComponent(relative)
        var slices: [AppExecutableSlice] = []
        var incomplete = false
        let rc = macho_for_each_slice_in_fd(fd) { header, _, size, stop in
            guard !Task.isCancelled, slices.count < 64, let slice = sliceInfo(header, bytes: size) else {
                incomplete = true
                stop.pointee = true
                return
            }
            slices.append(slice)
        }
        try Task.checkCancellation()
        guard rc == 0, !incomplete, !slices.isEmpty else {
            result.message = "主程序为脚本、格式无法识别或头部不完整。"
            return result
        }
        result.architectures = Array(Set(slices.map(\.name))).sorted()
        guard (info["LSMinimumSystemVersion"] == nil || result.minimumSystemVersion != nil),
              (info["LSMinimumSystemVersionByArchitecture"] == nil || info["LSMinimumSystemVersionByArchitecture"] is [String: Any]),
              perArch.count == result.minimumByArchitecture.count else {
            result.message = "应用声明的系统版本格式无法识别。"
            return result
        }
        let assessment = assess(slices: slices, host: host, globalMinimum: result.minimumSystemVersion,
                                perArchitecture: result.minimumByArchitecture, requiresNative: info["LSRequiresNativeExecution"] as? Bool == true)
        result.compatibility = assessment.0
        result.message = assessment.1
        return result
    }

    // Foundation can canonicalize the OS-owned /private aliases back to /var or /tmp.
    // Expand only these exact OS aliases; O_NOFOLLOW_ANY still rejects user symlinks.
    private static func systemAliasPath(_ path: String) -> String {
        for (alias, target) in [("/var", "private/var"), ("/tmp", "private/tmp")] {
            guard path.hasPrefix(alias + "/"),
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: alias),
                  destination == target || destination == "/" + target else { continue }
            return "/" + target + path.dropFirst(alias.count)
        }
        return path
    }

    private static func readInfo(in dir: Int32) -> [String: Any]? {
        let fd = openat(dir, "Contents/Info.plist", O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        let limit = 2_000_000
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= limit,
              let data = try? file.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func sliceInfo(_ header: UnsafePointer<mach_header>, bytes: Int) -> AppExecutableSlice? {
        guard bytes >= MemoryLayout<mach_header>.size else { return nil }
        let h = header.pointee
        guard h.magic == MH_MAGIC || h.magic == MH_MAGIC_64, h.filetype == MH_EXECUTE,
              let cName = macho_arch_name_for_mach_header(header) else { return nil }
        let start = h.magic == MH_MAGIC_64 ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size
        let end = start + Int(h.sizeofcmds)
        guard end <= bytes, h.sizeofcmds <= 4_194_304, h.ncmds <= 16_384 else { return nil }
        let base = UnsafeRawPointer(header)
        var pos = start
        var platforms: [UInt32: UInt32] = [:]
        for _ in 0..<h.ncmds {
            guard pos + MemoryLayout<load_command>.size <= end else { return nil }
            let command = base.loadUnaligned(fromByteOffset: pos, as: load_command.self)
            guard command.cmdsize >= 8, pos + Int(command.cmdsize) <= end else { return nil }
            if command.cmd == LC_BUILD_VERSION {
                guard command.cmdsize >= MemoryLayout<build_version_command>.size else { return nil }
                let build = base.loadUnaligned(fromByteOffset: pos, as: build_version_command.self)
                platforms[build.platform] = build.minos
            } else if [LC_VERSION_MIN_MACOSX, LC_VERSION_MIN_IPHONEOS, LC_VERSION_MIN_TVOS, LC_VERSION_MIN_WATCHOS].contains(Int32(bitPattern: command.cmd)) {
                guard command.cmdsize >= MemoryLayout<version_min_command>.size else { return nil }
                let version = base.loadUnaligned(fromByteOffset: pos, as: version_min_command.self)
                platforms[command.cmd == LC_VERSION_MIN_MACOSX ? UInt32(PLATFORM_MACOS) : 0] = version.version
            }
            pos += Int(command.cmdsize)
        }
        guard pos == end else { return nil }
        let macVersion = platforms[UInt32(PLATFORM_MACOS)]
        let desktop = macVersion != nil || platforms[UInt32(PLATFORM_MACCATALYST)] != nil
        let minimum = macVersion.map { "\($0 >> 16).\(($0 >> 8) & 0xff).\($0 & 0xff)" }
        return .init(name: String(cString: cName), desktop: platforms.isEmpty ? nil : desktop, minimum: minimum)
    }

    static func assess(slices: [AppExecutableSlice], host: DetailsHost, globalMinimum: String?,
                       perArchitecture: [String: String], requiresNative: Bool) -> (AppCompatibilityStatus, String) {
        let system = [host.system.majorVersion, host.system.minorVersion, host.system.patchVersion]
        var translated = false, uncertain = false
        var tooNew: String?
        func parsed(_ text: String) -> [Int]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == parts.count else { return nil }
            return numbers + Array(repeating: 0, count: 3 - numbers.count)
        }
        if let globalMinimum {
            guard let version = parsed(globalMinimum) else { return (.unknown, "应用声明的最低系统版本格式无法识别。") }
            if system.lexicographicallyPrecedes(version) { return (.incompatible, "应用要求系统 \(globalMinimum) 或更高版本。") }
        }
        for slice in slices {
            let family: String
            switch slice.name {
            case "arm64", "arm64e", "arm64e.x1": family = "arm64"
            case "x86_64", "x86_64h": family = "x86_64"
            case "i386", "ppc", "ppc64", "armv7", "armv7s": continue
            default: uncertain = true; continue
            }
            let needsTranslation = host.architecture == "arm64" && family == "x86_64"
            guard family == host.architecture || (needsTranslation && !requiresNative) else { continue }
            guard slice.desktop == true else { uncertain = true; continue }
            var usable = true
            for requirement in [perArchitecture[slice.name], perArchitecture[family], slice.minimum].compactMap({ $0 }) {
                guard let minimum = parsed(requirement) else { uncertain = true; usable = false; break }
                if system.lexicographicallyPrecedes(minimum) { tooNew = requirement; usable = false; break }
            }
            guard usable else { continue }
            if needsTranslation { translated = true }
            else { return (.native, "主程序包含本机架构，已核对的最低系统要求相符。") }
        }
        if translated { return (.requiresTranslation, "可用的英特尔版本需要系统转译，具体可用性由系统决定。") }
        if uncertain || slices.isEmpty { return (.unknown, "当前架构、平台或系统要求有未确认项目。") }
        if let tooNew { return (.incompatible, "本机可选架构要求系统 \(tooNew) 或更高版本。") }
        return (.incompatible, "主程序缺少适用的处理器架构，或应用要求原生执行。")
    }
}
