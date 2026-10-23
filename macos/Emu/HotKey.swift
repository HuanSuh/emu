// A global shortcut (⌥⌘E) through Carbon's RegisterEventHotKey — works
// without the Accessibility permission an event tap would need.
import Carbon
import Cocoa

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// [keyCode] is a virtual key (kVK_ANSI_E), [modifiers] Carbon flags.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data = data else { return noErr }
            Unmanaged<HotKey>.fromOpaque(data).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, me, &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x656D_7521), id: 1) // 'emu!'
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let h = handler { RemoveEventHandler(h) }
            return nil
        }
    }

    deinit {
        if let r = ref { UnregisterEventHotKey(r) }
        if let h = handler { RemoveEventHandler(h) }
    }
}
