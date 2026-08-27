@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Speech

struct CoreAudioError: Error, CustomStringConvertible {
    let code: OSStatus
    let op: String
    var description: String { "CoreAudio error (\(op)): \(code)" }
}

/// Captures system audio — what other apps are playing, such as remote
/// participants in an online meeting — with a Core Audio process tap, converts
/// it to the analyzer's format, and hands AnalyzerInput to the callback.
///
/// Uses the system-audio-recording TCC permission
/// (NSAudioCaptureUsageDescription), not Screen Recording: ScreenCaptureKit
/// would force a screen-capture grant even for audio-only use. A process tap
/// has no clock of its own, so it rides a private aggregate device — anchored
/// to the built-in output device (stable clock; a Bluetooth anchor delivers
/// rate-skewed audio that garbles recognition), falling back to the default
/// output on Macs without one.
final class SystemAudioSource: AudioCaptureSource, @unchecked Sendable {
    private let analyzerFormat: AVAudioFormat
    private let onChunk: @Sendable (AVAudioPCMBuffer, UInt64) -> Void
    /// Called once when the default output device changes. The aggregate stays
    /// anchored to the device it was built on and goes silently dead, so the
    /// engine should stop the session instead of appearing to run while
    /// capturing nothing.
    var onDeviceInvalidated: (@Sendable () -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceLostFired = false
    /// Whether the aggregate rides the built-in output (stable, always there)
    /// or, on a Mac without one, whatever the default output was at the time.
    private var anchoredToBuiltIn = true
    /// UID of the device the aggregate was built around. Only meaningful in
    /// the fallback case, where the anchor can be taken away.
    private var anchorUID: String?
    // Runs the IOProc off Core Audio's real-time IO thread; converting and
    // calling back are not safe there.
    private let ioQueue = DispatchQueue(label: "kikiyaku.system-audio")

    init(analyzerFormat: AVAudioFormat, onChunk: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) {
        self.analyzerFormat = analyzerFormat
        self.onChunk = onChunk
    }

    // Safety net for exceptional paths: never leak the tap / aggregate / IOProc
    // if the engine drops the object without stopping it. stop() is idempotent.
    deinit {
        stop()
    }

    func start() throws {
        // Any step past the first allocation can throw; unwind partial
        // allocations before rethrowing so the tap / aggregate never dangle.
        do {
            try startUnchecked()
        } catch {
            stop()
            throw error
        }
    }

    private func startUnchecked() throws {
        // Global system-output tap. kikiyaku never plays audio, so there is
        // nothing of our own to exclude from the mix. Creating the tap triggers
        // the system-audio-recording permission prompt on first use.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard status == noErr else { throw CoreAudioError(code: status, op: "CreateProcessTap") }
        tapID = tap

        // A process tap carries no clock of its own, so it has to ride an
        // aggregate device anchored to a real output device. Anchor to the
        // built-in output when available: the tap mixes all processes' audio
        // regardless of which device they play to, and the anchor only supplies
        // the clock. Anchoring to the default output couples capture to that
        // device's clock — with a Bluetooth output this delivered rate-skewed
        // audio (levels normal, speech recognition garbled) — and goes silently
        // dead when the default changes. The built-in clock is stable and always
        // present. Fall back to the default output on Macs without one.
        let anchoredToBuiltIn: Bool
        let outputUID: String
        if let builtIn = Self.builtInOutputDeviceUID() {
            outputUID = builtIn
            anchoredToBuiltIn = true
        } else {
            outputUID = try Self.defaultOutputDeviceUID()
            anchoredToBuiltIn = false
        }
        self.anchoredToBuiltIn = anchoredToBuiltIn
        self.anchorUID = outputUID
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "kikiyaku-system-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Per the SDK header, with this key AudioDeviceStart waits until a
            // tapped process receives its first audio. It returns promptly all
            // the same — measured within the same second on a quiet machine —
            // so start() does not stall waiting for playback. Requires the
            // private key.
            //
            // What it does NOT mean is that buffers then keep coming. The tap
            // delivers while something is playing and stops when nothing is:
            // starting a session on a silent machine yields no buffer at all
            // until something plays, and buffers cease again when it stops.
            // An earlier note here claimed silent buffers arrive at full rate,
            // and a watchdog built on that reading stopped healthy sessions
            // for the offence of nobody speaking. Anything asking "is this
            // capture alive?" has to ask the device, not the buffer flow.
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else { throw CoreAudioError(code: status, op: "CreateAggregateDevice") }
        aggregateID = aggregate

        var asbd = try Self.tapStreamFormat(tapID)
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: tapFormat, to: analyzerFormat) else {
            throw KikiyakuError.converterUnavailable
        }
        let box = ConverterBox(converter: converter, targetFormat: analyzerFormat)
        let onChunk = self.onChunk

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, ioQueue) { inNow, inInputData, inInputTime, _, _ in
            // The no-copy buffer aliases Core Audio's IO memory; the converter
            // reads it synchronously and writes into a fresh buffer, so no deep
            // copy is needed before handing it downstream.
            guard let aliased = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inInputData),
                  let converted = box.convert(aliased) else { return }
            let input = inInputTime.pointee
            let hostTime = input.mFlags.contains(.hostTimeValid)
                ? input.mHostTime : inNow.pointee.mHostTime
            onChunk(converted, hostTime)
        }
        guard status == noErr, let procID else { throw CoreAudioError(code: status, op: "CreateIOProc") }
        ioProcID = procID

        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else { throw CoreAudioError(code: status, op: "DeviceStart") }

        // With the stable built-in anchor, capture survives default-output
        // changes, so the invalidation watch is only needed in the fallback case
        // (aggregate following the default output).
        if !anchoredToBuiltIn {
            startDeviceListener()
            // The default output is read again now the listener is in place.
            // Reading it, building the aggregate and subscribing are three
            // separate moments, and a change falling between the first and the
            // third is announced to nobody — leaving an aggregate anchored to a
            // device that is no longer the one in use, which delivers nothing
            // and answers every question about itself as healthy.
            if let current = try? Self.defaultOutputDeviceUID(), current != outputUID {
                throw KikiyakuError.captureLostDeviceDuringStart(L("source.system"))
            }
        }
    }

    func stop() {
        stopDeviceListener()
        if let procID = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Whether the private aggregate device still exists.
    ///
    /// Asked of Core Audio rather than inferred from buffer arrivals: the tap
    /// falls silent whenever nothing is playing, and a session must not be
    /// torn down for a quiet room.
    ///
    /// Existence, not activity. kAudioDevicePropertyDeviceIsRunning answers
    /// whether the IOProc is currently running, and with the tap set to start
    /// itself when a tapped process first plays something, that is 0 for as
    /// long as the machine is quiet — which would condemn a perfectly healthy
    /// capture within seconds of starting one.
    var isAlive: Bool {
        // Read without synchronisation, as the rest of this type is: start and
        // stop never overlap (see AudioCaptureSource), and this is only ever
        // asked of a capture the engine has already attached.
        let device = aggregateID
        guard device != AudioObjectID(kAudioObjectUnknown) else { return false }
        // Once the anchor has been reported gone it stays gone. The aggregate
        // outlives it and goes on answering, so without latching, a capture
        // that has already lost its clock would read as healthy again.
        guard !deviceLostFired else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive)
        // An error here means the device is no longer answering — it was
        // destroyed under us, which is the failure this is looking for.
        guard status == noErr else {
            debugLog("aggregate device \(device) will not answer (status \(status))")
            return false
        }
        if alive == 0 {
            debugLog("aggregate device \(device) reports itself not alive")
            return false
        }

        // Existing is not the same as still being connected to the right
        // device. Anchored to the built-in output there is nothing to check —
        // it does not go anywhere. In the fallback case the anchor is whatever
        // the default output happened to be, and when that changes the
        // aggregate keeps its old sub-device: alive, answering, and delivering
        // nothing at all.
        if !anchoredToBuiltIn, let anchorUID {
            guard let current = try? Self.defaultOutputDeviceUID() else {
                debugLog("default output will not answer; treating the anchor as gone")
                return false
            }
            guard current == anchorUID else {
                debugLog("default output moved away from the aggregate's anchor")
                return false
            }
        }
        return true
    }

    // MARK: - Default-output change watch

    private static func defaultOutputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func startDeviceListener() {
        var address = Self.defaultOutputAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // The property can fire more than once for a single switch; coalesce.
            guard let self, !self.deviceLostFired else { return }
            self.deviceLostFired = true
            self.onDeviceInvalidated?()
        }
        deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    private func stopDeviceListener() {
        guard let block = deviceListenerBlock else { return }
        var address = Self.defaultOutputAddress()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        deviceListenerBlock = nil
    }

    // MARK: - Core Audio property helpers

    /// UID of the built-in output device (the preferred, clock-stable anchor),
    /// or nil on Macs without one. The built-in *mic* is also transport-type
    /// built-in, so require output streams.
    private static func builtInOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }

        for device in devices {
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                device, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                transport == kAudioDeviceTransportTypeBuiltIn else { continue }

            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                device, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { continue }

            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(
                device, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr, let uidRef else { continue }
            return uidRef.takeRetainedValue() as String
        }
        return nil
    }

    /// UID of the current default output device (the fallback anchor).
    private static func defaultOutputDeviceUID() throws -> String {
        var address = defaultOutputAddress()
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { throw CoreAudioError(code: status, op: "DefaultOutputDevice") }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &size, &uidRef)
        guard status == noErr, let uidRef else { throw CoreAudioError(code: status, op: "OutputDeviceUID") }
        return uidRef.takeRetainedValue() as String
    }

    /// Stream format the tap delivers, read from the tap object itself.
    private static func tapStreamFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw CoreAudioError(code: status, op: "TapFormat") }
        return asbd
    }
}
