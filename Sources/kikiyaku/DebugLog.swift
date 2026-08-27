import Foundation

/// Diagnostics for faults that only appear on someone else's machine — a
/// capture that dies when the audio devices are rearranged, say, which has
/// resisted reproduction here. Compiled in only when the build asks for it:
///
///     KIKIYAKU_DEBUG_LOG=1 ./scripts/build.sh
///
/// Read the result with:
///
///     log show --predicate 'process == "kikiyaku"' --last 1h
///
/// Nothing here may carry what was said. NSLog reaches the unified log, which
/// anyone on the machine can read and which a sysdiagnose carries off it, so
/// these lines stay with counts, kinds and timings — never recognized text, and
/// never a device name, which routinely holds its owner's own name.
@inline(__always)
func debugLog(_ format: String, _ args: CVarArg...) {
    #if KIKIYAKU_DEBUG_LOG
    withVaList(args) { NSLogv("kikiyaku[debug]: " + format, $0) }
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
