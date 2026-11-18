#if SCANNER_STANDALONE_TESTS
import Foundation

private enum ScannerAssertionError: Error { case missingValue }
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
private func XCTAssertTrue(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value(), "断言失败", file: file, line: line)
}
private func XCTAssertFalse(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value(), "断言失败", file: file, line: line)
}
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs == rhs, "值不相等：\(lhs) / \(rhs)", file: file, line: line)
}
private func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw ScannerAssertionError.missingValue }
    return value
}
#else
import XCTest
@testable import CleanCore
#endif

final class ScannerTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var apps: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("QingzhouScannerTests-" + UUID().uuidString)
        home = root.appendingPathComponent("Home")
        apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    @discardableResult
    private func file(_ path: String, content: Data = Data("test".utf8)) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url)
        return url
    }
    @discardableResult
    private func app(_ name: String, identifier: String, parent: URL? = nil) throws -> URL {
        let url = (parent ?? apps).appendingPathComponent(name + ".app")
        let info = url.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": name, "CFBundleIdentifier": identifier, "CFBundleShortVersionString": "1.0"], format: .xml, options: 0)
        try data.write(to: info)
        return url
    }
    private var scanner: AppScanner { AppScanner(home: home, applicationRoots: [apps]) }

    func testRelatedFilesUsesWholeIdentifierAndNeverSelectsUserData() throws {
        try app("NotesTest", identifier: "org.example.notes")
        try file("Library/Caches/org.example.notes/data")
        try file("Library/Caches/org.example.notesplus/data")
        try file("Library/Preferences/org.example.notes.plist")
        try file("Library/Preferences/org.example.notes.other.plist")
        try file("Library/Application Support/org.example.notes/document")
        try file("Library/Containers/org.example.notes/document")
        let selectedApp = try XCTUnwrap(scanner.scanApplications().apps.first)
        let files = scanner.relatedFiles(for: selectedApp)
        XCTAssertTrue(files.contains { $0.url.lastPathComponent == "org.example.notes" && $0.kind == .cache && $0.defaultSelected })
        XCTAssertFalse(files.contains { $0.url.lastPathComponent == "org.example.notesplus" })
        XCTAssertFalse(files.contains { $0.url.lastPathComponent == "org.example.notes.other.plist" })
        XCTAssertTrue(files.contains { $0.kind == .preference && !$0.defaultSelected && $0.risk == .personal })
        XCTAssertTrue(files.contains { $0.kind == .support && !$0.defaultSelected && $0.risk == .personal })
        XCTAssertTrue(files.contains { $0.kind == .container && !$0.defaultSelected && $0.risk == .personal })
    }

    func testNameOnlyMatchAndSharedContainerNeedManualReview() throws {
        try app("Example", identifier: "org.example.notes")
        try file("Library/Caches/Example/a")
        try file("Library/Group Containers/ABCD123456.org.example.notes/a")
        let files = scanner.relatedFiles(for: try XCTUnwrap(scanner.scanApplications().apps.first))
        XCTAssertTrue(files.contains { $0.url.lastPathComponent == "Example" && !$0.defaultSelected })
        XCTAssertTrue(files.contains { $0.url.lastPathComponent == "ABCD123456.org.example.notes" && !$0.defaultSelected && $0.risk == .personal })
    }

    func testSignedGroupCanBeFoundWithoutOwnerInItsNameAndProtectsOtherMembers() throws {
        try app("One", identifier: "org.sample.alpha")
        try app("Two", identifier: "org.sample.beta")
        let group = "ABCD123456.shared-data"
        let namedForTwo = "group.org.sample.beta"
        for name in [group, namedForTwo, group + "-other"] {
            try file("Library/Group Containers/" + name + "/fixture")
        }
        var scan = scanner
        scan.readGroups = { _, identifier in identifier == "org.sample.alpha" ? [group, namedForTwo] : [] }
        let apps = scan.scanApplications().apps
        let first = try XCTUnwrap(apps.first { $0.name == "One" })
        let second = try XCTUnwrap(apps.first { $0.name == "Two" })
        let firstGroups = scan.relatedFiles(for: first).filter { $0.kind == .container }
        XCTAssertEqual(Set(firstGroups.map { $0.url.lastPathComponent }), [group, namedForTwo])
        XCTAssertTrue(firstGroups.allSatisfy { $0.risk == .protected && !$0.defaultSelected })
        let shared = scan.reviewedFiles(for: second, installed: scan.fileOwners(of: apps)).first { $0.url.lastPathComponent == namedForTwo }
        XCTAssertEqual(shared?.risk, .protected)
        XCTAssertTrue(scan.leftovers(installed: []).allSatisfy { $0.kind != .container })
    }

    func testSystemAppAndItsFilesAreProtected() throws {
        try app("SystemExample", identifier: "com.apple.SystemExample")
        try file("Library/Caches/com.apple.SystemExample/data")
        let selectedApp = try XCTUnwrap(scanner.scanApplications().apps.first)
        XCTAssertTrue(selectedApp.isProtected)
        XCTAssertTrue(scanner.relatedFiles(for: selectedApp).allSatisfy { $0.risk == .protected && !$0.defaultSelected })
        XCTAssertTrue(scanner.caches().allSatisfy { $0.risk == .protected })
    }

    func testDirectoryReportDistinguishesDeniedMissingLinkedAndEmpty() throws {
        let fm = FileManager.default
        let root = home.appendingPathComponent("Library")
        let caches = root.appendingPathComponent("Caches")
        let denied = root.appendingPathComponent("Logs")
        for url in [caches, denied] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("Cookies"), withDestinationURL: caches)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        let checks = scanner.recordingDirectories { $0.leftovers(installed: []) }.directories
        let outcomes = Dictionary(uniqueKeysWithValues: checks.map { ($0.url.lastPathComponent, $0.outcome) })
        XCTAssertEqual(outcomes["Caches"], .read)
        XCTAssertEqual(outcomes["Preferences"], .missing)
        XCTAssertEqual(outcomes["Cookies"], .skipped)
        if getuid() != 0 { XCTAssertEqual(outcomes["Logs"], .denied) }
        XCTAssertEqual(AppScanner.directoryFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))), .denied)
    }

    func testOrphanedAgentRequiresMissingScopedApplicationAndNoInstalledOwner() throws {
        let gone = apps.appendingPathComponent("Gone.app/Contents/MacOS/Gone").path
        let live = try app("Alive", identifier: "org.example.alive")
        for (label, program, owner) in [
            ("org.example.gone", gone, ""),
            ("org.example.active", live.appendingPathComponent("Contents/MacOS/Alive").path, ""),
            ("org.example.reused", gone, "org.example.alive"),
            ("org.example.tool", "/usr/bin/true", ""),
            ("com.apple.fixture", gone, ""),
            ("org.example.outside", "/Elsewhere/Gone.app/Contents/MacOS/Gone", "")
        ] {
            let value: [String: Any] = ["Label": label, "ProgramArguments": [program], "AssociatedBundleIdentifiers": [owner]]
            try file("Library/LaunchAgents/" + label + ".plist", content: PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0))
        }
        let files = scanner.leftovers(installed: scanner.scanApplications().apps)
        XCTAssertEqual(files.map(\.ownerBundleID), ["org.example.gone"])
        let first = try XCTUnwrap(files.first)
        XCTAssertFalse(first.defaultSelected)
    }

    func testLeftoversExcludeHelpersAndSystemComponents() throws {
        let parent = try app("Parent", identifier: "org.example.parent")
        try app("UnrelatedHelper", identifier: "net.another.helper", parent: parent.appendingPathComponent("Contents/Library/LoginItems"))
        try file("Library/Preferences/net.another.helper.plist")
        try file("Library/Preferences/org.example.parent.worker.plist")
        try file("Library/Preferences/com.apple.fake.plist")
        try file("Library/Preferences/net.removed.program.plist")
        let installed = scanner.scanApplications().apps
        XCTAssertEqual(installed.count, 1)
        let related = scanner.relatedFiles(for: try XCTUnwrap(installed.first))
        XCTAssertTrue(related.contains { $0.url.lastPathComponent == "net.another.helper.plist" })
        let leftovers = scanner.leftovers(installed: installed)
        XCTAssertEqual(leftovers.map(\.url.lastPathComponent), ["net.removed.program.plist"])
        XCTAssertTrue(leftovers.allSatisfy { !$0.defaultSelected })
    }

    func testContainerMetadataMatchesUUIDDirectory() throws {
        try app("Example", identifier: "org.example.notes")
        let data = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": "org.example.notes"], format: .binary, options: 0)
        try file("Library/Containers/ABC123/.com.apple.containermanagerd.metadata.plist", content: data)
        let files = scanner.relatedFiles(for: try XCTUnwrap(scanner.scanApplications().apps.first))
        XCTAssertTrue(files.contains { $0.kind == .container && $0.url.lastPathComponent == "ABC123" && !$0.defaultSelected })
    }

    func testByHostOnlyRecognizesExactIdentifierAndUUID() throws {
        try app("Example", identifier: "org.example.notes")
        try file("Library/Preferences/ByHost/org.example.notes.11111111-2222-3333-4444-555555555555.plist")
        try file("Library/Preferences/ByHost/org.example.notes.helper.plist")
        let files = scanner.relatedFiles(for: try XCTUnwrap(scanner.scanApplications().apps.first))
        XCTAssertEqual(files.filter { $0.kind == .preference }.count, 1)
    }

    func testKnownBrowserDirectoriesNeverSelectVendorRoot() throws {
        try app("Google Chrome", identifier: "com.google.Chrome")
        try file("Library/Application Support/Google/Chrome/Profile/document")
        try file("Library/Application Support/Google/Unrelated/document")
        try file("Library/Caches/Google/Chrome/cache")
        let files = scanner.relatedFiles(for: try XCTUnwrap(scanner.scanApplications().apps.first))
        XCTAssertTrue(files.contains { $0.url.path.hasSuffix("Application Support/Google/Chrome") && $0.risk == .personal && !$0.defaultSelected })
        XCTAssertTrue(files.contains { $0.url.path.hasSuffix("Caches/Google/Chrome") && $0.defaultSelected })
        XCTAssertFalse(files.contains { $0.url.lastPathComponent == "Google" || $0.url.lastPathComponent == "Unrelated" })
        XCTAssertTrue(scanner.caches().contains { $0.url.lastPathComponent == "Google" && $0.risk == .protected && !$0.defaultSelected })
    }

    func testHostPreferencesSharedWithInstalledHelperRemainProtected() throws {
        try app("Independent", identifier: "org.example.helper")
        let suite = try app("Suite", identifier: "org.example.suite")
        try app("Helper", identifier: "org.example.helper", parent: suite.appendingPathComponent("Contents/Library/LoginItems"))
        let name = "org.example.helper.11111111-2222-3333-4444-555555555555.plist"
        try file("Library/Preferences/ByHost/" + name)
        let installed = scanner.scanApplications().apps
        let owners = scanner.fileOwners(of: installed)
        for item in installed {
            let files = scanner.reviewedFiles(for: item, installed: owners)
            XCTAssertEqual(files.first { $0.url.lastPathComponent == name }?.risk, .protected)
        }
    }

    func testCaseInsensitiveNameMatchRemainsManual() throws {
        try app("NotesTest", identifier: "org.example.notes")
        try file("Library/Application Support/notestest/document")
        let files = scanner.relatedFiles(for: try XCTUnwrap(scanner.scanApplications().apps.first))
        XCTAssertTrue(files.contains { $0.url.lastPathComponent == "notestest" && !$0.defaultSelected })
    }

    func testExtensionsExcludeSystemLexiconsAndKeepUserPackages() throws {
        try file("Library/Dictionaries/DynamicPhraseLexicon_zh_Hans.db")
        try file("Library/Dictionaries/emoji_adaptation.db")
        try file("Library/Dictionaries/facemark.dat")
        try file("Library/Input Methods/learned.db")
        try file("Library/Services/notes.txt")
        try file("Library/Dictionaries/Fake.dictionary")
        try file("Library/Dictionaries/User.dictionary/Contents/Resources/dictionary.data")
        try file("Library/Input Methods/User.inputmethod/Contents/Resources/input.data")
        try file("Library/Services/User.workflow/Contents/document.wflow")
        try file("Library/PreferencePanes/User.prefPane/Contents/Resources/settings")
        let files = scanner.extensions().filter { $0.url.path.contains("/" + root.lastPathComponent + "/") }
        XCTAssertEqual(Set(files.map(\.url.lastPathComponent)), ["User.dictionary", "User.inputmethod", "User.workflow", "User.prefPane"])
        XCTAssertTrue(files.allSatisfy { $0.risk == .personal && !$0.defaultSelected })
    }

    func testAppleExtensionIdentifiersAreProtected() throws {
        let appleInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.TestDictionary"], format: .xml, options: 0)
        try file("Library/Dictionaries/System.dictionary/Contents/Info.plist", content: appleInfo)
        try file("Library/QuickLook/com.apple.Test.qlgenerator/Contents/Resources/data")
        let files = scanner.extensions().filter { $0.url.path.contains("/" + root.lastPathComponent + "/") }
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.risk == .protected && !$0.defaultSelected })
    }

    func testWrappedApplicationsAreDiscoveredAndNotLeftovers() throws {
        let outer = apps.appendingPathComponent("Wrapped.app")
        let inner = try app("InnerMobile", identifier: "org.example.mobile", parent: outer.appendingPathComponent("Wrapper"))
        // Mobile applications use a root Info.plist instead of Contents/Info.plist.
        try FileManager.default.moveItem(at: inner.appendingPathComponent("Contents/Info.plist"), to: inner.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(at: outer.appendingPathComponent("WrappedBundle"), withDestinationURL: inner)
        try file("Library/Preferences/org.example.mobile.plist")
        try file("Library/Containers/org.example.mobile/documents")
        let installed = scanner.scanApplications().apps
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed.first?.bundleID, "org.example.mobile")
        XCTAssertEqual(installed.first?.url.lastPathComponent, "Wrapped.app")
        XCTAssertTrue(scanner.leftovers(installed: installed).isEmpty)
        let wrappedApp = try XCTUnwrap(installed.first)
        XCTAssertTrue(scanner.relatedFiles(for: wrappedApp).contains { $0.kind == .container })
    }

    func testWrappedApplicationCannotBorrowOutsideIdentity() throws {
        let external = try app("Outside", identifier: "org.example.outside", parent: root.appendingPathComponent("Elsewhere"))
        let outer = apps.appendingPathComponent("InvalidWrapped.app")
        try FileManager.default.createDirectory(at: outer.appendingPathComponent("Wrapper"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: outer.appendingPathComponent("WrappedBundle"), withDestinationURL: external)
        XCTAssertTrue(scanner.scanApplications().apps.isEmpty)
    }

    func testSingleAppProtectsOtherCopiesAndSharedHelpers() throws {
        let a = try app("First", identifier: "org.sample.first")
        let b = try app("Second", identifier: "org.sample.second")
        try app("ShareService", identifier: "net.shared.service", parent: a.appendingPathComponent("Contents/Helpers"))
        try app("ShareService", identifier: "net.shared.service", parent: b.appendingPathComponent("Contents/Helpers"))
        try file("Library/Caches/net.shared.service/data")
        try file("Library/Caches/org.sample.first/data")
        try file("Library/Preferences/net.shared.service.plist")
        try file("Library/Preferences/org.sample.first.plist")
        var installed = scanner.scanApplications().apps
        let first = try XCTUnwrap(installed.first { $0.url.lastPathComponent == a.lastPathComponent })
        let files = scanner.reviewedFiles(for: first, installed: scanner.fileOwners(of: installed))
        let shared = files.filter { $0.url.lastPathComponent.hasPrefix("net.shared.service") }
        XCTAssertEqual(shared.count, 2)
        XCTAssertTrue(shared.allSatisfy { $0.risk == .protected && !$0.defaultSelected })
        XCTAssertTrue(files.contains { $0.kind == .cache && $0.url.lastPathComponent == "org.sample.first" && $0.defaultSelected })
        let copy = try app("FirstCopy", identifier: first.bundleID, parent: root.appendingPathComponent("Opened"))
        let dropped = try XCTUnwrap(AppScanner(home: home, applicationRoots: [copy]).scanApplications().apps.first)
        installed.append(dropped)
        for target in [first, dropped] {
            let items = scanner.reviewedFiles(for: target, installed: scanner.fileOwners(of: installed))
            XCTAssertTrue(items.contains { $0.kind == .application && $0.defaultSelected })
            XCTAssertTrue(items.filter { $0.kind != .application }.allSatisfy { $0.risk == .protected && !$0.defaultSelected })
        }
    }

    func testWrappedExtensionKeepsItsIndependentDataOutOfLeftovers() throws {
        let outer = apps.appendingPathComponent("Wrapped.app")
        let inner = try app("Mobile", identifier: "org.sample.mobile", parent: outer.appendingPathComponent("Wrapper"))
        try FileManager.default.moveItem(at: inner.appendingPathComponent("Contents/Info.plist"), to: inner.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(at: outer.appendingPathComponent("WrappedBundle"), withDestinationURL: inner)
        let ext = inner.appendingPathComponent("PlugIns/Share.appex/Info.plist")
        try FileManager.default.createDirectory(at: ext.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "net.shared.mobile-extension"], format: .xml, options: 0).write(to: ext)
        try file("Library/Containers/net.shared.mobile-extension/documents")
        try file("Library/Preferences/net.shared.mobile-extension.plist")
        let installed = scanner.scanApplications().apps
        let mobile = try XCTUnwrap(installed.first)
        XCTAssertTrue(scanner.relatedIdentifiers(for: mobile).contains("net.shared.mobile-extension"))
        XCTAssertTrue(scanner.leftovers(installed: installed).isEmpty)
        XCTAssertTrue(scanner.relatedFiles(for: mobile).contains { $0.kind == .container && !$0.defaultSelected })
    }

    func testDeletedReviewKeepsOtherAppsDataAndReleasesItsOwn() throws {
        let a = try app("Old", identifier: "org.sample.old")
        let b = try app("New", identifier: "org.sample.other")
        for bundle in [a, b] {
            try app("Shared", identifier: "net.sample.shared", parent: bundle.appendingPathComponent("Contents/Helpers"))
        }
        try file("Library/Caches/org.sample.old/data")
        try file("Library/Preferences/net.sample.shared.plist")
        let installed = scanner.scanApplications().apps
        let owners = scanner.fileOwners(of: installed)
        let old = try XCTUnwrap(installed.first { $0.bundleID == "org.sample.old" })
        let moved = root.appendingPathComponent("TestTrash/Old.app")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old.url, to: moved)
        let deleted = AppRecord(url: moved, name: old.name, bundleID: old.bundleID, version: old.version)
        let reviewed = scanner.reviewedFiles(for: deleted, installed: owners, originalURL: old.url)
        XCTAssertTrue(reviewed.contains { $0.kind == .cache && $0.defaultSelected })
        XCTAssertTrue(reviewed.contains { $0.kind == .preference && $0.risk == .protected && !$0.defaultSelected })
    }

    func testOverlappingMappedAndNamedDirectoriesAreProtectedForEitherApp() throws {
        try app("Browser", identifier: "com.google.Chrome")
        try app("Google", identifier: "org.sample.folder-owner")
        try file("Library/Caches/Google/Chrome/index")
        let installed = scanner.scanApplications().apps
        let owners = scanner.fileOwners(of: installed)
        for record in installed {
            let reviewed = scanner.reviewedFiles(for: record, installed: owners)
            let cache = try XCTUnwrap(reviewed.first { $0.kind == .cache })
            XCTAssertEqual(cache.risk, .protected)
            XCTAssertFalse(cache.defaultSelected)
        }
    }

    func testWrappedApplicationSkipsLinkedPlugInDirectories() throws {
        let outer = apps.appendingPathComponent("Wrapped.app")
        let inner = try app("Mobile", identifier: "org.sample.mobile", parent: outer.appendingPathComponent("Wrapper"))
        try FileManager.default.createSymbolicLink(at: outer.appendingPathComponent("WrappedBundle"), withDestinationURL: inner)
        let elsewhere = root.appendingPathComponent("Unrelated")
        try app("Other", identifier: "net.sample.unrelated", parent: elsewhere)
        try FileManager.default.createSymbolicLink(at: inner.appendingPathComponent("PlugIns"), withDestinationURL: elsewhere)
        let installed = scanner.scanApplications().apps
        XCTAssertEqual(scanner.relatedIdentifiers(for: try XCTUnwrap(installed.first)), ["org.sample.mobile"])
    }

    func testScriptFoldersRequireExactIdentityAndManualReview() throws {
        let url = try app("ScriptsTest", identifier: "org.sample.notes")
        try app("Helper", identifier: "net.sample.notes-helper", parent: url.appendingPathComponent("Contents/Helpers"))
        let names = ["org.sample.notes", "net.sample.notes-helper", "org.sample.notesplus", "ScriptsTest",
                     "group.org.sample.notes", "ABCD123456.org.sample.notes", "com.apple.demo"]
        for name in names { try file("Library/Application Scripts/" + name + "/user-script") }
        let installed = scanner.scanApplications().apps
        let files = scanner.reviewedFiles(for: try XCTUnwrap(installed.first), installed: scanner.fileOwners(of: installed))
        let scripts = files.filter { $0.url.deletingLastPathComponent().lastPathComponent == "Application Scripts" }
        XCTAssertEqual(Set(scripts.map { $0.url.lastPathComponent }), ["org.sample.notes", "net.sample.notes-helper"])
        let main = try XCTUnwrap(scripts.first { $0.url.lastPathComponent == "org.sample.notes" })
        XCTAssertEqual(main.risk, .personal)
        XCTAssertEqual(main.ownerBundleID, main.url.lastPathComponent)
        XCTAssertFalse(main.defaultSelected)
        let helper = try XCTUnwrap(scripts.first { $0.url.lastPathComponent == "net.sample.notes-helper" })
        XCTAssertEqual(helper.risk, .protected)
        XCTAssertFalse(helper.defaultSelected)
        XCTAssertEqual(helper.ownerBundleID, main.ownerBundleID)
        let leftovers = scanner.leftovers(installed: [])
        XCTAssertEqual(Set(leftovers.map { $0.url.lastPathComponent }), Set(names.prefix(3)))
        XCTAssertTrue(leftovers.allSatisfy { !$0.defaultSelected && $0.risk == .personal && $0.ownerBundleID == $0.url.lastPathComponent })
        XCTAssertFalse(scanner.leftovers(installed: installed).contains { $0.url.lastPathComponent == "net.sample.notes-helper" })
    }

    func testWebAndHostResiduesUseOnlySupportedShapes() throws {
        let id = "org.sample.removed"
        let uuid = UUID().uuidString
        for folder in ["WebKit", "HTTPStorages"] {
            try file("Library/" + folder + "/" + id + "/data")
            try file("Library/" + folder + "/" + id + ".malformed")
        }
        for suffix in [".binarycookies", ".binarycookies.lock"] {
            try file("Library/HTTPStorages/" + id + suffix)
            try file("Library/Cookies/" + id + suffix)
        }
        try file("Library/Cookies/Cookies.binarycookies")
        try file("Library/Cookies/" + id + ".txt")
        try file("Library/Preferences/ByHost/" + id + "." + uuid + ".plist")
        try file("Library/Preferences/ByHost/" + id + ".fake.plist")
        let absent = scanner.leftovers(installed: [])
        XCTAssertEqual(absent.count, 7)
        XCTAssertTrue(absent.allSatisfy { $0.ownerBundleID == id && !$0.defaultSelected && $0.risk == .personal })
        try app("Installed", identifier: id)
        let installed = scanner.scanApplications().apps
        XCTAssertTrue(scanner.leftovers(installed: installed).isEmpty)
        let current = try XCTUnwrap(installed.first)
        XCTAssertTrue(Set(absent.map(\.id)).isSubset(of: Set(scanner.relatedFiles(for: current).map(\.id))))
    }

    func testChromiumChannelsSkipSiblingsAndVendorRoot() throws {
        try app("Google Chrome", identifier: "com.google.Chrome")
        for path in ["Application Support", "Caches"] {
            for channel in ["Chrome", "Chrome Beta", "Chrome Dev", "Chrome Canary", "Chrome Custom"] {
                try file("Library/" + path + "/Google/" + channel + "/Profile")
            }
        }
        let stableOnly = scanner.scanApplications().apps
        let remains = scanner.leftovers(installed: stableOnly)
        XCTAssertEqual(Set(remains.map { $0.url.lastPathComponent }), ["Chrome Beta", "Chrome Dev", "Chrome Canary"])
        XCTAssertEqual(remains.count, 6)
        XCTAssertTrue(remains.allSatisfy { !$0.defaultSelected })
        try app("Beta", identifier: "com.google.Chrome.beta")
        let installed = scanner.scanApplications().apps
        let beta = try XCTUnwrap(installed.first { $0.name == "Beta" })
        let files = scanner.relatedFiles(for: beta).filter { $0.kind != .application }
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.url.lastPathComponent == "Chrome Beta" })
        XCTAssertFalse(scanner.leftovers(installed: installed).contains { $0.url.lastPathComponent == "Chrome Beta" })
        try app("Google", identifier: "org.sample.vendor-alias")
        XCTAssertTrue(scanner.leftovers(installed: scanner.scanApplications().apps).isEmpty)
    }

    func testSpecialLocationsExcludeSymbolicLinksAndFilePretendingToBeScriptFolder() throws {
        let id = "org.sample.deleted"
        let target = try file("Documents/original/data").deletingLastPathComponent()
        let bases = ["WebKit", "Application Scripts", "Application Support/Google"]
        for base in bases {
            let url = home.appendingPathComponent("Library").appendingPathComponent(base)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url.appendingPathComponent(base.hasSuffix("Google") ? "Chrome Dev" : id), withDestinationURL: target)
        }
        try file("Library/Application Scripts/org.sample.regular")
        XCTAssertTrue(scanner.leftovers(installed: []).isEmpty)
    }

    func testSymbolicLinksAreNotScannedOrCounted() throws {
        try app("Example", identifier: "org.example.notes")
        let target = try file("Documents/valuable.txt", content: Data(repeating: 42, count: 100))
        let link = home.appendingPathComponent("Library/Caches/org.example.notes")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let files = scanner.relatedFiles(for: try XCTUnwrap(scanner.scanApplications().apps.first))
        XCTAssertFalse(files.contains { $0.url == link })
        XCTAssertEqual(AppScanner.size(of: link), 0)
    }
}

#if SCANNER_STANDALONE_TESTS
@main
struct ScannerTestRunner {
    static func main() throws {
        setbuf(stdout, nil)
        let tests: [(String, (ScannerTests) -> () throws -> Void)] = [
            ("完整标识匹配及个人数据保护", ScannerTests.testRelatedFilesUsesWholeIdentifierAndNeverSelectsUserData),
            ("名称关联和共享容器不默认选中", ScannerTests.testNameOnlyMatchAndSharedContainerNeedManualReview),
            ("系统应用保护", ScannerTests.testSystemAppAndItsFilesAreProtected),
            ("扫描位置区分读取、空目录、拒绝访问与链接", ScannerTests.testDirectoryReportDistinguishesDeniedMissingLinkedAndEmpty),
            ("仅将指向已消失应用的独立用户启动代理列为残留", ScannerTests.testOrphanedAgentRequiresMissingScopedApplicationAndNoInstalledOwner),
            ("辅助程序排除及关联", ScannerTests.testLeftoversExcludeHelpersAndSystemComponents),
            ("容器元数据匹配", ScannerTests.testContainerMetadataMatchesUUIDDirectory),
            ("设备偏好精确匹配", ScannerTests.testByHostOnlyRecognizesExactIdentifierAndUUID),
            ("重置保留其他应用辅助程序的设备偏好", ScannerTests.testHostPreferencesSharedWithInstalledHelperRemainProtected),
            ("浏览器固定映射不选厂商父目录", ScannerTests.testKnownBrowserDirectoriesNeverSelectVendorRoot),
            ("名称大小写兼容但不默认选择", ScannerTests.testCaseInsensitiveNameMatchRemainsManual),
            ("排除系统词库并保留真实扩展", ScannerTests.testExtensionsExcludeSystemLexiconsAndKeepUserPackages),
            ("苹果扩展标识保护", ScannerTests.testAppleExtensionIdentifiersAreProtected),
            ("包装应用识别及残留排除", ScannerTests.testWrappedApplicationsAreDiscoveredAndNotLeftovers),
            ("包装应用拒绝外部身份", ScannerTests.testWrappedApplicationCannotBorrowOutsideIdentity),
            ("单应用副本及共享辅助程序保护", ScannerTests.testSingleAppProtectsOtherCopiesAndSharedHelpers),
            ("包装应用内嵌扩展的残留排除与关联", ScannerTests.testWrappedExtensionKeepsItsIndependentDataOutOfLeftovers),
            ("签名声明发现异名共享组并保护跨应用成员", ScannerTests.testSignedGroupCanBeFoundWithoutOwnerInItsNameAndProtectsOtherMembers),
            ("拖入废纸篓后保留其他应用的共享数据", ScannerTests.testDeletedReviewKeepsOtherAppsDataAndReleasesItsOwn),
            ("固定目录和同名目录父子双向保护", ScannerTests.testOverlappingMappedAndNamedDirectoriesAreProtectedForEitherApp),
            ("包装应用忽略链接插件目录", ScannerTests.testWrappedApplicationSkipsLinkedPlugInDirectories),
            ("用户脚本目录精确归属及人工选择", ScannerTests.testScriptFoldersRequireExactIdentityAndManualReview),
            ("网页数据和设备偏好候选格式", ScannerTests.testWebAndHostResiduesUseOnlySupportedShapes),
            ("浏览器渠道专属目录及厂商父目录保护", ScannerTests.testChromiumChannelsSkipSiblingsAndVendorRoot),
            ("特殊目录拒绝符号链接和伪装文件", ScannerTests.testSpecialLocationsExcludeSymbolicLinksAndFilePretendingToBeScriptFolder),
            ("符号链接保护", ScannerTests.testSymbolicLinksAreNotScannedOrCounted)
        ]
        for (name, run) in tests {
            let test = ScannerTests()
            try test.setUpWithError()
            do { try run(test)(); try test.tearDownWithError() }
            catch { try? test.tearDownWithError(); throw error }
            print("通过：\(name)")
        }
        print("扫描核心测试：\(tests.count) 项通过，0 项失败")
    }
}
#endif
