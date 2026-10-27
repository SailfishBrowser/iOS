import Foundation
import Testing
@testable import SailBrowser

struct TrackingParamsTests {
    private func strip(_ string: String) -> String {
        TrackingParams.strip(URL(string: string)!).absoluteString
    }

    @Test func stripKeepsNonTrackingParamsInOrder() {
        #expect(
            strip("https://a.com/p?z=1&utm_source=x&b=a%20b&fbclid=f&gclid=g&a=2&dclid=d&msclkid=m&mc_eid=e&igsh=i&igshid=j&UTM_Medium=y#frag")
                == "https://a.com/p?z=1&b=a%20b&a=2#frag")
    }

    @Test func dropsEmptyQueryAndLeavesCleanURLsAlone() {
        #expect(strip("https://a.com/p?utm_campaign=x&fbclid=y#top") == "https://a.com/p#top")
        #expect(strip("https://a.com/p?x=1") == "https://a.com/p?x=1")
        #expect(strip("https://a.com/p") == "https://a.com/p")
    }

    @Test func stripsSiOnlyOnYouTube() {
        #expect(strip("https://youtu.be/abc?si=123&t=4") == "https://youtu.be/abc?t=4")
        #expect(strip("https://www.youtube.com/watch?v=abc&si=123") == "https://www.youtube.com/watch?v=abc")
        #expect(strip("https://example.com/?si=123") == "https://example.com/?si=123")
        #expect(strip("https://notyoutube.com/?si=123") == "https://notyoutube.com/?si=123")
    }
}
