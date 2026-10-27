// Prints the next build number for <bundle id>: one more than the highest build App Store Connect has for the app, and
// no lower than the current UTC time as yyyyMMddHHmm, the number archive.sh gives local builds. A build still
// processing may not be listed yet; the time floor keeps the next run above it.
// Usage: swift scripts/next-build.swift <bundle id>, with ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH set.
import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleID = CommandLine.arguments[1]

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: env["ASC_KEY_PATH"]!, encoding: .utf8))
let now = Int(Date().timeIntervalSince1970)
let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": env["ASC_KEY_ID"]!, "typ": "JWT"])
let claims = try JSONSerialization.data(withJSONObject: [
    "iss": env["ASC_ISSUER_ID"]!, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1",
])
let unsigned = base64URL(header) + "." + base64URL(claims)
let token = unsigned + "." + base64URL(try key.signature(for: Data(unsigned.utf8)).rawRepresentation)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("next-build.swift: \(message)\n".utf8))
    exit(1)
}

func get(_ path: String, _ query: [String: String]) async throws -> [[String: Any]] {
    var url = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/\(path)")!
    url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    var request = URLRequest(url: url.url!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as! HTTPURLResponse).statusCode == 200 else {
        FileHandle.standardError.write(data)
        fail("GET \(path) failed")
    }
    return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["data"] as! [[String: Any]]
}

let apps = try await get("apps", ["filter[bundleId]": bundleID, "fields[apps]": "bundleId"])
guard let app = apps.first(where: { ($0["attributes"] as! [String: Any])["bundleId"] as? String == bundleID }) else {
    fail("no app with bundle id \(bundleID) in App Store Connect")
}
let builds = try await get("builds", [
    "filter[app]": app["id"] as! String, "sort": "-uploadedDate", "limit": "200", "fields[builds]": "version",
])
let latest = builds.compactMap { Int(($0["attributes"] as! [String: Any])["version"] as! String) }.max() ?? 0
let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.timeZone = TimeZone(identifier: "UTC")
formatter.dateFormat = "yyyyMMddHHmm"
print(max(latest + 1, Int(formatter.string(from: Date()))!))
