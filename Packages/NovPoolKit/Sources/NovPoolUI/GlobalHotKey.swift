import Carbon.HIToolbox
import Foundation

/// Global hotkey registration (Carbon `RegisterEventHotKey`).
///
/// Difference from `NSEvent.addGlobalMonitorForEvents`: This method only registers hotkeys and does not monitor global keyboard input.
/// **No accessibility permission required**, and it also won't see what the user types in other apps.
@MainActor
public final class GlobalHotKey {
    /// Holding Carbon handles with ordinary classes: `deinit` needs to be able to safely release them,
    /// And the deinit of the @MainActor class is nonisolated, so it cannot touch non-Sendable pointers in the isolated state.
    private final class Registration {
        var hotKeyRef: EventHotKeyRef?
        var handlerRef: EventHandlerRef?

        deinit {
            if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
            if let handlerRef { RemoveEventHandler(handlerRef) }
        }
    }

    private let registration = Registration()
    private let onPress: @MainActor () -> Void

    public init?(spec: HotKeySpec, onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyCallback,
            1,
            &eventType,
            userData,
            &registration.handlerRef
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E_56_50_4C), id: 1) // 'NVPL'
        let registerStatus = RegisterEventHotKey(
            spec.keyCode,
            spec.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registration.hotKeyRef
        )
        guard registerStatus == noErr, registration.hotKeyRef != nil else {
            // For example, if a combination has already been taken by another application; in this case, do not register it, but do not let it bring down the entire application.
            if let handlerRef = registration.handlerRef { RemoveEventHandler(handlerRef) }
            registration.handlerRef = nil
            return nil
        }
    }

    /// Carbon event callbacks are dispatched on the main thread's main RunLoop.
    ///
    /// Here we use `Task { @MainActor }` to jump once instead of `MainActor.assumeIsolated`:
    /// The latter (as well as all implicit isolation checks) will call `swift_task_isCurrentExecutor…` at runtime,
    /// And this function has triggered `EXC_BAD_ACCESS` in a real app environment. The cost of one occurrence is one RunLoop dispatch,
    /// No perceptible impact on the response of shortcut keys.
    nonisolated fileprivate func fire() {
        Task { @MainActor in onPress() }
    }
}

/// It must be a global function (cannot capture context) in order to be used as a C callback for Carbon.
private func globalHotKeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    hotKey.fire()
    return noErr
}
