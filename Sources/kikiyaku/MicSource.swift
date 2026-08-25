@preconcurrency import AVFoundation
import Speech

/// A capture source that feeds converted AnalyzerInput chunks to the engine.
/// start() runs off the MainActor (Core Audio setup is blocking IPC with
/// coreaudiod); stop() is called from the MainActor. The engine never overlaps
/// the two.
protocol AudioCaptureSource: Sendable {
    func start() throws
    func stop()
}

/// Captures the microphone, converts buffers to the analyzer's format, and hands
/// AnalyzerInput to the callback. The tap callback runs on a Core Audio thread.
/// @unchecked: start/stop are serialized by the engine (see AudioCaptureSource).
///
/// The callback also receives the buffer's mach hostTime so the engine can
/// anchor this channel's audio timeline to the session-wide clock (each
/// channel's analyzer keeps its own timeline; hostTime is the common ruler).
final class MicSource: AudioCaptureSource, @unchecked Sendable {
    private let engine = AVAudioEngine()

    init(analyzerFormat: AVAudioFormat, onChunk: @escaping @Sendable (AnalyzerInput, UInt64) -> Void) throws {
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
            throw KikiyakuError.converterUnavailable
        }
        let box = ConverterBox(converter: converter, targetFormat: analyzerFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, when in
            if let converted = box.convert(buffer) {
                onChunk(AnalyzerInput(buffer: converted), when.hostTime)
            }
        }
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// AVAudioConverter is not Sendable, but each box instance is only ever touched
/// from a single capture callback context (the mic tap thread, or the system
/// tap's serial IO queue), so @unchecked is safe here.
final class ConverterBox: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat

    init(converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        self.converter = converter
        self.targetFormat = targetFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        // The input block is only ever called synchronously from inside convert(),
        // so the Sendable warning does not match reality; opt out explicitly.
        nonisolated(unsafe) var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
