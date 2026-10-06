import AVFoundation
import Foundation

/// `AVAudioSession` configuration for voice-prompt playback on CarPlay.
///
/// MapMapKit ships no TTS of its own — apps synthesise
/// ``SpokenPrompt/text``/``SpokenPrompt/ssml`` themselves (typically with
/// `AVSpeechSynthesizer`), same as on the phone. What CarPlay adds is a
/// specific audio-session recipe so prompts duck the car's current audio
/// source (music, phone calls) instead of fighting with it or going
/// silent: category `.playback`, mode `.voicePrompt`, options
/// `[.duckOthers, .interruptSpokenAudioAndMixWithOthers]` — the
/// combination settled on by mapbox-navigation-ios (#1864/#1933) after
/// exactly this category/mode/options set produced the fewest "no audio
/// on CarPlay" and "prompt cut off other audio entirely" reports.
public enum CarPlayAudioSession {

    /// Configure the shared `AVAudioSession` for CarPlay voice prompts.
    /// Call once when navigation starts (or when your CarPlay scene
    /// connects, if you want to be ready before the first prompt) and
    /// again if you've deactivated the session in between (e.g. after a
    /// phone call interruption).
    ///
    /// - Throws: whatever `AVAudioSession.setCategory`/`setActive` throw
    ///   (e.g. another app holding an incompatible session category).
    public static func configureForVoicePrompts() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .voicePrompt,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Deactivate the session, e.g. when navigation ends. Notifies other
    /// apps so they can resume ducked audio.
    public static func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
