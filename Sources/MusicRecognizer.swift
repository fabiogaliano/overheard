import ShazamKit
import AVFoundation

struct RecognizedTrack: Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
}

final class MusicRecognizer {

    private struct BufferEntry {
        let buffer: AVAudioPCMBuffer
        let frameCount: Int
    }

    private let sampleRate: Double = 44100
    private let maxBufferedSeconds: Double = 10
    private let minBufferedSeconds: Double = 5

    private var ringBuffer: [BufferEntry] = []
    private var totalFrames: Int = 0

    private var maxFrames: Int { Int(maxBufferedSeconds * sampleRate) }
    private var minFrames: Int { Int(minBufferedSeconds * sampleRate) }

    func addBuffer(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        ringBuffer.append(BufferEntry(buffer: buffer, frameCount: frames))
        totalFrames += frames

        while totalFrames > maxFrames, !ringBuffer.isEmpty {
            let removed = ringBuffer.removeFirst()
            totalFrames -= removed.frameCount
        }
    }

    func recognize() async -> RecognizedTrack? {
        guard totalFrames >= minFrames else { return nil }

        guard let concatenated = concatenateBuffers() else { return nil }

        let generator = SHSignatureGenerator()
        do {
            try generator.append(concatenated, at: nil)
        } catch {
            logError("Failed to append audio to signature generator: \(error.localizedDescription)")
            return nil
        }

        let signature = generator.signature()
        let session = SHSession()

        let result = await session.result(from: signature)

        switch result {
        case .match(let match):
            guard let item = match.mediaItems.first else { return nil }

            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = (item.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            guard !title.isEmpty, !artist.isEmpty else { return nil }

            let album = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanAlbum = (album?.isEmpty == true) ? nil : album

            let duration: TimeInterval? = if let raw = item[.timeRanges] as? [Range<TimeInterval>],
                                             let range = raw.last {
                range.upperBound
            } else {
                nil
            }

            return RecognizedTrack(
                title: title,
                artist: artist,
                album: cleanAlbum,
                duration: duration
            )

        case .noMatch:
            return nil

        case .error(let error, _):
            logError("Shazam recognition error: \(error.localizedDescription)")
            return nil

        @unknown default:
            return nil
        }
    }

    private func concatenateBuffers() -> AVAudioPCMBuffer? {
        guard !ringBuffer.isEmpty else { return nil }

        guard let firstFormat = ringBuffer.first?.buffer.format else { return nil }

        let capacity = AVAudioFrameCount(totalFrames)
        guard let output = AVAudioPCMBuffer(pcmFormat: firstFormat, frameCapacity: capacity) else {
            return nil
        }

        guard let dstChannels = output.floatChannelData else { return nil }
        let channelCount = Int(firstFormat.channelCount)
        var offset = 0

        for entry in ringBuffer {
            guard let srcChannels = entry.buffer.floatChannelData else { continue }
            let frames = entry.frameCount

            for ch in 0..<channelCount {
                let dst = dstChannels[ch].advanced(by: offset)
                let src = srcChannels[ch]
                dst.update(from: src, count: frames)
            }

            offset += frames
        }

        output.frameLength = AVAudioFrameCount(offset)
        return output
    }
}
