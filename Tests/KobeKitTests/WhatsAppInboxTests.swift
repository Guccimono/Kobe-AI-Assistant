import Foundation
import Testing
@testable import KobeKit

private func msg(_ id: String, chat: String = "15550001111@s.whatsapp.net", name: String = "Ana", text: String = "hi",
                 at seconds: TimeInterval = 0, fromMe: Bool = false, mentions: Bool = false) -> WAMessage {
    WAMessage(id: id, chat: chat, sender: chat, senderName: name, text: text,
              date: Date(timeIntervalSince1970: 1_000 + seconds), fromMe: fromMe, mentionsMe: mentions)
}

private let group = "120363000000000001@g.us"

@Suite struct WhatsAppJIDTests {
    @Test func normalisesTheSamePersonUnderItsForms() {
        #expect(WAJID.normalized("15550001111:12@s.whatsapp.net") == "15550001111@s.whatsapp.net")
        #expect(WAJID.normalized("15550001111@c.us") == "15550001111@s.whatsapp.net")
        #expect(WAJID.normalized(group) == group)
        #expect(WAJID.normalized("bare") == "bare")
    }

    @Test func displayNumberInitialsAndDuration() {
        #expect(WAJID.displayNumber("15550001111:3@s.whatsapp.net") == "+15550001111")
        #expect(WAJID.displayNumber("abc@lid") == "abc")
        #expect(WAJID.initials("Marie Dupont") == "MD")
        #expect(WAJID.initials("jean-paul sartre") == "JP")
        #expect(WAJID.initials("+33 6 12") == "#")
        #expect(WAJID.duration(12) == "0:12")
        #expect(WAJID.duration(75) == "1:15")
        #expect(WAJID.isGroup(group))
    }

    @Test func storiesChannelsAndBroadcastsAreNotChats() {
        #expect(WAJID.isBroadcast("status@broadcast"))
        #expect(WAJID.isBroadcast("1729000000@broadcast"))
        #expect(WAJID.isBroadcast("120363000000000009@newsletter"))
        #expect(!WAJID.isBroadcast("15550001111@s.whatsapp.net"))
        #expect(!WAJID.isBroadcast(group))
        #expect(!WAJID.isBroadcast("abc@lid"))
    }

    @Test func sameUserAndDigits() {
        #expect(WAJID.digits("15550001111:3@s.whatsapp.net") == "15550001111")
        #expect(WAJID.sameUser("15550001111@c.us", "15550001111@s.whatsapp.net"))
        #expect(!WAJID.sameUser("", ""))
    }

    @Test func ignoreEntryTakesANumberOrAChatId() {
        #expect(WAJID.ignoreEntry("+1 555 000 1111") == "15550001111@s.whatsapp.net")
        #expect(WAJID.ignoreEntry(group) == group)
        #expect(WAJID.ignoreEntry("   ") == nil)
        #expect(WAJID.ignoreEntry("abc") == nil)
    }

    @Test func mentionsNeedSixDigits() {
        #expect(WAMention.textMentions("hey @15550009999", me: "15550009999:2@s.whatsapp.net"))
        #expect(!WAMention.textMentions("hey @123", me: "123@s.whatsapp.net"))
        #expect(!WAMention.textMentions("hey", me: nil))
    }
}

@Suite struct WhatsAppInboxTests {
    @Test func groupsMessagesByConversationAndCountsUnread() {
        var inbox = WAInbox()
        let filters = WAFilters()
        #expect(inbox.add(msg("1"), filters: filters) == .notify)
        #expect(inbox.add(msg("2", chat: "15550001111@c.us", at: 5), filters: filters) == .notify)
        #expect(inbox.add(msg("2"), filters: filters) == .duplicate)
        #expect(inbox.conversations.count == 1)
        let conversation = inbox.conversations["15550001111@s.whatsapp.net"]!
        #expect(conversation.unread == 2)
        #expect(conversation.name == "Ana")
        #expect(conversation.messages.map(\.id) == ["1", "2"])
        #expect(inbox.totalUnread == 2)
    }

    @Test func yourOwnMessageReadsTheChatAndNeverNamesIt() {
        var inbox = WAInbox()
        inbox.add(msg("1", name: "", at: 0), filters: WAFilters())
        #expect(inbox.conversations.values.first?.name == "+15550001111")
        #expect(inbox.add(msg("2", name: "Me", at: 1, fromMe: true), filters: WAFilters()) == .quiet)
        let conversation = inbox.conversations.values.first!
        #expect(conversation.unread == 0)
        #expect(conversation.name == "+15550001111")
        inbox.add(msg("3", name: "Ana", at: 2), filters: WAFilters())
        #expect(inbox.conversations.values.first?.name == "Ana")
    }

    @Test func mutedGroupsStayQuietUnlessYouAreMentioned() {
        var inbox = WAInbox()
        let filters = WAFilters(muteGroups: true)
        #expect(inbox.add(msg("1", chat: group, name: "Bruno"), filters: filters) == .quiet)
        #expect(inbox.visible(filters: filters).isEmpty)
        #expect(inbox.visibleUnread(filters: filters) == 0)
        #expect(inbox.totalUnread == 1)
        #expect(inbox.add(msg("2", chat: group, name: "Bruno", at: 1, mentions: true), filters: filters) == .notify)
        #expect(inbox.visible(filters: filters).count == 1)
        #expect(inbox.visibleUnread(filters: filters) == 2)
        // A group's own name, never a member's.
        #expect(inbox.conversations[group]?.name == WAJID.displayNumber(group))
        #expect(inbox.needsName(group))
        inbox.rename(group, to: "Team")
        #expect(!inbox.needsName(group))
        #expect(inbox.add(msg("3", chat: group, at: 2), filters: WAFilters(muteGroups: false)) == .notify)
    }

    @Test func ignoredChatsAreDropped() {
        var inbox = WAInbox()
        let filters = WAFilters(ignored: ["15550001111@s.whatsapp.net"])
        #expect(inbox.add(msg("1", chat: "15550001111@c.us"), filters: filters) == .ignored)
        #expect(inbox.conversations.isEmpty)
        inbox.add(msg("2"), filters: WAFilters())
        #expect(inbox.visible(filters: filters).isEmpty)
        inbox.remove("15550001111@c.us")
        #expect(inbox.conversations.isEmpty)
    }

    @Test func historyIsKeptButNeverUnread() {
        var inbox = WAInbox()
        #expect(inbox.add(msg("1"), filters: WAFilters(), history: true) == .quiet)
        #expect(inbox.totalUnread == 0)
        inbox.add(msg("2", at: 1), filters: WAFilters())
        inbox.markAllRead()
        #expect(inbox.totalUnread == 0)
    }

    @Test func storyIsIgnoredNeverAChat() {
        var inbox = WAInbox()
        #expect(inbox.add(msg("s1", chat: "status@broadcast", name: "Ana"), filters: WAFilters()) == .ignored)
        #expect(inbox.add(msg("n1", chat: "120363000000000009@newsletter"), filters: WAFilters(), history: true) == .ignored)
        #expect(inbox.conversations.isEmpty)
        #expect(inbox.totalUnread == 0)
    }

    @Test func keepsTheLastTwoHundredNewestLast() {
        // Enough for a week of a busy chat, so an old message can still be read and answered.
        #expect(WAInbox.keep == 200)
        var inbox = WAInbox()
        for i in (0..<205).reversed() { inbox.add(msg("m\(i)", at: TimeInterval(i)), filters: WAFilters()) }
        let messages = inbox.conversations.values.first!.messages
        #expect(messages.count == WAInbox.keep)
        #expect(messages.first?.id == "m5")
        #expect(messages.last?.id == "m204")
    }

    @Test func forgetsTheOldestThousandIdsPastTwoThousand() {
        var inbox = WAInbox()
        for i in 0...2_000 { inbox.add(msg("id\(i)", at: TimeInterval(i)), filters: WAFilters()) }
        #expect(inbox.seenCount == 1_001)
        // An old id is new again; a recent one is still a duplicate.
        #expect(inbox.add(msg("id0"), filters: WAFilters()) != .duplicate)
        #expect(inbox.add(msg("id2000"), filters: WAFilters()) == .duplicate)
    }

    @Test func sortedNewestFirstAndClear() {
        var inbox = WAInbox()
        inbox.add(msg("1", at: 0), filters: WAFilters())
        inbox.add(msg("2", chat: "15550003333@s.whatsapp.net", name: "Caro", at: 10), filters: WAFilters())
        #expect(inbox.sorted.map(\.name) == ["Caro", "Ana"])
        inbox.markRead("15550003333@c.us")
        #expect(inbox.totalUnread == 1)
        inbox.clear()
        #expect(inbox.conversations.isEmpty && inbox.seenCount == 0)
    }

    @Test func ingestAnnouncesTheNewestButNotTheOpenChat() {
        var inbox = WAInbox()
        let fresh = inbox.ingest([msg("1"), msg("2", chat: "15550003333@s.whatsapp.net", name: "Caro", at: 1),
                                  msg("3", at: 2, fromMe: true)], filters: WAFilters(), openChat: nil)
        #expect(fresh?.id == "2")
        let open = inbox.ingest([msg("4", at: 3)], filters: WAFilters(), openChat: "15550001111@s.whatsapp.net")
        #expect(open == nil)
        #expect(inbox.conversations["15550001111@s.whatsapp.net"]?.unread == 0)
        #expect(inbox.ingest([msg("5", chat: group, at: 4)], filters: WAFilters(), openChat: nil) == nil)
        #expect(inbox.lastIncoming("15550001111@s.whatsapp.net") == "4")
    }
}

@Suite struct WhatsAppReplyTests {
    @Test func onlyToAConversationAlreadyThere() {
        var inbox = WAInbox()
        inbox.add(msg("1"), filters: WAFilters())
        #expect(WAReply.check("  \n ", to: "15550001111@s.whatsapp.net", in: inbox) == .empty)
        #expect(WAReply.check(String(repeating: "a", count: 4097), to: "15550001111@s.whatsapp.net", in: inbox) == .tooLong)
        #expect(WAReply.check(String(repeating: "a", count: 4096), to: "15550001111@c.us", in: inbox) == nil)
        // 2,049 emoji are 2,049 characters but 4,098 UTF-16 units: too long for the gateway.
        #expect(WAReply.check(String(repeating: "😀", count: 2049), to: "15550001111@c.us", in: inbox) == .tooLong)
        #expect(WAReply.check("hi", to: "15559999999@s.whatsapp.net", in: inbox) == .notAConversation)
    }

    @Test func sixAMinuteAtMost() {
        var limit = WARateLimit()
        let start = Date(timeIntervalSince1970: 0)
        func allow(_ t: TimeInterval) -> Bool { limit.allow(now: start.addingTimeInterval(t)) }
        for i in 0..<6 { #expect(allow(TimeInterval(i))) }
        #expect(!allow(30))
        #expect(allow(61))
    }

    @Test func cadenceFollowsTheTick() {
        #expect(WACadence.onTick(1, linked: false, failures: 0) == (true, false))
        #expect(WACadence.onTick(5, linked: false, failures: 13) == (false, false))
        #expect(WACadence.onTick(6, linked: false, failures: 13) == (true, false))
        #expect(WACadence.onTick(4, linked: true, failures: 0) == (false, true))
        #expect(WACadence.onTick(12, linked: true, failures: 0) == (true, true))
        #expect(WACadence.onTick(5, linked: true, failures: 0) == (false, false))
        let now = Date()
        #expect(WACadence.webhookAlive(lastWebhook: now.addingTimeInterval(-299), now: now))
        #expect(!WACadence.webhookAlive(lastWebhook: now.addingTimeInterval(-301), now: now))
        #expect(!WACadence.webhookAlive(lastWebhook: nil, now: now))
        #expect(!WACadence.mayAnnounce(last: now.addingTimeInterval(-3), now: now))
        #expect(WACadence.mayAnnounce(last: now.addingTimeInterval(-5), now: now))
    }

    @Test func previewsAndLabels() {
        var m = msg("1", text: "line\nbreak")
        #expect(WAText.preview(m, isGroup: false) == "line break")
        m.fromMe = true
        #expect(WAText.preview(m, isGroup: false) == "You: line break")
        m = msg("2", name: "Bruno", text: "look")
        m.media = .image
        #expect(WAText.preview(m, isGroup: true) == "Bruno: Photo · look")
        m.media = .voice(seconds: 75)
        #expect(WAText.preview(m, isGroup: false) == "Voice message · 1:15")
        m.media = .document(name: "menu.pdf")
        #expect(WAText.preview(m, isGroup: false) == "Document · menu.pdf")
        m.media = .sticker
        #expect(WAText.preview(m, isGroup: false) == "Sticker")
        #expect(WAText.unreadBadge(100) == "99+")
        #expect(WAText.unreadBadge(7) == "7")
        let now = Date()
        #expect(WAText.timeAgo(now.addingTimeInterval(-30), now: now) == "now")
        #expect(WAText.timeAgo(now.addingTimeInterval(-300), now: now) == "5m")
        #expect(WAText.timeAgo(now.addingTimeInterval(-7200), now: now) == "2h")
        #expect(WAText.timeAgo(now.addingTimeInterval(-200_000), now: now) == "2d")
    }
}

struct WAReplyRefusalTextTests {
    @Test func eachRefusalHasItsOwnReason() {
        #expect(WAText.refusal(.empty) == WAText.replyEmpty)
        #expect(WAText.refusal(.tooLong) == WAText.replyTooLong)
        #expect(WAText.refusal(.notAConversation) == WAText.replyNotAConversation)
        let all = [WAText.replyEmpty, WAText.replyTooLong, WAText.replyNotAConversation, WAText.replyTooFast,
                   WAText.replySending, WAText.replyNotConnected]
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { !$0.isEmpty })
    }
}
