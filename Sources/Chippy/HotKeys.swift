import Carbon.HIToolbox
import Combine
import ChippyCore

/// What a shortcut means for the card on screen.
enum ShortcutAction: Equatable {
    case allow, deny, always
    case option(Int) // 1-based digit
}

/// A shortcut routed to one card by request id, so a stale key can't answer the next card.
struct ShortcutEvent {
    let requestId: String
    let action: ShortcutAction
}

/// QuestionCard listens here; approvals are answered straight through the model.
enum ShortcutBus {
    static let events = PassthroughSubject<ShortcutEvent, Never>()
    /// QuestionCard reports which question it is on, so keys can match that question's options.
    static let steps = PassthroughSubject<(requestId: String, step: Int), Never>()
}

/// The one table of keys. All use Control+Option.
enum ShortcutKeys {
    static let prefix = "⌃⌥"
    static let approval: [(keyCode: Int, action: ShortcutAction)] = [
        (kVK_ANSI_Y, .allow), (kVK_ANSI_N, .deny), (kVK_ANSI_A, .always),
    ]
    static let digits: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// Digits 1...n for a question card; never more keys than the card has options.
    static func question(optionCount: Int) -> [(keyCode: Int, action: ShortcutAction)] {
        (1...9).compactMap { n in
            ShortcutGate.optionIndex(forKey: n, optionCount: optionCount) == nil ? nil : (digits[n - 1], ShortcutAction.option(n))
        }
    }
}

/// Carbon RegisterEventHotKey: system-wide, needs no Accessibility, and swallows the key.
@MainActor
final class HotKeys {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: ShortcutAction] = [:]
    private var handler: EventHandlerRef?
    private var nextId: UInt32 = 1
    var onAction: ((ShortcutAction) -> Void)?

    private static let signature: OSType = 0x4348_5059 // 'CHPY'

    /// True when every key registered.
    @discardableResult
    func register(_ set: [(keyCode: Int, action: ShortcutAction)]) -> Bool {
        unregister()
        var all = true
        installHandlerIfNeeded()
        for item in set {
            let id = nextId; nextId += 1
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(UInt32(item.keyCode), UInt32(controlKey | optionKey), hkID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[id] = ref; actions[id] = item.action }
            else { all = false; Log.hotKeys.error("Chippy: hot key \(item.keyCode) not registered (\(status))") }
        }
        return all
    }

    func unregister() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll(); actions.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { me.fire(id) } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func fire(_ id: UInt32) {
        if let a = actions[id] { onAction?(a) }
    }
}
