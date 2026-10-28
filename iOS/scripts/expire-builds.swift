// Expires every TestFlight build of <bundle id> but the newest <keep> (default 1) that are not expired already, so
// testers can only install the current build. A build still processing is not listed yet and so never counted.
// Usage: swift scripts/expire-builds.swift <bundle id> [<keep>], with ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH set.
import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleID = CommandLine.arguments[1]
let keep = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1

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
    FileHandle.standardError.write(Data("expire-builds.swift: \(message)\n".utf8))
    exit(1)
}

func send(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> [String: Any] {
    var url = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/\(path)")!
    if !query.isEmpty { url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
    var request = URLRequest(url: url.url!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (200..<300).contains((response as! HTTPURLResponse).statusCode) else {
        FileHandle.standardError.write(data)
        fail("\(method) \(path) failed")
    }
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

let apps = try await send("GET", "apps", query: ["filter[bundleId]": bundleID, "fields[apps]": "bundleId"])["data"] as! [[String: Any]]
guard let app = apps.first(where: { ($0["attributes"] as! [String: Any])["bundleId"] as? String == bundleID }) else {
    fail("no app with bundle id \(bundleID) in App Store Connect")
}
let builds = try await send("GET", "builds", query: [
    "filter[app]": app["id"] as! String, "filter[expired]": "false", "sort": "-uploadedDate", "limit": "200",
    "fields[builds]": "version,uploadedDate,expired",
])["data"] as! [[String: Any]]
let ordered = builds.sorted {
    Int(($0["attributes"] as! [String: Any])["version"] as! String)! > Int(($1["attributes"] as! [String: Any])["version"] as! String)!
}
for build in ordered.dropFirst(keep) {
    let id = build["id"] as! String
    let version = (build["attributes"] as! [String: Any])["version"] as! String
    _ = try await send("PATCH", "builds/\(id)", body: ["data": ["type": "builds", "id": id, "attributes": ["expired": true]]])
    print("expired build \(version)")
}
print("kept \(ordered.prefix(keep).map { ($0["attributes"] as! [String: Any])["version"] as! String }.joined(separator: ", "))")
