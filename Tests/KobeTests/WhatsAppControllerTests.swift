import Foundation
import Testing
@testable import KobeApp
@testable import KobeKit

/// The WhatsApp controller without a gateway: the rules that hold before anything is sent.
@MainActor
struct WhatsAppControllerTests {
    private func make() -> WhatsAppController {
        WhatsAppController(secrets: InMemorySecrets(), report: { _ in })
    }

    @Test func reopeningAConversationWithASavedDraftHoldsTheIsland() {
        let wa = make()
        let chat = "15550001111@s.whatsapp.net"
        wa.drafts[chat] = "See you at 8"
        wa.open(chat)
        // The saved reply is back in the field: the island stays open like while typing it.
        #expect(wa.hasDraft)
        wa.close(chat)
        #expect(!wa.hasDraft)
        // A conversation with nothing typed holds nothing.
        wa.drafts[chat] = nil
        wa.open(chat)
        #expect(!wa.hasDraft)
        // Only spaces is no draft either.
        wa.close(chat)
        wa.drafts[chat] = "  \n"
        wa.open(chat)
        #expect(!wa.hasDraft)
    }

    @Test func eachRefusedReplySaysWhyAndClearsTheLastReason() async {
        let wa = make()
        let chat = "15550001111@s.whatsapp.net"
        #expect(await wa.send(String(repeating: "a", count: 5000), to: chat) == false)
        #expect(wa.sendError == WAText.replyTooLong)
        // Not a chat that wrote to you: its own reason, never the earlier one.
        #expect(await wa.send("hi", to: chat) == false)
        #expect(wa.sendError == WAText.replyNotAConversation)
        #expect(await wa.send("   ", to: chat) == false)
        #expect(wa.sendError == WAText.replyEmpty)
    }

    @Test func refusedReplyThroughTheSinkCarriesThePreciseReason() async {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        let result = await model.actions.perform(.whatsappReply(chat: "15550001111@s.whatsapp.net", text: "hi"))
        guard case .failure(let error) = result else { Issue.record("a reply to an unknown chat went"); return }
        #expect(error.message == WAText.replyNotAConversation)
    }
}
