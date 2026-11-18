import Foundation

/// Looks up a single native Mac product only after the user chooses a storefront.
public enum StoreUpdateService {
    static func normalizedRegion(_ input: String) -> String? {
        let region = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard region.utf8.count == 2, Locale.Region.isoRegions.contains(Locale.Region(region)) else { return nil }
        return region
    }

    public static func supports(region: String) -> Bool { normalizedRegion(region) != nil }

    static func requestURL(for app: AppRecord, region: String) throws -> URL {
        guard app.hasStoreReceipt, let country = normalizedRegion(region),
              app.bundleID.utf8.count <= 255,
              app.bundleID.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            throw ManagementError.message("请核对应用的商店来源、标识和商店地区。")
        }
        var components = URLComponents()
        components.scheme = "https"; components.host = "itunes.apple.com"; components.path = "/lookup"
        components.queryItems = [URLQueryItem(name: "bundleId", value: app.bundleID), URLQueryItem(name: "entity", value: "macSoftware"), URLQueryItem(name: "country", value: country.lowercased())]
        guard let url = components.url else { throw ManagementError.message("无法创建商店查询。") }
        return url
    }

    private struct Response: Decodable {
        struct Product: Decodable {
            let kind: String?, bundleId: String?, trackId: Int64?, version: String?, minimumOsVersion: String?
        }
        let results: [Product]
    }

    private static func isNumericVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil
    }

    static func result(data: Data, for app: AppRecord, region: String, systemVersion: String) throws -> UpdateInfo {
        guard let country = normalizedRegion(region) else { throw ManagementError.message("商店地区无效。") }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let matches = response.results.filter { $0.kind == "mac-software" && $0.bundleId == app.bundleID }
        guard matches.count == 1, let product = matches.first, let id = product.trackId, id > 0,
              let latest = product.version, isNumericVersion(latest) else {
            throw ManagementError.message("\(country) 区商店未返回可核对的同标识电脑应用。")
        }
        let link = URL(string: "https://apps.apple.com/\(country.lowercased())/app/id\(id)")
        guard isNumericVersion(app.version) else { throw ManagementError.message("本机版本无法与 \(country) 区商店的 \(latest) 直接比较。") }
        let newer = UpdateService.compareVersions(latest, app.version) == .orderedDescending
        if newer, let minimum = product.minimumOsVersion, isNumericVersion(minimum),
           UpdateService.compareVersions(minimum, systemVersion) == .orderedDescending {
            return UpdateInfo(appID: app.id, status: .failed, latestVersion: latest, url: link, message: "\(country) 区商店的 \(latest) 至少需要系统 \(minimum)。可在商品页查看安装条件。")
        }
        let message = newer ? "\(country) 区商店列出 \(latest)，可在商品页核对并更新。" : "\(country) 区商店版本为 \(latest)，未发现更高版本。"
        return UpdateInfo(appID: app.id, status: newer ? .available : .upToDate, latestVersion: latest, url: link, message: message)
    }

    public static func check(app: AppRecord, region: String) async -> UpdateInfo {
        do {
            let url = try requestURL(for: app, region: region)
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
            let session = URLSession(configuration: config, delegate: StoreRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(from: url)
            let limit = 1_048_576
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.expectedContentLength <= limit else { throw ManagementError.message("苹果商店未返回有效清单，请稍后重试。") }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw ManagementError.message("商店清单超过读取上限。") }
                data.append(byte)
            }
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return try result(data: data, for: app, region: region, systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        } catch {
            return UpdateInfo(appID: app.id, status: .failed, latestVersion: nil, url: nil, message: "商店检查未完成。" + error.localizedDescription)
        }
    }
}

private final class StoreRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
