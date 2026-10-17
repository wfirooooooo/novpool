import Foundation

/// 库层向宿主应用转发诊断信息的出口。
///
/// 各个 Kit 模块不能直接依赖 app target 的日志实现，因此这里留一个可注入的 sink；
/// 应用启动时把它接到自己的日志文件上。
public enum NovPoolDiagnostics {
    /// 在应用启动时设置一次。用 `nonisolated(unsafe)` 是因为它只在启动阶段写入、
    /// 之后仅被读取。
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)?

    public static func log(_ message: String) {
        sink?(message)
    }
}
