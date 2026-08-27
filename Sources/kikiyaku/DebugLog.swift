import Foundation
import os

/// Diagnostics for faults that only appear on someone else's machine — a
/// capture that dies when the audio devices are rearranged, say, which has
/// resisted reproduction here. Compiled in only when the build asks for it:
///
///     KIKIYAKU_DEBUG_LOG=1 ./scripts/build.sh
///
/// Read the result with:
///
///     log show --predicate 'subsystem == "com.utahta.kikiyaku"' --last 1h
///
/// Marked public, without which the unified log redacts every interpolated
/// value as `<private>` and the line says nothing it was written to say. That
/// redaction is a privacy default worth respecting, which is why nothing here
/// may carry what was said: these lines hold counts, kinds and timings — never
/// recognized text, and never a device name, which routinely holds its owner's
/// own name.
private let debugLogger = Logger(subsystem: "com.utahta.kikiyaku", category: "diagnostics")

@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if KIKIYAKU_DEBUG_LOG
    let text = message()
    debugLogger.notice("\(text, privacy: .public)")
    #endif
}

/// Whether this build carries the diagnostics above, for the one line that says
/// so at startup — otherwise a log that stays empty is indistinguishable from a
/// build that was never going to write to it.
var debugLoggingEnabled: Bool {
    #if KIKIYAKU_DEBUG_LOG
    true
    #else
    false
    #endif
}
