import AppKit
import Carbon.HIToolbox

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case ctrlOptSpace = "ctrl-opt-space"
    case optSpace = "opt-space"
    case cmdShiftSpace = "cmd-shift-space"
    case ctrlOptO = "ctrl-opt-o"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ctrlOptSpace: "⌃⌥ Space"
        case .optSpace: "⌥ Space"
        case .cmdShiftSpace: "⌘⇧ Space"
        case .ctrlOptO: "⌃⌥ O"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .ctrlOptSpace, .optSpace, .cmdShiftSpace: UInt32(kVK_Space)
        case .ctrlOptO: UInt32(kVK_ANSI_O)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .ctrlOptSpace: UInt32(controlKey | optionKey)
        case .optSpace: UInt32(optionKey)
        case .cmdShiftSpace: UInt32(cmdKey | shiftKey)
        case .ctrlOptO: UInt32(controlKey | optionKey)
        }
    }
}

final class HotKeyManager {
    var callback: () -> Void = {}
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(_ preset: HotKeyPreset) {
        unregister()

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.callback() }
            return noErr
        }, 1, &eventSpec, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: 0x504F_504E /* "POPN" */, id: 1)
        RegisterEventHotKey(preset.keyCode, preset.modifiers, hotKeyID,
                            GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = handlerRef {
            RemoveEventHandler(ref)
            handlerRef = nil
        }
    }

    deinit { unregister() }
}
