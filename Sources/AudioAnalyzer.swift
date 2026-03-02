import Accelerate
import AVFoundation

final class AudioAnalyzer {

    nonisolated(unsafe) var onTransitionDetected: (@Sendable () -> Void)?
    nonisolated(unsafe) var onSilenceTimeout: (@Sendable () -> Void)?

    private let fftSize = 4096
    private let sampleRate: Float = 44100.0
    private let halfFFT: Int
    private let log2n: vDSP_Length

    private let window: [Float]
    private let fftSetup: FFTSetup
    private let melFilterbank: [Float]
    private let melFilterRows = 26
    private let dctSize = 32
    private let mfccCount = 13
    private let dct: vDSP.DCT

    private var sampleAccumulator: [Float] = []
    private var previousMagnitudes: [Float]
    private var previousMFCC: [Float]
    private var hasPreviousFrame = false

    private let rollingCapacity = 300
    private var fluxBuffer: [Float] = []
    private var mfccDistBuffer: [Float] = []

    private var frameCounter = 0
    private let evaluationInterval = 10
    private var lastFluxSpikeFrame = -1000
    private var lastMFCCSpikeFrame = -1000
    private var lastTransitionFrame = -1000
    private let debounceFrames = 107
    private let fusionWindowFrames = 30
    private let silenceThreshold: Float = 0.001
    private var consecutiveSilentFrames = 0
    private let silenceTimeoutFrames: Int?
    private var lastDebugLogFrame = 0
    private let debugLogInterval = 54  // ~5s at 44100Hz / 4096 samples per frame

    init(silenceTimeoutSeconds: Double? = 279) {
        halfFFT = fftSize / 2 + 1
        if let seconds = silenceTimeoutSeconds {
            silenceTimeoutFrames = Int(seconds * 44100.0 / 4096.0)
        } else {
            silenceTimeoutFrames = nil
        }
        let n = vDSP_Length(log2(Double(fftSize)))
        log2n = n

        window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningNormalized,
            count: fftSize,
            isHalfWindow: false
        )

        guard let setup = vDSP_create_fftsetup(n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup")
        }
        fftSetup = setup

        melFilterbank = AudioAnalyzer.buildMelFilterbank(
            numFilters: 26,
            fftSize: 4096,
            sampleRate: 44100.0,
            lowFreq: 80.0,
            highFreq: 8000.0
        )

        dct = vDSP.DCT(count: dctSize, transformType: .II)!

        previousMagnitudes = [Float](repeating: 0, count: fftSize / 2 + 1)
        previousMFCC = [Float](repeating: 0, count: 13)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let samples = UnsafeBufferPointer(start: channelData[0], count: count)
        sampleAccumulator.append(contentsOf: samples)

        while sampleAccumulator.count >= fftSize {
            let frame = Array(sampleAccumulator.prefix(fftSize))
            sampleAccumulator.removeFirst(fftSize)
            processFrame(frame)
        }
    }

    private func processFrame(_ frame: [Float]) {
        var windowed = vDSP.multiply(frame, window)

        let rms = computeRMS(windowed)
        let isSilent = rms < silenceThreshold

        if isSilent {
            consecutiveSilentFrames += 1
            if let timeout = silenceTimeoutFrames, consecutiveSilentFrames >= timeout {
                onSilenceTimeout?()
                consecutiveSilentFrames = 0
            }
        } else {
            consecutiveSilentFrames = 0
        }

        let magnitudes = computeMagnitudes(&windowed)

        let flux = computeSpectralFlux(magnitudes)
        let mfccDist = computeMFCCDistance(magnitudes)

        appendToRolling(&fluxBuffer, value: flux)
        appendToRolling(&mfccDistBuffer, value: mfccDist)

        previousMagnitudes = magnitudes
        hasPreviousFrame = true

        frameCounter += 1

        if (frameCounter - lastDebugLogFrame) >= debugLogInterval {
            lastDebugLogFrame = frameCounter
            var fluxMean: Float = 0
            if !fluxBuffer.isEmpty {
                vDSP_meanv(fluxBuffer, 1, &fluxMean, vDSP_Length(fluxBuffer.count))
            }
            logDebug("analyzer: rms=\(String(format: "%.4f", rms)) fluxMean=\(String(format: "%.4f", fluxMean)) silent=\(consecutiveSilentFrames) rolling=\(fluxBuffer.count)/\(rollingCapacity)")
        }

        if frameCounter % evaluationInterval == 0 {
            evaluateTransition(isSilent: isSilent)
        }
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return sqrtf(meanSquare)
    }

    private func computeMagnitudes(_ windowed: inout [Float]) -> [Float] {
        let n = fftSize
        let halfN = n / 2

        var realParts = [Float](repeating: 0, count: halfN)
        var imagParts = [Float](repeating: 0, count: halfN)

        realParts.withUnsafeMutableBufferPointer { realBuf in
            imagParts.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )

                windowed.withUnsafeBytes { rawBuf in
                    let typedPtr = rawBuf.baseAddress!.assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(typedPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        var magnitudes = [Float](repeating: 0, count: halfFFT)

        // DC component
        magnitudes[0] = abs(realParts[0]) / Float(fftSize)
        // Nyquist stored in imag[0] for packed format
        magnitudes[halfN] = abs(imagParts[0]) / Float(fftSize)

        // Remaining bins
        if halfN > 1 {
            var magSquared = [Float](repeating: 0, count: halfN - 1)
            realParts.withUnsafeMutableBufferPointer { realBuf in
                imagParts.withUnsafeMutableBufferPointer { imagBuf in
                    var sc = DSPSplitComplex(
                        realp: realBuf.baseAddress! + 1,
                        imagp: imagBuf.baseAddress! + 1
                    )
                    vDSP_zvmags(&sc, 1, &magSquared, 1, vDSP_Length(halfN - 1))
                }
            }

            let scaleFactor = 1.0 / Float(fftSize)
            for i in 0..<(halfN - 1) {
                magnitudes[i + 1] = sqrtf(magSquared[i]) * scaleFactor
            }
        }

        return magnitudes
    }

    private func computeSpectralFlux(_ magnitudes: [Float]) -> Float {
        guard hasPreviousFrame else { return 0 }

        var diff = [Float](repeating: 0, count: halfFFT)
        vDSP_vsub(previousMagnitudes, 1, magnitudes, 1, &diff, 1, vDSP_Length(halfFFT))

        var zero: Float = 0
        vDSP_vthres(diff, 1, &zero, &diff, 1, vDSP_Length(halfFFT))

        var sum: Float = 0
        vDSP_sve(diff, 1, &sum, vDSP_Length(halfFFT))

        return sum
    }

    private func computeMFCCDistance(_ magnitudes: [Float]) -> Float {
        var melEnergies = [Float](repeating: 0, count: melFilterRows)
        vDSP_mmul(
            melFilterbank, 1,
            magnitudes, 1,
            &melEnergies, 1,
            vDSP_Length(melFilterRows),
            1,
            vDSP_Length(halfFFT)
        )

        let epsilon: Float = 1e-10
        var logMel = melEnergies.map { logf(max($0, epsilon)) }
        logMel.append(contentsOf: [Float](repeating: 0, count: dctSize - melFilterRows))

        var dctOutput = [Float](repeating: 0, count: dctSize)
        dct.transform(logMel, result: &dctOutput)

        let mfcc = Array(dctOutput.prefix(mfccCount))

        guard hasPreviousFrame else {
            previousMFCC = mfcc
            return 0
        }

        var dotProduct: Float = 0
        vDSP_dotpr(mfcc, 1, previousMFCC, 1, &dotProduct, vDSP_Length(mfccCount))

        var normASq: Float = 0
        vDSP_svesq(mfcc, 1, &normASq, vDSP_Length(mfccCount))

        var normBSq: Float = 0
        vDSP_svesq(previousMFCC, 1, &normBSq, vDSP_Length(mfccCount))

        let normProduct = sqrtf(normASq) * sqrtf(normBSq)
        let cosineDistance: Float
        if normProduct > 0 {
            cosineDistance = 1.0 - (dotProduct / normProduct)
        } else {
            cosineDistance = 0
        }

        previousMFCC = mfcc
        return cosineDistance
    }

    private func evaluateTransition(isSilent: Bool) {
        guard fluxBuffer.count >= 10 else { return }
        if isSilent { return }

        let fluxSpiked = checkSpike(fluxBuffer)
        let mfccSpiked = checkSpike(mfccDistBuffer)

        if fluxSpiked {
            lastFluxSpikeFrame = frameCounter
            logDebug("analyzer: flux spike at frame \(frameCounter)")
        }
        if mfccSpiked {
            lastMFCCSpikeFrame = frameCounter
            logDebug("analyzer: mfcc spike at frame \(frameCounter)")
        }

        let bothSpikedRecently =
            abs(lastFluxSpikeFrame - lastMFCCSpikeFrame) <= fusionWindowFrames
            && lastFluxSpikeFrame > lastTransitionFrame
            && lastMFCCSpikeFrame > lastTransitionFrame

        if bothSpikedRecently && (frameCounter - lastTransitionFrame) >= debounceFrames {
            lastTransitionFrame = frameCounter
            logDebug("analyzer: transition detected at frame \(frameCounter)")
            onTransitionDetected?()
        }
    }

    private func checkSpike(_ buffer: [Float]) -> Bool {
        guard buffer.count >= 2 else { return false }

        var mean: Float = 0
        vDSP_meanv(buffer, 1, &mean, vDSP_Length(buffer.count))

        var meanSquare: Float = 0
        vDSP_measqv(buffer, 1, &meanSquare, vDSP_Length(buffer.count))

        let variance = meanSquare - mean * mean
        let stddev = sqrtf(max(variance, 0))

        let latest = buffer[buffer.count - 1]
        return latest > mean + 2.0 * stddev
    }

    private func appendToRolling(_ buffer: inout [Float], value: Float) {
        buffer.append(value)
        if buffer.count > rollingCapacity {
            buffer.removeFirst(buffer.count - rollingCapacity)
        }
    }

    private static func hzToMel(_ hz: Float) -> Float {
        2595.0 * log10f(1.0 + hz / 700.0)
    }

    private static func melToHz(_ mel: Float) -> Float {
        700.0 * (powf(10.0, mel / 2595.0) - 1.0)
    }

    static func buildMelFilterbank(
        numFilters: Int,
        fftSize: Int,
        sampleRate: Float,
        lowFreq: Float,
        highFreq: Float
    ) -> [Float] {
        let numBins = fftSize / 2 + 1
        let lowMel = hzToMel(lowFreq)
        let highMel = hzToMel(highFreq)

        let melPoints = (0..<(numFilters + 2)).map { i in
            melToHz(lowMel + Float(i) * (highMel - lowMel) / Float(numFilters + 1))
        }

        let binFreqStep = sampleRate / Float(fftSize)
        let binIndices = melPoints.map { hz in
            Int(floorf(hz / binFreqStep))
        }

        var filterbank = [Float](repeating: 0, count: numFilters * numBins)

        for m in 0..<numFilters {
            let left = binIndices[m]
            let center = binIndices[m + 1]
            let right = binIndices[m + 2]

            if left == center && center == right { continue }

            for k in left...min(center, numBins - 1) where left < center {
                let weight = Float(k - left) / Float(center - left)
                filterbank[m * numBins + k] = weight
            }

            for k in center...min(right, numBins - 1) where center < right {
                let weight = Float(right - k) / Float(right - center)
                filterbank[m * numBins + k] = weight
            }
        }

        return filterbank
    }
}
