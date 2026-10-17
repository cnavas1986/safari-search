//
//  HotKey.swift
//  Tab Search
//
//  A system-wide keyboard shortcut via Carbon's RegisterEventHotKey, which
//  needs no Accessibility permission. While registered, the shortcut is taken
//  from every other app, so callers enable it only when it should apply.
//

import Carbon.HIToolbox

final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var ref: EventHotKeyRef?

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? register() : unregister()
        }
    }

    /// `keyCode` is a kVK_* constant, `modifiers` a mask of cmdKey, shiftKey, ...
    init(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        self.id = HotKey.nextID
        HotKey.nextID += 1
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        HotKey.handlers[id] = handler
        HotKey.installHandlerIfNeeded()
    }

    deinit {
        unregister()
        HotKey.handlers[id] = nil
    }

    private func register() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5462_5372) /* 'TbSr' */, id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
