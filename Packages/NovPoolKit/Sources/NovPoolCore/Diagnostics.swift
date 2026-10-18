import Foundation

/// The exit through which the library layer forwards diagnostic information to the host application.
///
/// Each Kit module cannot directly depend on the app target's logging implementation, so a sink that can be injected is left here.
/// When the application starts, connect it to its own log file.
public enum NovPoolDiagnostics {
    /// Set it once at application startup. Use `nonisolated(unsafe)` because it only writes during the startup phase,
    /// Afterwards, it is only read.
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)?

    public static func log(_ message: String) {
        sink?(message)
    }
}
