import AVFAudio
import Foundation
import Testing
@testable import SailBrowser

@Suite(.serialized)
struct AudioSessionTests {
    @Test func launchSetsThePlaybackCategoryWithoutPlayingAnything() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.soloAmbient)
        makeEnvironment().launch()
        #expect(session.category == .playback)
        #expect(session.mode == .default)
        #expect(session.categoryOptions.isEmpty)
    }

    @Test func theAppDeclaresTheBackgroundAudioMode() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] == ["audio"])
    }

    @Test func pagesMayEnterPictureInPicture() {
        #expect(makeEnvironment().pool.configuration.allowsPictureInPictureMediaPlayback)
    }
}
