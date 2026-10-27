import Foundation

/// Turns written replies into text a voice can say: Markdown and links out, times and dates in words,
/// abbreviations read naturally. English now; `SpeechLocale` is where other languages go.
public enum SpeechText {
    /// Everything: `clean` plus the spoken conversions.
    public static func speakable(_ text: String, now: Date = .now, timeZone: TimeZone = .current, locale: SpeechLocale = .english) -> String {
        var s = clean(text)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        for (pattern, replacement) in locale.before {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        s = spellISODateTimes(in: s, now: now, timeZone: timeZone, locale: locale)
        s = spellShortDates(in: s, locale: locale)
        s = spellTimes(in: s, locale: locale)
        for (pattern, replacement) in locale.abbreviations + locale.after {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes Markdown so the voice doesn't read symbols aloud.
    public static func clean(_ text: String) -> String {
        var s = text
        // [label](url) → label
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        // [[note-id]] → note id
        s = s.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        // List bullets and headings at the start of a line
        s = s.replacingOccurrences(of: #"(?m)^\s*([-*•]|#{1,6}|\d+\.)\s+"#, with: "", options: .regularExpression)
        // LaTeX leftovers such as $\rightarrow$
        s = s.replacingOccurrences(of: #"\$\\rightarrow\$|\\rightarrow|→"#, with: " to ", options: .regularExpression)
        for symbol in ["**", "__", "`", "*", "#", "$"] { s = s.replacingOccurrences(of: symbol, with: "") }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Times

    /// "02:00" → "two in the morning", "15:30" → "three thirty in the afternoon", "10:00 AM" → "ten in the morning".
    static func spellTimes(in text: String, locale: SpeechLocale) -> String {
        let pattern = #"\b(\d{1,2}):(\d{2})(?::\d{2})?\s*(AM|PM|a\.m\.|p\.m\.)?(?!\d)"#
        return replace(pattern, in: text) { groups in
            guard let hour = Int(groups[1] ?? ""), let minute = Int(groups[2] ?? ""), hour < 24, minute < 60 else { return nil }
            var hour24 = hour
            if let marker = groups[3]?.lowercased().replacingOccurrences(of: ".", with: "") {
                if marker == "pm", hour < 12 { hour24 += 12 }
                if marker == "am", hour == 12 { hour24 = 0 }
            }
            return locale.time(hour24, minute)
        }
    }

    // MARK: Dates

    /// ISO dates and date-times: "2026-10-23" → "Friday the 23rd", "2026-10-23T10:00" → "Friday the 23rd at ten in the morning".
    /// The month is said only when it is not the current one.
    static func spellISODateTimes(in text: String, now: Date, timeZone: TimeZone, locale: SpeechLocale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let pattern = #"\b(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::\d{2})?)?\b"#
        return replace(pattern, in: text) { groups in
            guard let year = Int(groups[1] ?? ""), let month = Int(groups[2] ?? ""), let day = Int(groups[3] ?? ""),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            let sameMonth = calendar.isDate(date, equalTo: now, toGranularity: .month)
            var spoken = locale.date(calendar.component(.weekday, from: date), day, sameMonth ? nil : month)
            if let h = groups[4].flatMap(Int.init), let m = groups[5].flatMap(Int.init) {
                spoken += " " + locale.at + " " + locale.time(h, m)
            }
            return spoken
        }
    }

    /// "Fri 23 Oct" / "Fri 23 Oct 2026" → "Friday the 23rd of October".
    static func spellShortDates(in text: String, locale: SpeechLocale) -> String {
        let pattern = #"\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,? (\d{1,2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*(?: \d{4})?\b"#
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return replace(pattern, in: text) { groups in
            guard let day = Int(groups[2] ?? ""), let weekday = weekdays.firstIndex(of: groups[1] ?? ""),
                  let month = months.firstIndex(of: groups[3] ?? "") else { return nil }
            return locale.date(weekday + 1, day, month + 1)
        }
    }

    // MARK: Regex helper

    /// Replaces each match with `make(groups)`; groups[0] is the whole match. nil keeps the original.
    private static func replace(_ pattern: String, in text: String, make: ([String?]) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let groups = (0..<match.numberOfRanges).map { i -> String? in
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += make(groups) ?? groups[0]!
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

/// Words for one language: English, Spanish and French.
public struct SpeechLocale: Sendable {
    public let at: String
    public let abbreviations: [(String, String)]
    let time: @Sendable (_ hour24: Int, _ minute: Int) -> String
    let date: @Sendable (_ weekday: Int, _ day: Int, _ month: Int?) -> String
    /// Rewrites before the conversions (French "14h30" → "14:30").
    var before: [(String, String)] = []
    /// Rewrites after them (Spanish "a las las diez" → "a las diez").
    var after: [(String, String)] = []

    init(at: String, abbreviations: [(String, String)], time: @escaping @Sendable (Int, Int) -> String,
         date: @escaping @Sendable (Int, Int, Int?) -> String, before: [(String, String)] = [], after: [(String, String)] = []) {
        self.at = at
        self.abbreviations = abbreviations
        self.time = time
        self.date = date
        self.before = before
        self.after = after
    }

    public static let english = SpeechLocale(
        at: "at",
        abbreviations: [
            (#"\be\.g\.,?"#, "for example,"),
            (#"\bi\.e\.,?"#, "that is,"),
            (#"\betc\."#, "and so on."),
            (#"\bvs\.?"#, "versus"),
            (#"\bapprox\."#, "about"),
            (#"\bUSD/mo\b"#, "dollars a month"),
            (#"\bUSD\b"#, "dollars"),
            (#"\bEUR/mo\b"#, "euros a month"),
            (#"\bEUR\b"#, "euros"),
            (#"/mo\b"#, " a month"),
            (#"\bmin\b"#, "minutes"),
            (#"\bhrs?\b"#, "hours"),
            (#"\bw/\s*"#, "with "),
        ],
        time: { hour24, minute in
            if hour24 == 0 && minute == 0 { return "midnight" }
            if hour24 == 12 && minute == 0 { return "noon" }
            let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
            let part: String
            switch hour24 {
            case 0..<12: part = "in the morning"
            case 12..<17: part = "in the afternoon"
            case 17..<21: part = "in the evening"
            default: part = "at night"
            }
            let h = EnglishNumbers.words(hour12)
            let m: String
            switch minute {
            case 0: m = ""
            case 1...9: m = " oh " + EnglishNumbers.words(minute)
            default: m = " " + EnglishNumbers.words(minute)
            }
            return "\(h)\(m) \(part)"
        },
        date: { weekday, day, month in
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
            var spoken = "\(names[(weekday - 1) % 7]) the \(EnglishNumbers.ordinal(day))"
            if let month { spoken += " of \(months[(month - 1) % 12])" }
            return spoken
        }
    )
}

enum EnglishNumbers {
    static let small = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty"]

    static func words(_ n: Int) -> String {
        if n < 20 { return small[n] }
        let t = tens[n / 10], u = n % 10
        return u == 0 ? t : "\(t)-\(small[u])"
    }

    static let ordinalSmall = ["zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth"]
    static let ordinalTens = ["", "", "twentieth", "thirtieth"]

    /// "first", "twenty-third", "thirty-first": the way a date is said.
    static func ordinal(_ n: Int) -> String {
        if n < 20 { return ordinalSmall[n] }
        let t = n / 10, u = n % 10
        return u == 0 ? ordinalTens[t] : "\(tens[t])-\(ordinalSmall[u])"
    }
}

extension SpeechLocale {
    /// The words for a language identifier ("es-419", "fr-FR"); English for anything else.
    public static func `for`(_ identifier: String) -> SpeechLocale {
        switch identifier.prefix(2).lowercased() {
        case "es": .spanish
        case "fr": .french
        default: .english
        }
    }

    /// "a las diez y media de la mañana", "el viernes veintitrés de octubre".
    public static let spanish = SpeechLocale(
        at: "a",
        abbreviations: [
            (#"\bp\.\s?ej\.,?"#, "por ejemplo,"),
            (#"\betc\."#, "etcétera."),
            (#"\baprox\."#, "aproximadamente"),
            (#"\bUSD\b"#, "dólares"),
            (#"\bEUR\b"#, "euros"),
            (#"\bmin\b"#, "minutos"),
            (#"\bhrs?\b"#, "horas"),
            (#"\bSr\."#, "señor"),
            (#"\bSra\."#, "señora"),
        ],
        time: { hour24, minute in
            if hour24 == 0 && minute == 0 { return "medianoche" }
            if hour24 == 12 && minute == 0 { return "mediodía" }
            let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
            let hour = hour12 == 1 ? "la una" : "las " + SpanishNumbers.words(hour12)
            let part: String
            switch hour24 {
            case 0..<6: part = "de la madrugada"
            case 6..<12: part = "de la mañana"
            case 12..<20: part = "de la tarde"
            default: part = "de la noche"
            }
            let m: String
            switch minute {
            case 0: m = ""
            case 15: m = " y cuarto"
            case 30: m = " y media"
            default: m = " y " + SpanishNumbers.words(minute)
            }
            return "\(hour)\(m) \(part)"
        },
        date: { weekday, day, month in
            let names = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
            let months = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
            var spoken = "el \(names[(weekday - 1) % 7]) \(day == 1 ? "primero" : SpanishNumbers.words(day))"
            if let month { spoken += " de \(months[(month - 1) % 12])" }
            return spoken
        },
        after: [(#"\b(las?) (las?) "#, "$2 "), (#"\bel el\b"#, "el")]
    )

    /// "à quatorze heures trente", "vendredi vingt-trois octobre".
    public static let french = SpeechLocale(
        at: "à",
        abbreviations: [
            (#"\bp\.\s?ex\.,?"#, "par exemple,"),
            (#"\betc\."#, "et cetera."),
            (#"\benv\."#, "environ"),
            (#"\bUSD\b"#, "dollars"),
            (#"\bEUR\b"#, "euros"),
            (#"\bmin\b"#, "minutes"),
            (#"\bM\."#, "monsieur"),
            (#"\bMme\b"#, "madame"),
        ],
        time: { hour24, minute in
            if hour24 == 0 && minute == 0 { return "minuit" }
            if hour24 == 12 && minute == 0 { return "midi" }
            let hour = hour24 == 1 ? "une heure" : FrenchNumbers.words(hour24).replacingOccurrences(of: #"\bun$"#, with: "une", options: .regularExpression) + " heures"
            return minute == 0 ? hour : "\(hour) \(FrenchNumbers.words(minute))"
        },
        date: { weekday, day, month in
            let names = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
            let months = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
            var spoken = "\(names[(weekday - 1) % 7]) \(day == 1 ? "premier" : FrenchNumbers.words(day))"
            if let month { spoken += " \(months[(month - 1) % 12])" }
            return spoken
        },
        before: [(#"\b([01]?\d|2[0-3])\s?h\s?([0-5]\d)\b"#, "$1:$2"), (#"\b([01]?\d|2[0-3])\s?h\b"#, "$1:00")],
        after: [(#"\ble (lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)\b"#, "$1")]
    )
}

enum SpanishNumbers {
    static let small = ["cero", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez", "once", "doce", "trece",
                        "catorce", "quince", "dieciséis", "diecisiete", "dieciocho", "diecinueve", "veinte", "veintiuno", "veintidós",
                        "veintitrés", "veinticuatro", "veinticinco", "veintiséis", "veintisiete", "veintiocho", "veintinueve"]
    static let tens = ["", "", "", "treinta", "cuarenta", "cincuenta"]

    /// 0–59, as said in times and dates.
    static func words(_ n: Int) -> String {
        if n < 30 { return small[n] }
        let u = n % 10
        return u == 0 ? tens[n / 10] : "\(tens[n / 10]) y \(small[u])"
    }
}

enum FrenchNumbers {
    static let small = ["zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix", "onze", "douze", "treize",
                        "quatorze", "quinze", "seize", "dix-sept", "dix-huit", "dix-neuf"]
    static let tens = ["", "", "vingt", "trente", "quarante", "cinquante"]

    /// 0–59, as said in times and dates.
    static func words(_ n: Int) -> String {
        if n < 20 { return small[n] }
        let t = tens[n / 10], u = n % 10
        switch u {
        case 0: return t
        case 1: return "\(t) et un"
        default: return "\(t)-\(small[u])"
        }
    }
}
