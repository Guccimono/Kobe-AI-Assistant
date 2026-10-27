import Foundation

/// English strings for WhatsApp.
/// In KobeKit so the controller, the views and the tests share one copy.
public enum WAText {
    public static let mediaPhoto = "Photo"
    public static let mediaVideo = "Video"
    public static let mediaVoice = "Voice message"
    public static let mediaDocument = "Document"
    public static let mediaSticker = "Sticker"
    public static let mediaLocation = "Location"
    public static let mediaContact = "Contact"
    public static let mediaOther = "Message"
    public static let you = "You"
    public static let now = "now"

    public static let statusOff = "Turned off in Settings"
    public static let statusConnecting = "Connecting to the gateway…"
    public static let statusNeedsQR = "Scan the QR code in Settings"
    public static let statusConnected = "Connected"
    public static let statusUnreachable = "The gateway doesn’t answer: is it running?"
    public static let statusUnauthorized = "The gateway refuses the credentials"
    public static let statusBadURL = "The gateway URL isn’t valid (http://…)"

    public static func testConnected(_ who: String) -> String { "Connected as \(who)." }
    public static let testConnecting = "The gateway answers and is connecting to WhatsApp…"
    public static let testNeedsQR = "The gateway answers. Scan the QR code below with your phone."

    public static let replyTooLong = "Too long for one message (4,096 characters at most)."
    public static let replyTooFast = "A few replies a minute at most: wait a moment."
    public static let replyEmpty = "Nothing to send."
    public static let replyNotAConversation = "Replies only go to a chat that wrote to you."
    public static let replySending = "The last reply is still on its way: wait a moment."
    public static let replyNotConnected = "WhatsApp isn’t connected: nothing was sent."

    /// Why `WAReply.check` refused a reply, in the words shown under the field.
    public static func refusal(_ refusal: WAReply.Refusal) -> String {
        switch refusal {
        case .empty: replyEmpty
        case .tooLong: replyTooLong
        case .notAConversation: replyNotAConversation
        }
    }
    public static let replyPlaceholder = "Reply…  (⇧↩ new line)"

    public static let installNoBuild = "No GOWA build for this Mac was found on GitHub. Try again later, or set your own gateway under Advanced."
    public static let installNoChecksum = "GOWA's release has no checksum to check the download against: nothing was installed."
    public static let installDownloadFailed = "The download didn't go through. Check your connection and try again."
    public static let installBadChecksum = "The download doesn't match the file GOWA published: it was deleted, nothing was installed."
    public static let installUnzipFailed = "The download couldn't be unzipped. Try again."

    /// "Marie: see you", "You: ok", "Photo · look", "Voice message": one line, media as a label only.
    public static func preview(_ message: WAMessage, isGroup: Bool) -> String {
        let (label, value) = message.preview
        var line = label.isEmpty ? value : (value.isEmpty ? label : "\(label) · \(value)")
        line = line.replacingOccurrences(of: "\n", with: " ")
        if message.fromMe { return you + ": " + line }
        if isGroup, !message.senderName.isEmpty { return message.senderName + ": " + line }
        return line
    }

    /// "now", "5m", "3h", "2d".
    public static func timeAgo(_ date: Date, now: Date = Date()) -> String {
        let diff = now.timeIntervalSince(date)
        if diff < 60 { return Self.now }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        return "\(Int(diff / 86400))d"
    }

    /// The unread capsule: "3", "99+".
    public static func unreadBadge(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
}
