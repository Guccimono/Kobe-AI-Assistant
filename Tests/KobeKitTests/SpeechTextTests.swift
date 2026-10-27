import Foundation
import Testing
@testable import KobeKit


struct SpeechTextTests {
    let mexico = TimeZone(identifier: "America/Mexico_City")!
    // Sat 17 Oct 2026 in Mexico City.
    let now = ISO8601DateFormatter().date(from: "2026-10-17T18:00:00Z")!

    private func say(_ text: String) -> String { SpeechText.speakable(text, now: now, timeZone: mexico) }

    @Test func stripsMarkdown() {
        #expect(SpeechText.clean("**Free**: 0 EUR") == "Free: 0 EUR")
        #expect(SpeechText.clean("- one\n- two") == "one two")
        #expect(SpeechText.clean("## Tiers") == "Tiers")
        #expect(SpeechText.clean("See [the note](https://x.y) and [[tiers]]") == "See the note and tiers")
        #expect(SpeechText.clean("Run `git status`") == "Run git status")
        #expect(SpeechText.clean("1. First") == "First")
        #expect(SpeechText.clean("1.0 $\\rightarrow$ 2.0") == "1.0 to 2.0")
    }

    @Test func times() {
        #expect(say("at 02:00") == "at two in the morning")
        #expect(say("at 15:30") == "at three thirty in the afternoon")
        #expect(say("at 00:00") == "at midnight")
        #expect(say("at 12:00") == "at noon")
        #expect(say("at 12:30") == "at twelve thirty in the afternoon")
    }
}

struct MultiLanguageSpeechTests {
    @Test func spanishAndFrenchTimesAndDates() {
        #expect(SpeechText.speakable("Nos vemos a las 10:30.", locale: .spanish) == "Nos vemos a las diez y media de la mañana.")
        #expect(SpeechText.speakable("Es a la 13:00.", locale: .spanish) == "Es a la una de la tarde.")
        #expect(SpeechText.speakable("Rendez-vous à 14h30.", locale: .french) == "Rendez-vous à quatorze heures trente.")
        #expect(SpeechLocale.spanish.time(13, 0) == "la una de la tarde")
    }
}

@Test func repliesAreSpokenSentenceBySentence() {
    #expect(SpeechChunks.split("Hello there. How are you? I'm fine!") == ["Hello there.", "How are you?", "I'm fine!"])
    #expect(SpeechChunks.split("Version 1.5 is out. Great.") == ["Version 1.5 is out.", "Great."])
    #expect(SpeechChunks.split("   ") == [])
}

@Test func veryLongSentencesAreCutAtACommaOrSpace() {
    let long = Array(repeating: "word", count: 120).joined(separator: " ")
    #expect(SpeechChunks.split(long).allSatisfy { $0.count <= SpeechChunks.maxLength })
}

@Test func languageOfAReply() {
    #expect(SpeechChunks.language(of: "Hola Sam, ¿cómo estás hoy? Todo bien por aquí.") == "es")
    #expect(SpeechChunks.language(of: "Bonjour Sam, comment vas-tu aujourd'hui ? Tout va bien.") == "fr")
    #expect(SpeechChunks.language(of: "Hello Sam, how are you today? All good here.") == "en")
}
