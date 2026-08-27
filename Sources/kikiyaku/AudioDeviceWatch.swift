import CoreAudio
import Foundation

/// Records changes to the machine's audio device line-up while a session runs.
///
/// Rearranging the devices — a USB switch handing a microphone to another
/// computer and back, earphones connecting — has been seen to leave capture
/// alive but silent. The watchdog in Engine notices the silence; this says what
/// happened just before it, which is the part that identifies the cause.
///
/// Only the transport kinds and how many of each are recorded. Device names are
/// deliberately left out: they routinely carry their owner's name, and the
/// count is what the timeline needs.
@MainActor
enum AudioDeviceWatch {
    private static var listener: AudioObjectPropertyListenerBlock?
    private static var previous: [String: Int] = [:]

    static func start() {
        guard debugLoggingEnabled, listener == nil else { return }
        previous = census()
        debugLog("audio devices at start: %@", describe(previous))

        var address = devicesAddress()
        // Registered against the main queue, so the state above is reached
        // from the actor that owns it.
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated {
                let now = census()
                defer { previous = now }
                guard now != previous else { return }
                debugLog("audio devices changed: %@ -> %@", describe(previous), describe(now))
            }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    static func stop() {
        guard let block = listener else { return }
        var address = devicesAddress()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        listener = nil
        previous = [:]
    }

    private static func devicesAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// How many devices of each transport kind the machine currently has.
    private static func census() -> [String: Int] {
        var address = devicesAddress()
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return [:] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [:] }

        var tally: [String: Int] = [:]
        for id in ids {
            tally[transportName(of: id), default: 0] += 1
        }
        return tally
    }

    private static func transportName(of device: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return "unknown"
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "builtin"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity"
        default: return "other"
        }
    }

    private static func describe(_ tally: [String: Int]) -> String {
        let total = tally.values.reduce(0, +)
        let parts = tally.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        return "\(total) (" + parts.joined(separator: ", ") + ")"
    }
}
