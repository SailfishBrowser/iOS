import Foundation
import Testing
@testable import SailBrowser

struct TrackerDomainsTests {
    @Test func aHostMatchesItsOwnOrAParentDomainOnly() throws {
        let domains = try trackerDomains(["doubleclick.net", "127.0.0.1"])
        #expect(domains.contains(host: "doubleclick.net"))
        #expect(domains.contains(host: "stats.g.doubleclick.net"))
        #expect(!domains.contains(host: "notdoubleclick.net"))
        #expect(!domains.contains(host: "net"))
        #expect(domains.contains(host: "127.0.0.1"))
    }

    // A leading dot marks a rule that blocks the domain's subdomains only, as EasyPrivacy's .google-analytics.com/ does.
    @Test func aSubdomainOnlyEntryMatchesProperSubdomainsOnly() throws {
        let domains = try trackerDomains([".google-analytics.com"])
        #expect(domains.contains(host: "www.google-analytics.com"))
        #expect(domains.contains(host: "a.ssl.google-analytics.com"))
        #expect(!domains.contains(host: "google-analytics.com"))
        #expect(!domains.contains(host: "notgoogle-analytics.com"))
        #expect(!domains.contains(host: "com"))
    }

    // The set holds unconditional domain blocks only: hostslick.com is blocked only on some sites (if-domain), and
    // adtraction.com has an exception rule.
    @Test func theBundledSetHoldsOnlyDomainsTheListsAlwaysBlock() throws {
        let domains = try TrackerDomains(contentsOf: #require(Bundle.main.url(forResource: "tracker-domains", withExtension: "txt")))
        #expect(domains.contains(host: "www.googletagmanager.com"))
        #expect(!domains.contains(host: "hostslick.com"))
        #expect(!domains.contains(host: "adtraction.com"))
        #expect(domains.contains(host: "www.google-analytics.com"))
        #expect(domains.contains(host: "ssl.google-analytics.com"))
        #expect(!domains.contains(host: "google-analytics.com"))
    }
}

func trackerDomains(_ lines: [String]) throws -> TrackerDomains {
    let url = FileManager.default.temporaryDirectory.appending(path: "domains-\(UUID().uuidString).txt")
    try lines.map { "\($0)\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
    return try TrackerDomains(contentsOf: url)
}
