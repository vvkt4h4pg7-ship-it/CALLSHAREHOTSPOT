import Foundation
import AVFoundation
import Darwin

/// Fresh, isolated audio engine for CALLSHARE's existing J7WV wire protocol.
///
/// Wire contract (unchanged): 48,000 Hz, signed Int16 little-endian,
/// interleaved stereo, 960 frames / 20 ms / 3,840 PCM bytes per packet.
///
/// Design notes:
/// - CallKit remains the owner of AVAudioSession activation.
/// - No VoiceProcessingIO is enabled in this first clean baseline, so the
///   J7 -> iPhone playback path is not subjected to a new system voice DSP mode.
/// - Capture is read from inputNode.outputFormat(forBus: 0), converted to
///   mono Float32 at 48 kHz, processed once, and explicitly duplicated to L/R.
/// - UDP protocol framing remains WiFiTransport's responsibility.
final class WiFiVoiceEngine: NSObject {
    private static let sampleRate: Double = 48_000
    private static let packetFrames = 960
    private static let packetBytes = packetFrames * 2 * MemoryLayout<Int16>.size

    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private let playerNode = AVAudioPlayerNode()
    private let transport: WiFiTransport
    private let playbackQueue = DispatchQueue(label: "com.callshare.wifi.playback.r1", qos: .userInitiated)
    private let stateLock = NSLock()

    private var isRunning = false
    private var muted = false
    private var playbackConnected = false
    private var useSpeaker = true

    private var micConverter: AVAudioConverter?
    private var micInputFormat: AVAudioFormat?
    private let micTargetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    private var monoAccumulator: [Float] = []
    private var txFrames = 0
    private var rxFrames = 0

    // Software mic processing. These are intentionally isolated from playback.
    private let highPassAlpha: Double = 0.9896       // ~80 Hz at 48 kHz
    private let targetRMS: Double = 0.063            // about -24 dBFS; 6 dB lower test target to reduce J7 uplink overdrive
    private let maximumGain: Double = 32.0           // +30.1 dB ceiling
    private let minimumGain: Double = 0.35
    private let nearSilenceRMS: Double = 0.000025    // do not raise digital silence
    private let limiterKnee: Double = 0.72
    private let limiterCeiling: Double = 0.94
    private var hpPreviousInput: Double = 0
    private var hpPreviousOutput: Double = 0
    private var currentMicGain: Double = 1.0

    private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 2,
        interleaved: true
    )!

    var onStatus: ((String) -> Void)?

    init(transport: WiFiTransport) {
        self.transport = transport
        super.init()
    }

    // MARK: - Public API (kept compatible with AppModel.swift)

    func setSpeakerDefault(_ enabled: Bool) {
        useSpeaker = enabled
        if runningSnapshot() {
            configureAudioSession()
        }
    }

    func setMuted(_ value: Bool) {
        stateLock.lock()
        muted = value
        stateLock.unlock()
        report(value ? "[WIFI_AUDIO] MIC MUTED" : "[WIFI_AUDIO] MIC UNMUTED")
    }

    /// Called before CallKit activates its audio session. Never activates the
    /// session itself; CXProviderDelegate.didActivate remains authoritative.
    func prepareForCallAudio() {
        configureAudioSession()
        report("[WIFI_AUDIO] FRESH_R1 SESSION PREPARED; CallKit owns activation")
    }

    @discardableResult
    func start() -> Bool {
        startEngine()
    }

    func stop() {
        stateLock.lock()
        let wasRunning = isRunning
        isRunning = false
        stateLock.unlock()

        guard wasRunning || audioEngine.isRunning else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        playerNode.reset()
        audioEngine.stop()

        micConverter = nil
        micInputFormat = nil
        monoAccumulator.removeAll(keepingCapacity: true)
        resetMicDSP()
        transport.sendVoiceClose()
        report("[WIFI_AUDIO] FRESH_R1 CLOSED")
    }

    func receivePCM(_ pcm: Data, sampleRate: UInt32, channels: UInt16, frames: UInt16) {
        guard sampleRate == 48_000,
              channels == 2,
              frames == UInt16(Self.packetFrames),
              pcm.count == Self.packetBytes else {
            report("[WIFI_AUDIO] RX FORMAT DROP rate=\(sampleRate) ch=\(channels) frames=\(frames) bytes=\(pcm.count)")
            return
        }

        playbackQueue.async { [weak self] in
            guard let self, self.runningSnapshot(), self.audioEngine.isRunning else { return }
            self.playPCMNow(pcm)
        }
    }

    // MARK: - Session / engine setup

    private func configureAudioSession() {
        var options: AVAudioSession.CategoryOptions = []
        if useSpeaker { options.insert(.defaultToSpeaker) }

        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try audioSession.setPreferredSampleRate(Self.sampleRate)
            // Request a low-latency hardware I/O cycle. The wire packet remains 20 ms.
            try audioSession.setPreferredIOBufferDuration(0.01)
            report("[WIFI_AUDIO] FRESH_R1 SESSION category=playAndRecord mode=voiceChat ioPref=10ms otherAudio=\(audioSession.isOtherAudioPlaying)")
        } catch {
            report("[WIFI_AUDIO] FRESH_R1 SESSION ERROR: \(error.localizedDescription)")
        }
    }

    private func startEngine() -> Bool {
        if runningSnapshot() { return true }

        do {
            if !playbackConnected {
                audioEngine.attach(playerNode)
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: wireFormat)
                playbackConnected = true
            }

            // Preserve the existing J7 -> iPhone playback gain. No new output
            // volume adjustment and no VoiceProcessingIO mode switch here.
            playerNode.volume = 1.0
            audioEngine.mainMixerNode.outputVolume = 1.0

            let input = audioEngine.inputNode
            // The tap is on the input node's OUTPUT bus: this is the microphone
            // stream format to capture, not the node's input-bus format.
            let captureFormat = input.outputFormat(forBus: 0)
            guard captureFormat.sampleRate > 0, captureFormat.channelCount > 0 else {
                throw engineError(1, "Microphone output format is unavailable")
            }

            guard let converter = AVAudioConverter(from: captureFormat, to: micTargetFormat) else {
                throw engineError(2, "Could not create microphone-to-mono-48k converter")
            }
            // If the route offers more than one input channel, select channel 0
            // explicitly instead of downmixing opposing channels into cancellation.
            converter.channelMap = [NSNumber(value: 0)]

            micInputFormat = captureFormat
            micConverter = converter
            monoAccumulator.removeAll(keepingCapacity: true)
            txFrames = 0
            rxFrames = 0
            resetMicDSP()

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 480, format: captureFormat) { [weak self] buffer, _ in
                self?.captureMicrophone(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            stateLock.lock()
            isRunning = true
            stateLock.unlock()

            playerNode.play()
            transport.sendVoiceOpen()
            report("[WIFI_AUDIO] FRESH_R1 OPEN OK capture=\(Int(captureFormat.sampleRate))Hz/\(captureFormat.channelCount)ch format=\(captureFormat.commonFormat.rawValue) -> monoFloat/48000 -> S16LE dual-mono 48k/2ch")
            report("[WIFI_AUDIO] FRESH_R1 MIC TX path active; playback path unchanged; VPIO=off")
            return true
        } catch {
            stateLock.lock()
            isRunning = false
            stateLock.unlock()
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            playerNode.stop()
            micConverter = nil
            micInputFormat = nil
            report("[WIFI_AUDIO] FRESH_R1 START ERROR: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Microphone capture / conversion / packetization

    private func captureMicrophone(_ inputBuffer: AVAudioPCMBuffer) {
        guard runningSnapshot(), !mutedSnapshot(), let converter = micConverter else { return }

        let inputRate = inputBuffer.format.sampleRate
        guard inputRate > 0 else { return }
        let estimatedFrames = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * Self.sampleRate / inputRate) + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: micTargetFormat, frameCapacity: max(estimatedFrames, 1)) else { return }

        var converterError: NSError?
        var providedInput = false
        converter.convert(to: converted, error: &converterError) { _, status in
            if providedInput {
                status.pointee = .noDataNow
                return nil
            }
            providedInput = true
            status.pointee = .haveData
            return inputBuffer
        }

        guard converterError == nil,
              converted.frameLength > 0,
              let channelData = converted.floatChannelData else {
            if let converterError {
                report("[WIFI_AUDIO] FRESH_R1 MIC CONVERT ERROR: \(converterError.localizedDescription)")
            }
            return
        }

        // The destination format is non-interleaved Float32 mono, therefore
        // channel 0 has one contiguous sample per frame (stride 1).
        let count = Int(converted.frameLength)
        monoAccumulator.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))

        while monoAccumulator.count >= Self.packetFrames {
            let packetSamples = Array(monoAccumulator.prefix(Self.packetFrames))
            monoAccumulator.removeFirst(Self.packetFrames)
            let processed = makeWirePacket(fromMonoSamples: packetSamples)
            txFrames += 1
            transport.sendAudioPCM(processed.data, sampleRate: 48_000, channels: 2, frames: UInt16(Self.packetFrames))

            if txFrames == 1 || txFrames % 50 == 0 {
                report(String(format: "[WIFI_AUDIO] FRESH_R1 MIC TX #%d gain=%.2fx rawRMS=%.1f dBFS hpRMS=%.1f dBFS outRMS=%.1f dBFS outPeak=%.1f dBFS", txFrames, processed.gain, processed.rawRMSDBFS, processed.highPassRMSDBFS, processed.outputRMSDBFS, processed.outputPeakDBFS))
            }
        }
    }

    private struct ProcessedPacket {
        let data: Data
        let gain: Double
        let rawRMSDBFS: Double
        let highPassRMSDBFS: Double
        let outputRMSDBFS: Double
        let outputPeakDBFS: Double
    }

    /// Process 20 ms mono input and make exactly 3,840 bytes of L=R S16_LE PCM.
    /// This is software mic processing only; no player/output samples are touched.
    private func makeWirePacket(fromMonoSamples samples: [Float]) -> ProcessedPacket {
        var filtered = [Double](repeating: 0, count: samples.count)
        var rawSumSquares = 0.0
        var hpSumSquares = 0.0
        var previousX = hpPreviousInput
        var previousY = hpPreviousOutput

        for index in samples.indices {
            let x = max(-1.0, min(1.0, Double(samples[index])))
            rawSumSquares += x * x
            let y = highPassAlpha * (previousY + x - previousX)
            previousX = x
            previousY = y
            filtered[index] = y
            hpSumSquares += y * y
        }
        hpPreviousInput = previousX
        hpPreviousOutput = previousY

        let divisor = Double(max(samples.count, 1))
        let rawRMS = sqrt(rawSumSquares / divisor)
        let highPassRMS = sqrt(hpSumSquares / divisor)

        let desiredGain: Double
        if highPassRMS < nearSilenceRMS {
            desiredGain = 1.0
        } else {
            desiredGain = min(maximumGain, max(minimumGain, targetRMS / max(highPassRMS, 1.0e-8)))
        }

        // Fast gain reduction prevents strong plosives/wind from carrying high
        // gain into the next speech packet; gain-up is smoothed to reduce pumping.
        let smoothing = desiredGain < currentMicGain ? 0.82 : 0.42
        currentMicGain += (desiredGain - currentMicGain) * smoothing
        currentMicGain = min(maximumGain, max(minimumGain, currentMicGain))

        var outputData = Data(count: Self.packetBytes)
        var outputSumSquares = 0.0
        var outputPeak = 0.0

        outputData.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count >= Self.packetBytes else { return }

            for index in 0..<Self.packetFrames {
                let boosted = filtered[index] * currentMicGain
                let magnitude = abs(boosted)
                let limitedMagnitude: Double
                if magnitude <= limiterKnee {
                    limitedMagnitude = magnitude
                } else {
                    let span = limiterCeiling - limiterKnee
                    limitedMagnitude = limiterKnee + span * (1.0 - exp(-(magnitude - limiterKnee) / span))
                }
                let limited = boosted < 0 ? -limitedMagnitude : limitedMagnitude
                let normalized = max(-1.0, min(32767.0 / 32768.0, limited))
                let quantized = Int16((normalized * 32768.0).rounded())
                let bits = UInt16(bitPattern: quantized)
                let offset = index * 4

                // Explicit little-endian dual mono: L sample then identical R sample.
                let lo = UInt8(truncatingIfNeeded: bits)
                let hi = UInt8(truncatingIfNeeded: bits >> 8)
                bytes[offset] = lo
                bytes[offset + 1] = hi
                bytes[offset + 2] = lo
                bytes[offset + 3] = hi

                let sampleOut = Double(quantized) / 32768.0
                outputSumSquares += sampleOut * sampleOut
                outputPeak = max(outputPeak, abs(sampleOut))
            }
        }

        return ProcessedPacket(
            data: outputData,
            gain: currentMicGain,
            rawRMSDBFS: dbfs(sqrt(rawSumSquares / divisor)),
            highPassRMSDBFS: dbfs(highPassRMS),
            outputRMSDBFS: dbfs(sqrt(outputSumSquares / divisor)),
            outputPeakDBFS: dbfs(outputPeak)
        )
    }

    private func resetMicDSP() {
        hpPreviousInput = 0
        hpPreviousOutput = 0
        currentMicGain = 1.0
    }

    // MARK: - J7 -> iPhone playback (wire-compatible path kept intentionally simple)

    private func playPCMNow(_ pcm: Data) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: AVAudioFrameCount(Self.packetFrames)) else { return }
        buffer.frameLength = AVAudioFrameCount(Self.packetFrames)

        let audioBufferList = buffer.mutableAudioBufferList
        guard audioBufferList.pointee.mNumberBuffers == 1,
              let destination = audioBufferList.pointee.mBuffers.mData else { return }

        pcm.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            memcpy(destination, base, pcm.count)
        }

        playerNode.scheduleBuffer(buffer)
        rxFrames += 1
        if rxFrames == 1 || rxFrames % 50 == 0 {
            report("[WIFI_AUDIO] FRESH_R1 RX PCM #\(rxFrames) 3840B")
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    // MARK: - Small helpers

    private func runningSnapshot() -> Bool {
        stateLock.lock()
        let value = isRunning
        stateLock.unlock()
        return value
    }

    private func mutedSnapshot() -> Bool {
        stateLock.lock()
        let value = muted
        stateLock.unlock()
        return value
    }

    private func dbfs(_ value: Double) -> Double {
        guard value > 0 else { return -120.0 }
        return 20.0 * log10(value)
    }

    private func engineError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "CALLSHARE.WiFiVoiceEngine.FRESH_R1", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func report(_ status: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }
}
