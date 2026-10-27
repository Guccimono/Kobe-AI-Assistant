import Foundation
import NaturalLanguage

/// How a reply becomes speech: cut into sentences so the voice starts after the first one, and the reply's language
/// picked so Spanish and French get Kokoro's own voices.
public enum SpeechChunks {
    /// Kokoro handles short inputs best; longer sentences are cut at a comma, else at a space.
    public static let maxLength = 300

    public static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .localized]) { substring, _, _, _ in
            let sentence = (substring ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences.flatMap(cut)
    }

    /// "en", "es", "fr", or another ISO code; "en" when unsure.
    public static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    private static func cut(_ sentence: String) -> [String] {
        guard sentence.count > maxLength else { return [sentence] }
        var pieces: [String] = []
        var rest = Substring(sentence)
        while rest.count > maxLength {
            let window = rest.prefix(maxLength)
            let at = window.lastIndex(of: ",").map { rest.index(after: $0) } ?? window.lastIndex(of: " ") ?? window.endIndex
            pieces.append(String(rest[rest.startIndex..<at]).trimmingCharacters(in: .whitespaces))
            rest = rest[at...].drop { $0 == " " }
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces.filter { !$0.isEmpty }
    }
}
