import AppKit
import ApplicationServices
import CleanCore

/// Only the browser's own extension detail button is pressed. The native confirmation stays with the user.
enum BrowserRemovalAction {
    static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    static func openConfirmation(_ row: BrowserExtensionRecord, application: URL) async throws -> Bool {
        guard row.removal == .browserConfirmation, row.browser != .firefox,
              row.identifier.range(of: #"\A[a-p]{32}\z"#, options: .regularExpression) != nil,
              row.profile == "Default" || row.profile.range(of: #"\AProfile [0-9]+\z"#, options: .regularExpression) != nil,
              Bundle(url: application)?.bundleIdentifier == row.browser.bundleID else {
            throw CocoaError(.featureUnsupported)
        }
        let nonce = UUID().uuidString
        // The unique document URL binds the accessibility action to this specific navigation.
        let target = row.detailAddress + "#qingzhou-" + nonce
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--profile-directory=" + row.profile, "--new-window", target]
        _ = try await NSWorkspace.shared.openApplication(at: application, configuration: config)
        guard AXIsProcessTrusted() else { return false }
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline {
            try Task.checkCancellation()
            let browsers = NSRunningApplication.runningApplications(withBundleIdentifier: row.browser.bundleID)
            for browser in browsers where browser.bundleURL?.standardizedFileURL.path == application.standardizedFileURL.path {
                let pid = browser.processIdentifier
                if await Task.detached(priority: .userInitiated, operation: {
                    pressRemoval(in: pid, target: target)
                }).value { return true }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    static func pressRemoval(in pid: pid_t, target: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        // Chromium enables its accessibility tree on request from an accessibility client.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        func elements(_ root: AXUIElement, where test: (AXUIElement) -> Bool) -> [AXUIElement] {
            var queue = [root], matches = [AXUIElement](), index = 0
            while index < queue.count, index < 500 {
                let item = queue[index]; index += 1
                if test(item) { matches.append(item); continue }
                let children = attribute(item, "AXChildren") as? [AXUIElement] ?? []
                queue.append(contentsOf: children.prefix(500 - min(queue.count, 500)))
            }
            return matches
        }
        guard let focused = attribute(app, "AXFocusedWindow"), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let window = unsafeBitCast(focused, to: AXUIElement.self)
        func targetDocument(_ element: AXUIElement) -> Bool {
            guard attribute(element, "AXRole") as? String == "AXWebArea" else { return false }
            let url = attribute(element, "AXURL")
            return (url as? URL)?.absoluteString == target || url as? String == target
        }
        let docs = elements(window, where: targetDocument)
        guard docs.count == 1 else { return false }
        let buttons = elements(docs[0]) { element in
            guard attribute(element, "AXRole") as? String == "AXButton" else { return false }
            let id = attribute(element, "AXDOMIdentifier") as? String
            if id == "remove-extension" { return true }
            let titles = ["Remove extension", "Remove Extension", "移除扩展程序", "移除扩展", "删除扩展", "移除擴充功能", "移除延伸模組"]
            return ["AXTitle", "AXDescription"].contains { key in
                (attribute(element, key) as? String).map(titles.contains) == true
            }
        }
        guard buttons.count == 1, targetDocument(docs[0]), attribute(buttons[0], "AXEnabled") as? Bool != false else { return false }
        return AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success
    }
}
