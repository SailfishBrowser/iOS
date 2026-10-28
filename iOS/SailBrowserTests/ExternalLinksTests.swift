import Foundation
import Testing
@testable import SailBrowser

struct ExternalLinksTests {
    @Test(arguments: [
        ("tel:+15551234567", ExternalLinks.Kind.external),
        ("mailto:a@b.test", .external),
        ("sms:+15551234567", .external),
        ("facetime:a@b.test", .external),
        ("maps://?q=cafe", .external),
        ("itms-apps://apps.apple.com/app/id1", .external),
        ("https://apps.apple.com/us/app/id6472513080", .external),
        ("https://itunes.apple.com/app/id1", .external),
        ("https://example.test/", .web),
        ("http://example.test/", .web),
        ("HTTPS://Example.test/", .web),
        ("about:blank", .page),
        ("javascript:void(0)", .page),
        ("blob:https://example.test/1", .page),
        ("data:text/html,a", .page),
        ("file:///tmp/a.html", .page),
    ])
    func classifies(_ link: String, _ kind: ExternalLinks.Kind) {
        #expect(ExternalLinks.kind(of: URL(string: link)!) == kind)
    }
}
