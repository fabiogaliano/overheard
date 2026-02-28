import ScreenCaptureKit
import AVFoundation
import CoreMedia

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    nonisolated(unsafe) var onAudioBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    private let audioQueue = DispatchQueue(label: "radio-scrobbler.audio-capture", qos: .userInteractive)
    private var stream: SCStream?
    private var retryCount = 0
    private let maxRetries = 3

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch let error as SCStreamError where error.code == .userDeclined {
            logError("Screen recording permission denied.")
            logError("Grant access in: System Settings > Privacy & Security > Screen Recording")
            exit(1)
        } catch {
            throw error
        }

        guard let display = content.displays.first else {
            logError("No display found for audio capture.")
            exit(1)
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 44100
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        do {
            try await scStream.startCapture()
        } catch let error as SCStreamError where error.code == .userDeclined {
            logError("Screen recording permission denied.")
            logError("Grant access in: System Settings > Privacy & Security > Screen Recording")
            exit(1)
        }

        stream = scStream
        retryCount = 0
    }

    func stop() {
        guard let scStream = stream else { return }
        stream = nil
        scStream.stopCapture { error in
            if let error {
                logError("Failed to stop audio capture: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        guard let audioFormat = AVAudioFormat(streamDescription: asbd) else { return }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return }

        guard let srcData = audioBufferList.mBuffers.mData,
              let dstData = pcmBuffer.floatChannelData else {
            return
        }

        let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)
        memcpy(dstData[0], srcData, byteCount)

        let audioTime = AVAudioTime(sampleTime: 0, atRate: asbd.pointee.mSampleRate)
        onAudioBuffer?(pcmBuffer, audioTime)
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logError("Audio capture stream stopped: \(error.localizedDescription)")
        attemptRestart()
    }

    private nonisolated func attemptRestart() {
        let currentRetry: Int = audioQueue.sync {
            let count = retryCount
            retryCount = count + 1
            return count
        }

        guard currentRetry < maxRetries else {
            logError("Audio capture failed after \(maxRetries) restart attempts. Giving up.")
            return
        }

        let delay = pow(2.0, Double(currentRetry))
        logError("Restarting audio capture in \(Int(delay))s (attempt \(currentRetry + 1)/\(maxRetries))...")

        audioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.start()
                } catch {
                    logError("Audio capture restart failed: \(error.localizedDescription)")
                    self.attemptRestart()
                }
            }
        }
    }
}
