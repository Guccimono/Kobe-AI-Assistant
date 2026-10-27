import Foundation

// WhatsApp in the notch: what Kobe keeps of the conversations, in memory only, and the
// rules that decide what reaches the pill. Pure Foundation, so the parsing and the rules are tested without the
// app (Tests/KobeKitTests/WhatsApp*Tests.swift). Nothing here is ever written to disk or to a log.

/// What a message holds besides text: only a label is shown, the media itself is never fetched.
public enum WAMedia: Equatable, Sendable {
    case none
    case image
    case video
    case audio(seconds: Int?)
    case voice(seconds: Int?)
    case document(name: String?)
    case sticker
    case location
    case contact
    case other
}

public struct WAMessage: Identifiable, Equatable, Sendable {
    public var id: String
    /// The conversation: a person (…@s.whatsapp.net, …@lid, …@c.us) or a group (…@g.us).
    public var chat: String
    /// Who wrote it (in a group, the member; in a private chat, the chat itself).
    public var sender: String
    public var senderName: String
    public var text: String
    public var media: WAMedia
    public var date: Date
    public var fromMe: Bool
    /// The message mentions this account (only meaningful in groups).
    public var mentionsMe: Bool
    /// Set by the gateway when the chat name came with the message.
    public var chatName: String?

    public init(id: String, chat: String, sender: String, senderName: String, text: String, media: WAMedia = .none,
                date: Date, fromMe: Bool = false, mentionsMe: Bool = false, chatName: String? = nil) {
        self.id = id
        self.chat = chat
        self.sender = sender
        self.senderName = senderName
        self.text = text
        self.media = media
        self.date = date
        self.fromMe = fromMe
        self.mentionsMe = mentionsMe
        self.chatName = chatName
    }
}

extension WAMessage {
    /// One line for the pill: the text, else the media's label (its English text; empty for plain text).
    public var preview: (label: String, value: String) {
        switch media {
        case .none: return ("", text)
        case .image: return (WAText.mediaPhoto, text)
        case .video: return (WAText.mediaVideo, text)
        case .audio(let s), .voice(let s): return (WAText.mediaVoice, s.map(WAJID.duration) ?? "")
        case .document(let name): return (WAText.mediaDocument, name ?? text)
        case .sticker: return (WAText.mediaSticker, "")
        case .location: return (WAText.mediaLocation, "")
        case .contact: return (WAText.mediaContact, "")
        case .other: return (WAText.mediaOther, text)
        }
    }
}

public struct WAConversation: Identifiable, Equatable, Sendable {
    public var id: String   // the chat JID
    public var name: String
    public var isGroup: Bool
    /// Newest last, the last `WAInbox.keep` only.
    public var messages: [WAMessage]
    public var unread: Int
    public var lastActivity: Date

    public init(id: String, name: String, isGroup: Bool, messages: [WAMessage] = [], unread: Int = 0, lastActivity: Date) {
        self.id = id
        self.name = name
        self.isGroup = isGroup
        self.messages = messages
        self.unread = unread
        self.lastActivity = lastActivity
    }
}

/// What the user chose in Settings › WhatsApp.
public struct WAFilters: Equatable, Sendable {
    /// Groups stay quiet unless the message mentions you.
    public var muteGroups: Bool
    /// Chats never shown (JIDs).
    public var ignored: Set<String>

    public init(muteGroups: Bool = true, ignored: Set<String> = []) {
        self.muteGroups = muteGroups
        self.ignored = ignored
    }
}

public enum WAJID {
    public static func isGroup(_ jid: String) -> Bool { jid.hasSuffix("@g.us") }

    /// Stories (status@broadcast), broadcast lists and channels (…@newsletter): never a chat to read or answer.
    public static func isBroadcast(_ jid: String) -> Bool {
        jid.hasSuffix("@broadcast") || jid.hasSuffix("@newsletter")
    }

    /// "33612345678@s.whatsapp.net" → "+33612345678": the digits with a plus.
    public static func displayNumber(_ jid: String) -> String {
        let user = jid.split(separator: "@").first.map(String.init) ?? jid
        let digits = user.split(separator: ":").first.map(String.init) ?? user
        return digits.allSatisfy(\.isNumber) && !digits.isEmpty ? "+" + digits : digits
    }

    /// The number with its middle hidden, for the conversation header and the "Sent as" footer:
    /// "15550100142@s.whatsapp.net" → "+15 5 ·· ·· 01 42". nil for a group or an id too short to be a number.
    public static func masked(_ jid: String) -> String? {
        guard !isGroup(jid) else { return nil }
        let d = Array(digits(jid))
        guard d.count >= 8 else { return nil }
        let s = { (r: Range<Int>) in String(d[r]) }
        return "+\(s(0..<2)) \(s(2..<3)) ·· ·· \(s(d.count - 4..<d.count - 2)) \(s(d.count - 2..<d.count))"
    }

    /// Two letters for the avatar: "Marie Dupont" → "MD", "+33 6…" → "#".
    public static func initials(_ name: String) -> String {
        let words = name.split { $0 == " " || $0 == "-" }.filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "#" : letters.joined()
    }

    /// 12 → "0:12", 75 → "1:15".
    public static func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    /// The same person under its several forms: "33612345678:12@s.whatsapp.net" and "33612345678@c.us" are one chat.
    public static func normalized(_ jid: String) -> String {
        let parts = jid.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return jid }
        let user = parts[0].split(separator: ":").first.map(String.init) ?? parts[0]
        let server = parts[1] == "c.us" ? "s.whatsapp.net" : parts[1]
        return "\(user)@\(server)"
    }

    /// The user part's digits: "33612345678:3@s.whatsapp.net" → "33612345678".
    public static func digits(_ jid: String) -> String {
        let user = jid.split(separator: "@").first.map(String.init) ?? jid
        let base = user.split(separator: ":").first.map(String.init) ?? user
        return base.filter(\.isNumber)
    }

    /// Two ids of the same person, whatever their server part (@c.us, @s.whatsapp.net, a bare number).
    public static func sameUser(_ a: String, _ b: String) -> Bool {
        let x = digits(a), y = digits(b)
        return !x.isEmpty && x == y
    }

    /// What Settings' "Add" turns an entry into: a phone number ("+33 6 12…") or a full chat id ("…@g.us").
    /// nil when there is nothing to ignore.
    public static func ignoreEntry(_ raw: String) -> String? {
        let raw = raw.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let chat = raw.contains("@") ? raw : raw.filter(\.isNumber) + "@s.whatsapp.net"
        guard chat.count > "@s.whatsapp.net".count else { return nil }
        return WAJID.normalized(chat)
    }
}

/// The conversations, grouped by chat: one entry per conversation, never one per message.
public struct WAInbox: Equatable, Sendable {
    /// Messages kept per conversation: a week of a busy chat, so an old message can still be read and answered.
    public static let keep = 200

    public private(set) var conversations: [String: WAConversation] = [:]
    private var seenIds: Set<String> = []
    /// The same ids in arrival order, so the oldest are the ones forgotten.
    private var seenOrder: [String] = []

    public init() {}

    /// How many message ids are remembered for de-duplication (2,000 at most, then the oldest 1,000 go).
    public var seenCount: Int { seenOrder.count }

    /// Newest activity first.
    public var sorted: [WAConversation] {
        conversations.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    public var totalUnread: Int { conversations.values.reduce(0) { $0 + $1.unread } }

    public enum Outcome: Equatable, Sendable { case duplicate, ignored, quiet, notify }

    /// Adds a message to its conversation. `.notify` when it should reach you, `.quiet` when it is kept but stays
    /// silent (a muted group, your own message). `history`: an older message loaded on demand (a conversation
    /// opened, the backfill): kept, never counted as unread, never announced.
    @discardableResult
    public mutating func add(_ message: WAMessage, filters: WAFilters, name: String? = nil, history: Bool = false) -> Outcome {
        guard !seenIds.contains(message.id) else { return .duplicate }
        let chat = WAJID.normalized(message.chat)
        guard !filters.ignored.contains(chat), !WAJID.isBroadcast(chat) else { return .ignored }
        seenIds.insert(message.id)
        seenOrder.append(message.id)
        if seenOrder.count > 2_000 {
            let dropped = seenOrder.prefix(1_000)
            seenOrder.removeFirst(1_000)
            for id in dropped { seenIds.remove(id) }
        }

        let isGroup = WAJID.isGroup(chat)
        let number = WAJID.displayNumber(chat)
        // In a private chat the other person names it: never your own name on your own message.
        let personName = isGroup || message.fromMe ? nil : nonEmpty(message.senderName)
        var conversation = conversations[chat] ?? WAConversation(
            id: chat, name: name ?? message.chatName ?? personName ?? number,
            isGroup: isGroup, lastActivity: message.date)
        if let name = name ?? message.chatName, !name.isEmpty { conversation.name = name }
        else if conversation.name == number, let personName { conversation.name = personName }
        var msg = message
        msg.chat = chat
        conversation.messages.append(msg)
        conversation.messages.sort { $0.date < $1.date }
        if conversation.messages.count > Self.keep { conversation.messages.removeFirst(conversation.messages.count - Self.keep) }
        conversation.lastActivity = max(conversation.lastActivity, message.date)

        let outcome: Outcome
        if history {
            outcome = .quiet
        } else if message.fromMe {
            // You answered from the phone: it is read there.
            conversation.unread = 0
            outcome = .quiet
        } else {
            conversation.unread += 1
            outcome = isGroup && filters.muteGroups && !message.mentionsMe ? .quiet : .notify
        }
        conversations[chat] = conversation
        return outcome
    }

    /// The conversations the pill lists: muted groups without unread mentions stay out of it.
    public func visible(filters: WAFilters) -> [WAConversation] {
        sorted.filter { !filters.ignored.contains($0.id) && (!$0.isGroup || !filters.muteGroups || $0.messages.contains { $0.mentionsMe && !$0.fromMe }) }
    }

    /// Unread messages in the conversations the pill shows (a muted group's quiet messages and an ignored chat
    /// can't be opened, so they don't count).
    public func visibleUnread(filters: WAFilters) -> Int {
        visible(filters: filters).reduce(0) { $0 + $1.unread }
    }

    /// A chat dropped from the inbox (the user ignores it).
    public mutating func remove(_ chat: String) {
        conversations[WAJID.normalized(chat)] = nil
    }

    public mutating func markRead(_ chat: String) {
        conversations[WAJID.normalized(chat)]?.unread = 0
    }

    /// History loaded at connection: whether it was read is unknown, so nothing counts as new.
    public mutating func markAllRead() {
        for key in conversations.keys { conversations[key]?.unread = 0 }
    }

    public mutating func rename(_ chat: String, to name: String) {
        guard !name.isEmpty else { return }
        conversations[WAJID.normalized(chat)]?.name = name
    }

    /// Everything goes (Kobe quits, WhatsApp turned off).
    public mutating func clear() {
        conversations = [:]
        seenIds = []
        seenOrder = []
    }

    /// New messages from the webhook or the polling fallback. Messages in the conversation open on screen are read
    /// at once (the receipt waits for a reply or the next opening). Returns the newest message to announce: not
    /// yours, not in the open chat, not in a muted group unless it mentions you; nil when there is none.
    public mutating func ingest(_ messages: [WAMessage], filters: WAFilters, openChat: String?) -> WAMessage? {
        var fresh: WAMessage?
        for message in messages {
            let key = WAJID.normalized(message.chat)
            let outcome = add(message, filters: filters)
            if key == openChat {
                markRead(key)
                continue
            }
            if outcome == .notify, !message.fromMe { fresh = message }
        }
        return fresh
    }

    /// The newest message you received in the chat (what a read receipt points at).
    public func lastIncoming(_ chat: String) -> String? {
        conversations[WAJID.normalized(chat)]?.messages.last { !$0.fromMe }?.id
    }

    /// A group still known only by its id: its name is worth asking the gateway for (once).
    public func needsName(_ chat: String) -> Bool {
        let key = WAJID.normalized(chat)
        guard WAJID.isGroup(key), let conversation = conversations[key] else { return false }
        return conversation.name == WAJID.displayNumber(key)
    }

    private func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}

/// What may be sent from the notch: a reply, in a conversation already there, one at a time.
public enum WAReply {
    public enum Refusal: Equatable, Sendable { case empty, tooLong, notAConversation }
    /// The gateways' own cap (OpenWA's send-text takes 4,096 characters at most).
    public static let maxLength = 4096

    public static func check(_ text: String, to chat: String, in inbox: WAInbox) -> Refusal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        // The gateways count UTF-16 units (an emoji can be two), so that's what is measured.
        if trimmed.utf16.count > maxLength { return .tooLong }
        // Never a new chat, never a list of recipients: only a conversation that wrote to you.
        guard inbox.conversations[WAJID.normalized(chat)] != nil else { return .notAConversation }
        return nil
    }
}

/// A few sends a minute at most, whatever is clicked: Kobe is no bulk sender.
public struct WARateLimit: Sendable {
    public var limit: Int
    public var window: TimeInterval
    public private(set) var sent: [Date] = []

    public init(limit: Int = 6, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    public mutating func allow(now: Date = Date()) -> Bool {
        sent.removeAll { now.timeIntervalSince($0) > window }
        guard sent.count < limit else { return false }
        sent.append(now)
        return true
    }
}

/// How often the controller asks the gateway, on a 5 s tick: every tick while not linked (every
/// sixth once it has failed more than 12 times in a row), and once linked a status check every minute and a poll
/// every 20 s (the poll itself is skipped while webhooks arrive).
public enum WACadence {
    public static let tick: TimeInterval = 5

    public static func onTick(_ tick: Int, linked: Bool, failures: Int) -> (refresh: Bool, poll: Bool) {
        if !linked {
            if failures > 12 && tick % 6 != 0 { return (false, false) }
            return (true, false)
        }
        return (tick % 12 == 0, tick % 4 == 0)
    }

    /// Webhooks came in the last five minutes: no need to poll.
    public static func webhookAlive(lastWebhook: Date?, now: Date = Date()) -> Bool {
        guard let lastWebhook else { return false }
        return now.timeIntervalSince(lastWebhook) < 300
    }

    /// A burst of messages is one announcement, not ten: one every 4 s at most.
    public static func mayAnnounce(last: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(last) > 4
    }
}

// MARK: - The webhook's HTTP request

/// One HTTP request read from the local socket: enough of HTTP/1.1 for a gateway's webhook.
public struct WAHTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public enum Parse: Equatable, Sendable { case incomplete, invalid, done(WAHTTPRequest) }

    /// Parses what arrived so far; `.incomplete` until the whole body is there. Headers over 16 KB or a body over
    /// `maxBody` (1 MB) are refused.
    public static func parse(_ data: Data, maxBody: Int = 1_000_000) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16_384 ? .invalid : .incomplete
        }
        guard end.lowerBound - data.startIndex <= 16_384 else { return .invalid }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBody else { return .invalid }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        return .done(WAHTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body)))
    }

    public static func response(_ status: Int, _ reason: String) -> Data {
        Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        default: "Error"
        }
    }
}

// MARK: - Hex

extension Data {
    public var waHex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Compares two strings in constant time (signatures).
public func waConstantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in x.indices { diff |= x[i] ^ y[i] }
    return diff == 0
}
