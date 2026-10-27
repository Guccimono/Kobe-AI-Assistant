import Foundation
import CryptoKit

// What the two local WhatsApp gateways send and answer, turned into WAMessage. Every field
// name here comes from each gateway's docs and source code:
//   GOWA   — github.com/aldinokemal/go-whatsapp-web-multidevice (docs/webhook-payload.md, docs/openapi.yaml)
//   OpenWA — github.com/rmyndharis/OpenWA (docs/06-api-specification.md)
// Nothing parsed here is logged or written anywhere.

public enum WAGatewayKind: String, CaseIterable, Sendable {
    case gowa, openwa

    public var name: String { self == .gowa ? "GOWA" : "OpenWA" }
    /// Kobe runs GOWA on 47840: port 3000 (the default) is Hermes' own WhatsApp bridge.
    public var defaultURL: String { self == .gowa ? "http://127.0.0.1:\(WAGOWA.defaultPort)" : "http://127.0.0.1:2785" }
    /// The header carrying the webhook's HMAC-SHA256 ("sha256=<hex>"), lowercased.
    public var signatureHeader: String { self == .gowa ? "x-hub-signature-256" : "x-openwa-signature" }
}

/// What one webhook delivery holds for Kobe.
public enum WAWebhookEvent: Equatable, Sendable {
    case message(WAMessage)
    /// A valid delivery Kobe has no use for (receipts, reactions, a test ping…).
    case ignored
}

public enum WAWebhook {
    /// The path the gateway posts to on Kobe's local listener.
    public static let path = "/whatsapp"

    /// "sha256=<lowercase hex>" of HMAC-SHA256(secret, body): what both gateways send.
    public static func signature(body: Data, secret: String) -> String {
        "sha256=" + Data(HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))).waHex
    }

    /// True when the delivery carries the signature `secret` gives, over the raw body bytes.
    public static func verify(kind: WAGatewayKind, headers: [String: String], body: Data, secret: String) -> Bool {
        guard !secret.isEmpty, let sent = headers[kind.signatureHeader], sent.hasPrefix("sha256=") else { return false }
        return waConstantTimeEqual(sent, signature(body: body, secret: secret))
    }

    /// The listener's answer to one request: 404 off the path, 401 unsigned, 200 for a signed delivery (whose body
    /// is then handed over).
    public static func status(for request: WAHTTPRequest, kind: WAGatewayKind, secret: String) -> Int {
        guard request.method == "POST", request.path.hasPrefix(path) else { return 404 }
        guard verify(kind: kind, headers: request.headers, body: request.body, secret: secret) else { return 401 }
        return 200
    }

    /// Parses one delivery. nil when it isn't JSON at all. `me` is this account's JID or number, to tell a mention
    /// of you (GOWA also gives it in the delivery itself).
    public static func parse(kind: WAGatewayKind, body: Data, me: String? = nil) -> WAWebhookEvent? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        switch kind {
        case .gowa: return parseGOWA(json, me: me)
        case .openwa: return parseOpenWA(json, me: me)
        }
    }

    // MARK: GOWA

    /// `{"event":"message","device_id":"<own JID>","payload":{id, chat_id, from, from_name, sender_display_name,
    /// timestamp (RFC3339), is_from_me, body, image|video|audio|document|…}}`
    private static func parseGOWA(_ json: [String: Any], me: String?) -> WAWebhookEvent {
        guard json["event"] as? String == "message",
              let p = json["payload"] as? [String: Any],
              let id = p["id"] as? String, !id.isEmpty,
              let chat = p["chat_id"] as? String, !chat.isEmpty else { return .ignored }
        let from = (p["from"] as? String) ?? chat
        let text = (p["body"] as? String) ?? ""
        let mine = me ?? (json["device_id"] as? String)
        var message = WAMessage(
            id: id, chat: chat, sender: from,
            senderName: nonEmpty(p["sender_display_name"]) ?? nonEmpty(p["from_name"]) ?? "",
            text: text, media: gowaMedia(p),
            date: WADate.rfc3339(p["timestamp"] as? String) ?? Date(),
            fromMe: p["is_from_me"] as? Bool ?? false)
        message.mentionsMe = WAJID.isGroup(chat) && WAMention.textMentions(text, me: mine)
        return .message(message)
    }

    /// GOWA puts each media under its own key; only the label matters to Kobe.
    public static func gowaMedia(_ p: [String: Any]) -> WAMedia {
        if p["image"] != nil { return .image }
        if p["video"] != nil || p["video_note"] != nil { return .video }
        if p["audio"] != nil { return .voice(seconds: nil) }
        if let doc = p["document"] {
            return .document(name: (doc as? [String: Any]).flatMap { nonEmpty($0["filename"]) })
        }
        if p["sticker"] != nil { return .sticker }
        if p["location"] != nil || p["live_location"] != nil { return .location }
        if p["contact"] != nil || p["contacts_array"] != nil { return .contact }
        if p["poll"] != nil { return .other }
        return .none
    }

    // MARK: OpenWA

    /// `{"event":"message.received"|"message.sent","sessionId","data":{id, from, to, chatId, author, body, type,
    /// timestamp (epoch s), fromMe, isGroup, mentionedIds, contact{name, pushName}, media{filename}}}`
    private static func parseOpenWA(_ json: [String: Any], me: String?) -> WAWebhookEvent {
        let event = json["event"] as? String
        guard event == "message.received" || event == "message.sent",
              let d = json["data"] as? [String: Any],
              let id = d["id"] as? String, !id.isEmpty,
              let chat = (d["chatId"] as? String) ?? (d["from"] as? String), !chat.isEmpty else { return .ignored }
        let type = (d["type"] as? String) ?? "text"
        guard type != "revoked" else { return .ignored }
        let fromMe = (d["fromMe"] as? Bool) ?? (event == "message.sent")
        let contact = d["contact"] as? [String: Any]
        let media = d["media"] as? [String: Any]
        var message = WAMessage(
            id: id, chat: chat,
            sender: nonEmpty(d["author"]) ?? (d["from"] as? String) ?? chat,
            senderName: nonEmpty(contact?["name"]) ?? nonEmpty(contact?["pushName"]) ?? "",
            text: (d["body"] as? String) ?? "",
            media: openwaMedia(type, filename: nonEmpty(media?["filename"])),
            date: WADate.epoch(d["timestamp"]) ?? Date(),
            fromMe: fromMe)
        let isGroup = (d["isGroup"] as? Bool) ?? WAJID.isGroup(chat)
        if isGroup, let mine = me {
            let ids = (d["mentionedIds"] as? [String]) ?? []
            message.mentionsMe = ids.contains { WAJID.sameUser($0, mine) } || WAMention.textMentions(message.text, me: mine)
        }
        return .message(message)
    }

    /// OpenWA's `type` (text|image|video|audio|voice|document|sticker|location|contact|poll|…).
    public static func openwaMedia(_ type: String, filename: String? = nil) -> WAMedia {
        switch type {
        case "text", "": return .none
        case "image": return .image
        case "video": return .video
        case "audio": return .audio(seconds: nil)
        case "voice": return .voice(seconds: nil)
        case "document": return .document(name: filename)
        case "sticker": return .sticker
        case "location": return .location
        case "contact": return .contact
        default: return .other
        }
    }
}

// MARK: - REST answers (status, QR, polling)

/// What a gateway says of the WhatsApp link.
public struct WAStatus: Equatable, Sendable {
    public enum Link: Equatable, Sendable {
        /// Logged in and online.
        case connected
        /// Waiting for the QR to be scanned.
        case needsQR
        /// Logged in but offline, starting, or anything in between.
        case connecting
    }
    public var link: Link
    /// This account's JID or number, once logged in.
    public var me: String?

    public init(link: Link, me: String?) {
        self.link = link
        self.me = me
    }
}

public enum WAGOWA {
    /// Kobe's GOWA port (3000 is Hermes' own WhatsApp bridge) and device id, kept from the first Kobe link.
    public static let defaultPort = 47840
    public static let deviceID = "kobe"

    /// GOWA's envelope: `{code, message, results}` (no "status": the HTTP code says it).
    public static func results(_ data: Data) -> Any? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["results"]
    }

    /// `GET /devices` → `results: [{id, phone_number, display_name, state, jid, created_at}]`. The device Kobe uses:
    /// a logged-in one first, else the first one.
    public static func device(_ data: Data) -> (id: String, status: WAStatus)? {
        guard let list = results(data) as? [[String: Any]], !list.isEmpty else { return nil }
        let pick = list.first { $0["state"] as? String == "logged_in" } ?? list[0]
        guard let id = pick["id"] as? String, !id.isEmpty else { return nil }
        let jid = nonEmpty(pick["jid"])
        let link: WAStatus.Link
        switch pick["state"] as? String {
        case "logged_in": link = .connected
        default: link = jid == nil ? .needsQR : .connecting
        }
        return (id, WAStatus(link: link, me: jid))
    }

    /// `GET /devices/{id}/login` → `results: {device_id, qr_link, qr_duration}`. The PNG's path, to fetch from the
    /// gateway itself (never from another host the link may name).
    public static func qrPath(_ data: Data) -> (path: String, seconds: Int)? {
        guard let r = results(data) as? [String: Any], let link = r["qr_link"] as? String,
              let url = URL(string: link), !url.path.isEmpty else { return nil }
        return (url.path, (r["qr_duration"] as? Int) ?? 30)
    }

    /// `gowa rest` for "Start GOWA automatically": on this Mac only, on the URL's port, media never downloaded
    /// (Kobe shows a label, so GOWA keeps no photo or voice note on disk), and listed as "Kobe" on the phone.
    public static func launchArguments(for url: URL) -> [String] {
        ["rest", "--host=127.0.0.1", "--port=\(url.port ?? defaultPort)", "--auto-download-media=false", "--os=Kobe"]
    }

    /// The error code of a refused call (`ALREADY_LOGGED_IN`, `DEVICE_ID_REQUIRED`…).
    public static func errorCode(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["code"] as? String
    }

    /// `GET /chats` → `results: {data: [{jid, name, last_message_time, …}], pagination}`.
    public static func chats(_ data: Data) -> [(jid: String, name: String, last: Date)] {
        guard let r = results(data) as? [String: Any], let list = r["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let jid = c["jid"] as? String, !jid.isEmpty, !WAJID.isBroadcast(jid) else { return nil }
            return (jid, (c["name"] as? String) ?? "", WADate.rfc3339(c["last_message_time"] as? String) ?? .distantPast)
        }
    }

    /// `GET /chat/{jid}/messages` → `results: {data: [{id, chat_jid, sender_jid, sender_display_name, content,
    /// timestamp, is_from_me, media_type, filename}], chat_info}`. Newest first there.
    public static func messages(_ data: Data, me: String?) -> [WAMessage] {
        guard let r = results(data) as? [String: Any], let list = r["data"] as? [[String: Any]] else { return [] }
        let chatName = nonEmpty((r["chat_info"] as? [String: Any])?["name"])
        return list.compactMap { m in
            guard let id = m["id"] as? String, let chat = m["chat_jid"] as? String else { return nil }
            let text = (m["content"] as? String) ?? ""
            var msg = WAMessage(
                id: id, chat: chat, sender: (m["sender_jid"] as? String) ?? chat,
                senderName: nonEmpty(m["sender_display_name"]) ?? "",
                text: text, media: gowaStoredMedia(m["media_type"] as? String, filename: nonEmpty(m["filename"])),
                date: WADate.rfc3339(m["timestamp"] as? String) ?? .distantPast,
                fromMe: m["is_from_me"] as? Bool ?? false)
            msg.chatName = WAJID.isGroup(chat) ? chatName : nil
            msg.mentionsMe = WAJID.isGroup(chat) && WAMention.textMentions(text, me: me)
            return msg
        }
    }

    /// `media_type` of a stored message: image|video|video_note|audio|document|sticker|call or "".
    public static func gowaStoredMedia(_ type: String?, filename: String?) -> WAMedia {
        switch type ?? "" {
        case "": return .none
        case "image": return .image
        case "video", "video_note": return .video
        case "audio": return .voice(seconds: nil)
        case "document": return .document(name: filename)
        case "sticker": return .sticker
        default: return .other
        }
    }
}

/// GOWA's own releases on GitHub, for "Install WhatsApp" (one click, no Terminal): which zip fits this Mac and the
/// SHA-256 GOWA publishes for it. GoReleaser names them `whatsapp_<version>_darwin_<arch>.zip` (the binary inside
/// is `darwin-<arch>`) next to `checksums-macos.txt`.
public enum WAGOWARelease {
    public static let latestURL = URL(string: "https://api.github.com/repos/aldinokemal/go-whatsapp-web-multidevice/releases/latest")!

    public struct Asset: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let size: Int
        /// "sha256:<hex>" when GitHub gives it.
        public let digest: String?

        public init(name: String, url: URL, size: Int, digest: String?) {
            self.name = name
            self.url = url
            self.size = size
            self.digest = digest
        }
    }

    /// `GET /releases/latest` → `{tag_name, assets: [{name, browser_download_url, size, digest?}]}`.
    public static func parse(_ data: Data) -> (version: String, assets: [Asset])? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String, let list = obj["assets"] as? [[String: Any]] else { return nil }
        let assets: [Asset] = list.compactMap { a in
            guard let name = a["name"] as? String, let s = a["browser_download_url"] as? String,
                  let url = URL(string: s) else { return nil }
            return Asset(name: name, url: url, size: (a["size"] as? Int) ?? 0, digest: a["digest"] as? String)
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return (version, assets)
    }

    /// The zip for this Mac ("arm64" or "amd64") and the macOS checksums file.
    public static func pick(_ assets: [Asset], arch: String) -> (zip: Asset, checksums: Asset?)? {
        guard let zip = assets.first(where: { $0.name.hasPrefix("whatsapp_") && $0.name.hasSuffix("_darwin_\(arch).zip") }) else { return nil }
        return (zip, assets.first { $0.name == "checksums-macos.txt" })
    }

    /// The binary's name inside the zip.
    public static func binaryName(arch: String) -> String { "darwin-\(arch)" }

    /// This Mac's architecture, as GOWA's release names it.
    public static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    /// The SHA-256 (lowercase hex) of `asset` in a GoReleaser checksums file ("<hex>  <name>" per line), else from
    /// GitHub's own "sha256:<hex>" digest.
    public static func expectedSHA256(for asset: Asset, checksums: String?) -> String? {
        for line in (checksums ?? "").split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1] == Substring(asset.name), parts[0].count == 64 { return parts[0].lowercased() }
        }
        if let d = asset.digest, d.hasPrefix("sha256:"), d.count == 71 { return String(d.dropFirst(7)).lowercased() }
        return nil
    }

    /// The SHA-256 of a downloaded file, lowercase hex.
    public static func sha256(_ data: Data) -> String { Data(SHA256.hash(data: data)).waHex }

    /// Only GitHub serves the download (its assets redirect to githubusercontent.com).
    public static func allowedHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "github.com" || h == "api.github.com" || h.hasSuffix(".githubusercontent.com")
    }
}

public typealias WAOpenWASession = (id: String, status: String, phone: String?)

public enum WAOpenWA {
    /// A session: `{id (uuid), name, status, phone, pushName, …}`.
    /// status: created|initializing|qr_ready|authenticating|ready|disconnected|action_required|failed.
    public static func session(_ obj: Any?) -> WAOpenWASession? {
        guard let s = obj as? [String: Any], let id = s["id"] as? String, !id.isEmpty else { return nil }
        return (id, (s["status"] as? String) ?? "", nonEmpty(s["phone"]))
    }

    public static func status(_ s: WAOpenWASession) -> WAStatus {
        switch s.status {
        case "ready": return WAStatus(link: .connected, me: s.phone)
        case "qr_ready": return WAStatus(link: .needsQR, me: nil)
        default: return WAStatus(link: .connecting, me: s.phone)
        }
    }

    /// Sessions that must be started before a QR can come: never started, stopped or failed.
    public static func needsStart(_ status: String) -> Bool {
        ["created", "disconnected", "failed"].contains(status)
    }

    /// `GET /api/sessions/{id}/qr` → `{qrCode: "data:image/png;base64,…", status}`: the PNG bytes.
    public static func qrPNG(_ data: Data) -> Data? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = obj["qrCode"] as? String,
              let comma = url.firstIndex(of: ","), url.hasPrefix("data:image/png;base64") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    /// `GET /api/sessions/{id}/messages` → `{messages: [{waMessageId, chatId, from, author, chatName, body, type,
    /// direction, timestamp (s), metadata}], total}`.
    public static func messages(_ data: Data, me: String?) -> [WAMessage] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = obj["messages"] as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = nonEmpty(m["waMessageId"]) ?? nonEmpty(m["id"]),
                  let chat = m["chatId"] as? String, !chat.isEmpty else { return nil }
            let type = (m["type"] as? String) ?? "text"
            guard type != "revoked" else { return nil }
            let media = (m["metadata"] as? [String: Any])?["media"] as? [String: Any]
            var msg = WAMessage(
                id: id, chat: chat, sender: nonEmpty(m["author"]) ?? (m["from"] as? String) ?? chat,
                senderName: "", text: (m["body"] as? String) ?? "",
                media: WAWebhook.openwaMedia(type, filename: nonEmpty(media?["filename"])),
                date: WADate.epoch(m["timestamp"]) ?? .distantPast,
                fromMe: m["direction"] as? String == "outgoing")
            msg.chatName = nonEmpty(m["chatName"])
            if WAJID.isGroup(chat), let me { msg.mentionsMe = WAMention.textMentions(msg.text, me: me) }
            return msg
        }
    }

    /// NestJS error: `{statusCode, message (string or [string]), error}`.
    public static func errorMessage(_ data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let s = obj["message"] as? String { return s }
        return (obj["message"] as? [String])?.joined(separator: ", ")
    }

    /// OpenWA names people `<number>@c.us` (Kobe keeps the @s.whatsapp.net form inside).
    public static func chatId(_ jid: String) -> String {
        jid.hasSuffix("@s.whatsapp.net") ? jid.replacingOccurrences(of: "@s.whatsapp.net", with: "@c.us") : jid
    }
}

// MARK: - Helpers

public enum WAMention {
    /// "@33612345678" in the text, for this account's number (how GOWA shows a mention of you).
    public static func textMentions(_ text: String, me: String?) -> Bool {
        guard let me, case let digits = WAJID.digits(me), digits.count >= 6 else { return false }
        return text.contains("@" + digits)
    }
}

public enum WADate {
    public static func rfc3339(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    public static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// Epoch seconds, as a number or a numeric string.
    public static func epoch(_ v: Any?) -> Date? {
        if let n = v as? Double, n > 0 { return Date(timeIntervalSince1970: n) }
        if let n = v as? Int, n > 0 { return Date(timeIntervalSince1970: TimeInterval(n)) }
        if let s = v as? String, let n = Double(s), n > 0 { return Date(timeIntervalSince1970: n) }
        return nil
    }
}

private func nonEmpty(_ v: Any?) -> String? {
    guard let s = v as? String, !s.isEmpty else { return nil }
    return s
}
