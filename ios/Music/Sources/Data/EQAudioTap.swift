import AVFoundation
import Foundation
import MediaToolbox

/// Client storage for one processing tap: the DSP state plus the parameter source it
/// reads from. Retained by the tap, released in `finalize`.
private final class EQTapBox {
    let processor: EQAudioProcessor
    let source: EQParameterSource

    init(source: EQParameterSource) {
        self.processor = EQAudioProcessor()
        self.source = source
    }
}

// MARK: - MediaToolbox callbacks (file-scope C functions; they cannot capture context)

private func eqTapInit(tap: MTAudioProcessingTap,
                       clientInfo: UnsafeMutableRawPointer?,
                       tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo
}

private func eqTapBox(_ tap: MTAudioProcessingTap) -> EQTapBox {
    Unmanaged<EQTapBox>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private func eqTapFinalize(tap: MTAudioProcessingTap) {
    Unmanaged<EQTapBox>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func eqTapPrepare(tap: MTAudioProcessingTap,
                          maxFrames: CMItemCount,
                          processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    let box = eqTapBox(tap)
    guard let format = AVAudioFormat(streamDescription: processingFormat) else { return }
    box.processor.prepare(format: format, source: box.source)
    let description = processingFormat.pointee
    NSLog("EQ: tap prepared — %.0f Hz, %u ch, %u bits, float=%@",
          description.mSampleRate, description.mChannelsPerFrame, description.mBitsPerChannel,
          (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? "yes" : "no")
    // Report the rate the filters actually run at, not the rate we hoped for.
    AudioPathMonitor.shared.updateProcessing(TapFormatSummary.from(description))
}

private func eqTapUnprepare(tap: MTAudioProcessingTap) {
    eqTapBox(tap).processor.unprepare()
    AudioPathMonitor.shared.updateProcessing(nil)
}

private func eqTapProcess(tap: MTAudioProcessingTap,
                          numberFrames: CMItemCount,
                          flags: MTAudioProcessingTapFlags,
                          bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                          numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                          flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                    flagsOut, nil, numberFramesOut)
    // On failure the buffer is not ours to touch; leave it exactly as AVFoundation left it.
    guard status == noErr else { return }
    eqTapBox(tap).processor.process(buffers: bufferListInOut, frameCount: Int(numberFramesOut.pointee))
}

// MARK: - Mix construction

enum EQAudioMixFactory {
    /// Builds an audio mix whose post-effects tap applies the current EQ chain to
    /// `track`. Returns `nil` when no tap could be created, so the item plays
    /// unprocessed rather than failing.
    static func makeAudioMix(for track: AVAssetTrack, source: EQParameterSource) -> AVAudioMix? {
        guard track.mediaType == .audio else { return nil }

        let box = EQTapBox(source: source)
        let clientInfo = Unmanaged.passRetained(box).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: eqTapInit,
            finalize: eqTapFinalize,
            prepare: eqTapPrepare,
            unprepare: eqTapUnprepare,
            process: eqTapProcess
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let created = tap else {
            // Balance the retain taken above; `finalize` will never run.
            Unmanaged<EQTapBox>.fromOpaque(clientInfo).release()
            NSLog("EQAudioMixFactory: MTAudioProcessingTapCreate failed (\(status))")
            return nil
        }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = created
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}
