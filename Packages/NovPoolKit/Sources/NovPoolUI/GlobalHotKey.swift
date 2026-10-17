import Carbon.HIToolbox
import Foundation

/// 全局快捷键注册（Carbon `RegisterEventHotKey`）。
///
/// 与 `NSEvent.addGlobalMonitorForEvents` 的区别：本方式只登记热键、不监听全局键盘输入，
/// **不需要辅助功能授权**，也不会看到用户在别的应用里敲了什么。
@MainActor
public final class GlobalHotKey {
    /// 用普通类持有 Carbon 句柄：`deinit` 需要能安全释放它们，
    /// 而 @MainActor 类的 deinit 是 nonisolated，不能碰隔离状态里的非 Sendable 指针。
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
            // 例如组合已被其他应用占用；此时不注册，但不要把整个应用拖垮。
            if let handlerRef = registration.handlerRef { RemoveEventHandler(handlerRef) }
            registration.handlerRef = nil
            return nil
        }
    }

    /// Carbon 事件回调在主线程的主 RunLoop 上派发。
    ///
    /// 这里用 `Task { @MainActor }` 跳一次而不是 `MainActor.assumeIsolated`：
    /// 后者（以及所有隐式隔离检查）会在运行时调用 `swift_task_isCurrentExecutor…`，
    /// 而该函数在真实 app 环境中出现过 `EXC_BAD_ACCESS`。跳一次代价是一次 RunLoop 派发，
    /// 对快捷键响应无可感知影响。
    nonisolated fileprivate func fire() {
        Task { @MainActor in onPress() }
    }
}

/// 必须是全局函数（不能捕获上下文）才能作为 Carbon 的 C 回调。
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
