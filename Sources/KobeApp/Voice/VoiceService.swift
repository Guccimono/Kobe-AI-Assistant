@preconcurrency import AVFoundation
import Observation
import KobeKit

/// Reads Kobe's replies aloud when Voice is on: Kokoro on this Mac for English, Spanish and French, the best
/// installed macOS voice otherwise (or when Kokoro isn't available). Replies are cleaned for speech (no Markdown,
/// times said the way people say them) and spoken sentence by sentence so the voice starts right away.
@MainActor
@Observable
final class VoiceService {
    enum Status: Equatable {
        case off
        case starting
        case kokoro
        case system(reason: String)
    }

    private(set) var status: Status = .off
    private(set) var voices: [String] = []

    @ObservationIgnored private let kokoro = KokoroSpeaker()
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    /// Starts Kokoro's helper (the model loads on the first sentence). Safe to call again.
    func prepare() async {
        guard status != .kokoro, status != .starting else { return }
        guard KokoroSpeaker.isInstalled else {
            status = .system(reason: "Kokoro isn't set up on this Mac (scripts/setup-kokoro.sh), so the macOS voice speaks.")
            return
        }
        status = .starting
        await kokoro.start()
        if kokoro.isUsable {
            voices = kokoro.voices
            status = .kokoro
        } else {
            let detail = if case .failed(let message) = kokoro.status { message } else { "Kokoro didn't start." }
            status = .system(reason: detail + " The macOS voice speaks instead.")
        }
    }

    private var isKokoro: Bool { status == .kokoro }

    func speak(_ reply: String, settings: AppSettings) {
        stop()
        let language = SpeechChunks.language(of: reply)
        let text = SpeechText.speakable(reply, locale: .for(language))
        let sentences = SpeechChunks.split(text)
        guard !sentences.isEmpty else { return }
        if isKokoro, KokoroSpeaker.voice(for: language, english: settings.voiceName) != nil {
            kokoro.language = language
            kokoro.voice = settings.voiceName
            kokoro.speed = settings.voiceSpeed
            sentences.forEach(kokoro.speak)
        } else {
            for sentence in sentences {
                let utterance = AVSpeechUtterance(string: sentence)
                utterance.voice = Self.bestSystemVoice(for: language)
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(settings.voiceSpeed)
                synthesizer.speak(utterance)
            }
        }
    }

    func stop() {
        kokoro.stop()
        synthesizer.stopSpeaking(at: .immediate)
    }

    func shutdown() {
        stop()
        kokoro.shutdown()
        status = .off
    }

    /// Premium first, then Enhanced, then any voice for the language.
    static func bestSystemVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let matching = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        return matching.first { $0.quality == .premium } ?? matching.first { $0.quality == .enhanced } ?? matching.first
            ?? AVSpeechSynthesisVoice(language: language)
    }
}
