import Carbon.HIToolbox
import Foundation

/// A system-wide hot key through Carbon, which needs no extra permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var action: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ preset: HotKeyPreset) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5841_4231), id: 1) // "XAB1"
        RegisterEventHotKey(UInt32(preset.keyCode), UInt32(preset.carbonModifiers), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    fileprivate func fire() { action?() }
}

private nonisolated func hotKeyHandler(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    Task { @MainActor in HotKeyCenter.shared.fire() }
    return noErr
}
