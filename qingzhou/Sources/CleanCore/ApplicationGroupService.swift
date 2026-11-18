import Foundation
import Darwin
import Security

/// Signed membership is evidence of shared use, never of exclusive ownership.
public enum ApplicationGroupService {
    struct Declaration {
        let identifier: String
        let team: String
        let groups: [String]
    }

    private static let appleSigner: SecRequirement? = {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()
    private static let maximumGroups = 128

    public static func declaredIdentifiers(at application: URL, expectedBundleID: String) -> Set<String> {
        declaredIdentifiers(at: application, expectedBundleID: expectedBundleID, read: signedDeclaration)
    }

    static func declaredIdentifiers(at application: URL, expectedBundleID: String,
                                    read: (URL) -> Declaration?) -> Set<String> {
        guard !Task.isCancelled, application.pathExtension.lowercased() == "app", !expectedBundleID.isEmpty,
              !isReserved(expectedBundleID), physicalDirectory(application) else { return [] }
        let bundle = ApplicationMetadata.wrappedBundle(in: application) ?? application
        guard physicalDirectory(bundle), let main = read(bundle), main.identifier == expectedBundleID,
              validTeam(main.team) else { return [] }
        var groups = eligibleGroups(main.groups, team: main.team)
        // Only immediate embedded extensions in standard directories qualify. Never follow aliases.
        for relative in ["Contents/PlugIns", "Contents/Extensions", "PlugIns", "Extensions"] {
            let parent = bundle.appendingPathComponent(relative)
            guard physicalDirectory(parent), let entries = FileManager.default.enumerator(at: parent, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, _ in false }) else { continue }
            for (index, entry) in entries.enumerated() {
                if Task.isCancelled { return [] }
                if index >= 64 { break }
                guard let candidate = entry as? URL, candidate.pathExtension.lowercased() == "appex",
                      physicalPath(candidate.deletingLastPathComponent()) == physicalPath(parent), physicalDirectory(candidate),
                      let child = read(candidate), child.team == main.team, child.identifier.hasPrefix(main.identifier + "."),
                      !isReserved(child.identifier) else { continue }
                groups.formUnion(eligibleGroups(child.groups, team: main.team))
                guard groups.count <= maximumGroups else { return [] }
            }
        }
        return groups
    }

    /// Return only real, exactly named direct children. Never invoke the system API which creates a container.
    public static func containerURLs(for identifiers: Set<String>, home: URL) -> [URL] {
        let parent = home.appendingPathComponent("Library/Group Containers")
        guard !identifiers.isEmpty, identifiers.count <= maximumGroups, physicalDirectory(parent) else { return [] }
        return identifiers.sorted().compactMap { name in
            guard !Task.isCancelled, validGroup(name) else { return nil }
            let url = parent.appendingPathComponent(name)
            let fd = open(physicalPath(url), O_EVTONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            // An exact path lookup alone can resolve a differently cased name on APFS.
            var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &bytes) == 0,
                  URL(fileURLWithPath: String(cString: bytes)).lastPathComponent == name else { return nil }
            return url
        }
    }

    // Foundation canonicalizes /private/tmp and /private/var to their system aliases.
    // Keep O_NOFOLLOW_ANY in force below those two verified operating-system links.
    private static func physicalPath(_ url: URL) -> String {
        let path = url.path
        for (alias, target) in [("/tmp", "private/tmp"), ("/var", "private/var")] where path.hasPrefix(alias + "/") {
            let actual = try? FileManager.default.destinationOfSymbolicLink(atPath: alias)
            if actual == target || actual == "/" + target { return "/" + target + path.dropFirst(alias.count) }
        }
        return path
    }

    private static func physicalDirectory(_ url: URL) -> Bool {
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host), !url.pathComponents.contains("..") else { return false }
        let fd = open(physicalPath(url), O_EVTONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        close(fd); return true
    }

    private static func regularFile(_ url: URL) -> Bool {
        let fd = open(physicalPath(url), O_EVTONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    static func signedDeclaration(at bundle: URL) -> Declaration? {
        // Resolve the ordinary executable layout first so Security doesn't resolve an external symlink.
        let nativeInfo = bundle.appendingPathComponent("Contents/Info.plist")
        let native = regularFile(nativeInfo)
        let plist = native ? nativeInfo : bundle.appendingPathComponent("Info.plist")
        let descriptor = open(physicalPath(plist), O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0, attributes.st_size <= 2_000_000,
              let data = try? file.read(upToCount: 2_000_001), data.count <= 2_000_000,
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let expected = info["CFBundleIdentifier"] as? String, !expected.isEmpty,
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.utf8.contains(0), let appleSigner else { return nil }
        let executable = (native ? bundle.appendingPathComponent("Contents/MacOS") : bundle).appendingPathComponent(name)
        guard regularFile(executable) else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        // Authenticate the signed metadata without traversing every resource or contacting a validation service.
        let policy = SecCSFlags(rawValue: kSecCSBasicValidateOnly).union(.noNetworkAccess)
        guard SecStaticCodeCheckValidity(code, policy, appleSigner) == errSecSuccess else { return nil }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let signing = raw as? [String: Any], let id = signing[kSecCodeInfoIdentifier as String] as? String,
              id == expected, let team = signing[kSecCodeInfoTeamIdentifier as String] as? String, validTeam(team),
              let main = signing[kSecCodeInfoMainExecutable as String] as? URL,
              main.standardizedFileURL.path == executable.standardizedFileURL.path else { return nil }
        let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        return Declaration(identifier: id, team: team, groups: groups)
    }

    static func eligibleGroups(_ groups: [String], team: String) -> Set<String> {
        guard groups.count <= maximumGroups, validTeam(team) else { return [] }
        return Set(groups.filter { validGroup($0) && ($0.hasPrefix("group.") || $0.hasPrefix(team + ".")) })
    }

    private static func validTeam(_ team: String) -> Bool {
        team.utf8.count == 10 && team.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }

    private static func validGroup(_ group: String) -> Bool {
        guard group.utf8.count <= 255, let dot = group.firstIndex(of: ".") else { return false }
        let prefix = String(group[..<dot]); let suffix = String(group[group.index(after: dot)...])
        guard prefix == "group" || validTeam(prefix), !isReserved(suffix) else { return false }
        return suffix.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
            }
        } && !suffix.isEmpty
    }

    private static func isReserved(_ identifier: String) -> Bool {
        let name = identifier.lowercased()
        return ["com.apple", "group.com.apple", "apple", "cn.local.qingzhou", "com.qingzhou.cleaner", "local.qingzhou.cleaner", "org.qingzhou.cleaner"].contains { name == $0 || name.hasPrefix($0 + ".") }
    }
}
