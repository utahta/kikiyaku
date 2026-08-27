import AVFoundation
import CoreMedia
import Foundation
import Speech

/// mach ticks → seconds, against the timebase this machine counts them in.
let machSecondsPerTick: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1_000_000_000
}()

/// Which capture generation a channel is currently listening to.
///
/// A capture that has been replaced can still have callbacks in flight — a
/// Core Audio IO thread mid-buffer, a tap block already scheduled. Those
/// buffers belong to a device the channel has given up on: fed to the analyzer
/// they would interleave with the new capture's audio, and counted as arrivals
/// they would report a dead capture as recovered. Each capture carries the
/// generation it was made for, and stops being heard the moment that changes.
/// The arrival record lives here rather than beside the epoch, because it has
/// to be written under the same lock that decides whether the caller is still
/// the current capture. Checked and then written separately, a retirement
/// landing in between would let a dead capture's buffer stamp the record — and
/// a rebuild waiting for its first buffer would read that as having succeeded.
final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var lastArrival: SuspendingClock.Instant?

    /// Stops every existing capture being heard, without making a new one yet.
    /// Called before the old capture is told to stop, so that a buffer already
    /// on its way cannot land in the window between the two. The arrival record
    /// goes with it: it described a capture that is no longer listened to.
    func retire() {
        lock.lock()
        current += 1
        lastArrival = nil
        lock.unlock()
    }

    /// Retires every existing capture and returns the generation the next one
    /// should carry.
    func nextGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        current += 1
        lastArrival = nil
        return current
    }

    /// Records an arrival from `generation` and runs `deliver` — both while
    /// holding the lock, so a retirement cannot slip between the check and
    /// either of them. Returns false, having done nothing, once the generation
    /// has been retired.
    @discardableResult
    func accept(generation: Int, deliver: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == current else { return false }
        lastArrival = SuspendingClock.now
        deliver()
        return true
    }

    /// When the current generation last delivered. Cleared by a retirement, so
    /// this never speaks for a capture that has been replaced.
    var lastArrivalAt: SuspendingClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        return lastArrival
    }
}

/// Everything that happens to a captured buffer between the audio thread and
/// the analyzer: the generation check, the arrival record the watchdog reads,
/// and the timeline position the analyzer is told about.
///
/// One feed per capture, so the generation is fixed at construction.
final class CaptureFeed: @unchecked Sendable {
    private let epoch: EpochBox
    private let gate: CaptureGate
    private let generation: Int
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var announcesStartTime: Bool

    /// - Parameter resuming: whether this feed follows a capture that died. The
    ///   analyzer's timeline advances by the audio it is given, so audio that
    ///   never arrived is time it never counted; left to infer the position
    ///   itself it would splice the resumed audio onto the moment the old
    ///   capture stopped, and every utterance from here on would carry a time
    ///   short by the length of the outage. The first buffer after a rebuild
    ///   therefore states where it belongs.
    init(epoch: EpochBox,
         gate: CaptureGate,
         generation: Int,
         continuation: AsyncStream<AnalyzerInput>.Continuation,
         resuming: Bool) {
        self.epoch = epoch
        self.gate = gate
        self.generation = generation
        self.continuation = continuation
        self.announcesStartTime = resuming
    }

    /// Called from the capture's audio thread.
    func accept(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        // The epoch is the hostTime the analyzer's timeline counts zero from,
        // and it is set by the session's first buffer — never by a rebuild's,
        // which would move the origin every time a session survived an outage.
        let firstHostTime = epoch.value

        var startTime: CMTime?
        lock.lock()
        if announcesStartTime {
            if let firstHostTime, hostTime > firstHostTime {
                let elapsed = Double(hostTime - firstHostTime) * machSecondsPerTick
                startTime = CMTime(seconds: elapsed, preferredTimescale: 48_000)
                announcesStartTime = false
            } else if firstHostTime != nil {
                // A hostTime at or before the epoch cannot place the buffer;
                // let the analyzer carry on from where it was rather than
                // claim a position that would be wrong.
                announcesStartTime = false
            }
            // With no epoch yet this is the session's first buffer after all —
            // there is no outage to describe, and it starts the timeline.
        }
        lock.unlock()

        // Recording the arrival and handing the audio on happen together,
        // under the generation check: a capture retired a moment ago must
        // neither report itself alive nor put its audio in front of the
        // analyzer the replacement is feeding.
        gate.accept(generation: generation) {
            epoch.noteBuffer(hostTime: hostTime)
            continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: startTime))
        }
    }
}
