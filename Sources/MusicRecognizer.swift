import AVFoundation
import Foundation

struct RecognizedTrack: Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
}

enum RecognitionReason: String, Sendable {
    case startup = "startup"
    case startupRetry = "startup-retry"
    case transition = "transition"
    case periodic = "periodic"
    case acceleratedPeriodic = "accelerated-periodic"
    case suspicion = "suspicion"
}

final class MusicRecognizer {

    private struct BufferEntry {
        let buffer: AVAudioPCMBuffer
        let frameCount: Int
    }

    private let sampleRate: Double = 44100
    private let maxBufferedSeconds: Double = 10
    private let defaultWindowSeconds: Double = 10
    private let transitionWindowSeconds: Double = 8
    private let defaultMinBufferedSeconds: Double = 8
    private let transitionMinBufferedSeconds: Double = 6
    private let scriptPath: String
    private let recognitionTimeout: TimeInterval = 20

    private let bufferQueue = DispatchQueue(label: "overheard.recognizer-buffer")
    private var ringBuffer: [BufferEntry] = []
    private var totalFrames: Int = 0

    private var maxFrames: Int { Int(maxBufferedSeconds * sampleRate) }

    init() {
        let bundle = Bundle.main.bundlePath
        let dir = URL(fileURLWithPath: bundle).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let candidate = dir + "/recognize.py"
        if FileManager.default.fileExists(atPath: candidate) {
            scriptPath = candidate
        } else {
            scriptPath = FileManager.default.currentDirectoryPath + "/recognize.py"
        }
    }

    func addBuffer(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        bufferQueue.sync {
            ringBuffer.append(BufferEntry(buffer: buffer, frameCount: frames))
            totalFrames += frames

            while totalFrames > maxFrames, !ringBuffer.isEmpty {
                let removed = ringBuffer.removeFirst()
                totalFrames -= removed.frameCount
            }
        }
    }

    func recognize(reason: RecognitionReason) async -> RecognizedTrack? {
        let snapshot: (entries: [BufferEntry], totalFrames: Int) = bufferQueue.sync {
            (entries: ringBuffer, totalFrames: totalFrames)
        }

        let minimumBufferedSeconds = minBufferedSeconds(for: reason)
        let minimumFrames = Int(minimumBufferedSeconds * sampleRate)
        let recognitionWindowSeconds = windowSeconds(for: reason)
        let tailFrames = min(snapshot.totalFrames, Int(recognitionWindowSeconds * sampleRate))

        let bufferedSeconds = Double(snapshot.totalFrames) / sampleRate
        let windowedSeconds = Double(tailFrames) / sampleRate
        logDebug("recognizer: recognize(\(reason.rawValue)) called — \(snapshot.totalFrames) frames (\(String(format: "%.1f", bufferedSeconds))s buffered), window=\(String(format: "%.1f", windowedSeconds))s")

        guard snapshot.totalFrames >= minimumFrames else {
            logDebug("recognizer: not enough audio for \(reason.rawValue) (\(String(format: "%.1f", bufferedSeconds))s < \(String(format: "%.1f", minimumBufferedSeconds))s)")
            return nil
        }

        guard let concatenated = concatenateTailBuffers(
            entries: snapshot.entries,
            totalFrames: snapshot.totalFrames,
            tailFrames: tailFrames
        ) else {
            return nil
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("overheard-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        do {
            let audioFile = try AVAudioFile(
                forWriting: tempFile,
                settings: concatenated.format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try audioFile.write(from: concatenated)
        } catch {
            logError("Failed to write temp audio: \(error.localizedDescription)")
            return nil
        }

        logDebug("recognizer: wrote temp WAV to \(tempFile.path) (\(reason.rawValue))")
        return await runRecognition(audioPath: tempFile.path, reason: reason)
    }

    private func runRecognition(audioPath: String, reason: RecognitionReason) async -> RecognizedTrack? {
        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["uv", "run", scriptPath, audioPath]
        process.standardOutput = pipe
        process.standardError = errPipe

        logDebug("recognizer: running uv run \(scriptPath) \(audioPath) (\(reason.rawValue))")

        let timeout = recognitionTimeout

        return await withCheckedContinuation { continuation in
            let gate = ResumeGate(continuation: continuation)

            process.terminationHandler = { _ in
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !errStr.isEmpty {
                    logError("recognize.py stderr: \(errStr)")
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let stdout = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !stdout.isEmpty {
                    logDebug("recognizer: stdout: \(stdout)")
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["match"] as? Bool == true else {
                    gate.resume(with: nil)
                    return
                }

                let title = (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let artist = (json["artist"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                guard !title.isEmpty, !artist.isEmpty else {
                    gate.resume(with: nil)
                    return
                }

                let album = json["album"] as? String
                let cleanAlbum = (album?.isEmpty == true) ? nil : album

                gate.resume(with: RecognizedTrack(
                    title: title,
                    artist: artist,
                    album: cleanAlbum,
                    duration: nil
                ))
            }

            do {
                try process.run()
            } catch {
                logError("Failed to run recognition: \(error.localizedDescription)")
                gate.resume(with: nil)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                logError("Recognition timed out after \(Int(timeout))s, terminating")
                process.terminate()
                gate.resume(with: nil)
            }
        }
    }

    private func windowSeconds(for reason: RecognitionReason) -> Double {
        switch reason {
        case .transition, .suspicion:
            return transitionWindowSeconds
        case .startup, .startupRetry, .periodic, .acceleratedPeriodic:
            return defaultWindowSeconds
        }
    }

    private func minBufferedSeconds(for reason: RecognitionReason) -> Double {
        switch reason {
        case .transition, .suspicion:
            return transitionMinBufferedSeconds
        case .startup, .startupRetry, .periodic, .acceleratedPeriodic:
            return defaultMinBufferedSeconds
        }
    }

    private final class ResumeGate<T: Sendable>: @unchecked Sendable {
        private let queue = DispatchQueue(label: "overheard.resume-gate")
        private var resumed = false
        private let continuation: CheckedContinuation<T, Never>

        init(continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }

        func resume(with value: T) {
            queue.sync {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
        }
    }

    private func concatenateTailBuffers(entries: [BufferEntry], totalFrames: Int, tailFrames: Int) -> AVAudioPCMBuffer? {
        guard !entries.isEmpty else { return nil }
        guard tailFrames > 0 else { return nil }

        guard let firstFormat = entries.first?.buffer.format else { return nil }

        let capacity = AVAudioFrameCount(tailFrames)
        guard let output = AVAudioPCMBuffer(pcmFormat: firstFormat, frameCapacity: capacity) else {
            return nil
        }

        guard let dstChannels = output.floatChannelData else { return nil }
        let channelCount = Int(firstFormat.channelCount)

        let startFrame = max(0, totalFrames - tailFrames)
        var sourceCursor = 0
        var offset = 0

        for entry in entries {
            guard let srcChannels = entry.buffer.floatChannelData else { continue }
            let frames = entry.frameCount
            let entryStart = sourceCursor
            let entryEnd = sourceCursor + frames
            sourceCursor = entryEnd

            let copyStart = max(entryStart, startFrame)
            let copyEnd = min(entryEnd, totalFrames)
            let copyCount = copyEnd - copyStart
            guard copyCount > 0 else { continue }

            let sourceOffset = copyStart - entryStart

            for ch in 0..<channelCount {
                let dst = dstChannels[ch].advanced(by: offset)
                let src = srcChannels[ch].advanced(by: sourceOffset)
                dst.update(from: src, count: copyCount)
            }

            offset += copyCount
            if offset >= tailFrames {
                break
            }
        }

        output.frameLength = AVAudioFrameCount(offset)
        return output
    }
}
