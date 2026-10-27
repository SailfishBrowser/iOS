import AVFAudio

enum AudioSession {
    // Playback lets page media sound with the ringer silenced and keep going in the background or in Picture in
    // Picture. The session stays inactive here: WebKit activates it only when a page plays, so a quiet page never
    // holds the app awake.
    static func configure() {
        try! AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }
}
