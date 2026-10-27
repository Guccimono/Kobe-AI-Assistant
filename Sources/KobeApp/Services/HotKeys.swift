import AppKit
import Carbon.HIToolbox

/// Global shortcuts through Carbon hot keys: they work from any app and need no permission. One event handler
/// for all of Kobe's hot keys (ported from the old Kobe), keyed by id, so registering one can never swallow another's presses.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    enum ID: UInt32 {
        case approve = 1, decline, quickAsk
    }

    private static let signature = OSType(0x4B4F_4245)  // "KOBE"
    private var handler: EventHandlerRef?
    private var refs: [ID: EventHotKeyRef] = [:]
    nonisolated(unsafe) fileprivate static var actions: [UInt32: (_ pressed: Bool) -> Void] = [:]

    func isRegistered(_ id: ID) -> Bool { refs[id] != nil }

    /// `action(true)` on press, `action(false)` on release. Returns false when macOS refused the combination
    /// (another app owns it).
    @discardableResult
    func register(_ id: ID, keyCode: Int, modifiers: Int, action: @escaping (_ pressed: Bool) -> Void) -> Bool {
        installHandler()
        unregister(id)
        Self.actions[id.rawValue] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: Self.signature, id: id.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { Self.actions[id.rawValue] = nil; return false }
        refs[id] = ref
        return true
    }

    func unregister(_ id: ID) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        Self.actions[id.rawValue] = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Not ours: let the next handler have it.
            guard id.signature == HotKeyCenter.signature, let action = HotKeyCenter.actions[id.id] else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { action(pressed) }
            return noErr
        }, 2, &types, nil, &handler)
    }
}
