import Foundation
import KobeKit

/// The shim: the app's own WhatsApp controller and service clients do the work.
@MainActor
final class ShimActionSink: ActionSink {
    private weak var app: AppModel?

    init(app: AppModel) { self.app = app }

    func perform(_ action: WidgetAction) async -> Result<Void, ActionError> {
        guard let app else { return .failure(ActionError(message: "Kobe is closing")) }
        switch action {
        case .whatsappReply(let chat, let text):
            // The controller keeps every rule (existing chats only, 4,096 characters, one at a time, a few a minute)
            // and sets the reason for each refusal.
            if await app.whatsapp.send(text, to: chat) { return .success(()) }
            return .failure(ActionError(message: app.whatsapp.sendError ?? "Couldn't send"))
        case .whatsappMarkRead(let chat):
            app.whatsapp.markRead(chat)
            return .success(())
        case .refresh(let id):
            guard let service = app.service(for: id) else { return .failure(ActionError(message: "Nothing to refresh")) }
            service.refresh()
            return .success(())
        case .reminderDone(let id, let done):
            return await app.mac.setDone(id, done)
        case .addReminder(let draft, let list):
            return await app.mac.addReminder(draft, list: list)
        case .stopRun:
            // Hermes has no stop endpoint: Kobe Agent's own runs stop through its `kobe-actions` daemon (plan 2).
            return .failure(ActionError(message: "Stopping Kobe's own runs arrives with Kobe Agent's connector"))
        }
    }
}
