import Foundation
import AVFoundation

final class WiFiVoiceEngine: NSObject {
    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private let playerNode = AVAudioPlayerNode()
    private let transport: WiFiTransport

    private let playbackQueue = DispatchQueue(label: "com.callshare.wifi.playback", qos: .userInitiated)
    private var isRunning = false
    private var playbackConnected = false
    private var converter: AVAudioConverter?
    private var pcmAccumulator = Data()
    private var txFrames = 0
    private var rxFrames = 0
    private var preStartRX: [(Data, UInt32, UInt16, UInt16)] = []
    private let maxPreStartRX = 5 // ~100 ms at 20 ms packets
    private var useSpeaker = true
    private var muted = false

    // iPhone microphone uplink only. The existing AVAudioSession, CallKit activation,
    // UDP framing, and J7 -> iPhone playback path are intentionally unchanged.
    // A per-packet leveler supplies makeup gain because .voiceChat without Voice Processing I/O
    // does not guarantee system AGC. Gain is capped and followed by a soft limiter.
    private let micHighPassAlpha: Double = 0.9856 // approximately 110 Hz at 48 kHz
    private let micTargetRMS: Double = 0.125      // about -18 dBFS
    private let micMaxGain: Double = 18.0         // maximum boost: about +25 dB
    private let micMinGain: Double = 0.35         // allow attenuation of loud wind/plosives
    private let micGateRMS: Double = 0.0010       // avoid amplifying idle noise (~-60 dBFS)
    private let micLimiterKnee: Double = 0.72
    private let micLimiterCeiling: Double = 0.94
    private var micHPPrevX: Double = 0.0
    private var micHPPrevY: Double = 0.0
    private var micCurrentGain: Double = 1.0

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    )!

    var onStatus: ((String) -> Void)?

    init(transport: WiFiTransport) {
        self.transport = transport
        super.init()
    }

    func setSpeakerDefault(_ enabled: Bool) {
        useSpeaker = enabled
        if isRunning { configureSession(activate: false) }
    }

    func setMuted(_ value: Bool) {
        muted = value
        report(value ? "[WIFI_AUDIO] MUTED" : "[WIFI_AUDIO] UNMUTED")
    }

    /// CallKit owns activation for real calls. We only prepare the session here;
    /// this deliberately does not call setActive(true).
    func prepareForCallAudio() {
        configureSession(activate: false)
        report("[WIFI_AUDIO] SESSION PREPARED 48k stereo")
    }

    /// Real-call mode: CallKit's didActivate callback must have fired first.
    @discardableResult
    func start() -> Bool {
        startEngine()
    }

    func stop() {
        guard isRunning || audioEngine.isRunning else { return }

        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        playerNode.reset()
        audioEngine.stop()
        converter = nil
        pcmAccumulator.removeAll(keepingCapacity: true)
        playbackQueue.async { [weak self] in self?.preStartRX.removeAll(keepingCapacity: true) }
        transport.sendVoiceClose()
        report("[WIFI_AUDIO] CLOSED")
    }

    func receivePCM(_ pcm: Data, sampleRate: UInt32, channels: UInt16, frames: UInt16) {
        guard sampleRate == 48_000, channels == 2, frames == 960, pcm.count == 3840 else {
            report("[WIFI_AUDIO] RX FORMAT DROP rate=\(sampleRate) ch=\(channels) frames=\(frames) bytes=\(pcm.count)")
            return
        }

        playbackQueue.async { [weak self] in
            guard let self else { return }
            // Hard gate: never queue or play GSM PCM before CallKit activates audio.
            // This prevents pre-answer / idle audio leakage and stale frames after activation.
            guard self.isRunning, self.audioEngine.isRunning else {
                return
            }
            self.playPCMNow(pcm, frames: frames)
        }
    }

    private func playPCMNow(_ pcm: Data, frames: UInt16) {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ) else { return }

        buffer.frameLength = AVAudioFrameCount(frames)
        let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
        guard let destination = audioBuffer.mData else { return }

        pcm.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            memcpy(destination, base, pcm.count)
        }

        playerNode.scheduleBuffer(buffer)
        rxFrames += 1

        if rxFrames == 1 || rxFrames % 50 == 0 {
            report("[WIFI_AUDIO] RX PCM #\(rxFrames) 3840B")
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func flushPreStartRX() {
        let pending = preStartRX
        preStartRX.removeAll(keepingCapacity: true)
        for (pcm, _, _, frames) in pending {
            playPCMNow(pcm, frames: frames)
        }
    }

    private func startEngine() -> Bool {
        guard !isRunning else { return true }

        do {
            if !playbackConnected {
                audioEngine.attach(playerNode)
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: targetFormat)
                playbackConnected = true
            }

            playerNode.volume = 1.0
            audioEngine.mainMixerNode.outputVolume = 1.0

            let input = audioEngine.inputNode
            let inputFormat = input.inputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw NSError(domain: "CALLSHARE.WiFiAudio", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No microphone input route"])
            }

            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            guard converter != nil else {
                throw NSError(domain: "CALLSHARE.WiFiAudio", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "48 kHz stereo converter unavailable"])
            }

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
                self?.capture(buffer)
            }

            playerNode.stop()
            playerNode.reset()
            txFrames = 0
            rxFrames = 0
            pcmAccumulator.removeAll(keepingCapacity: true)
            micHPPrevX = 0.0
            micHPPrevY = 0.0
            micCurrentGain = 1.0

            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
            playerNode.play()
            playbackQueue.async { [weak self] in self?.flushPreStartRX() }
            transport.sendVoiceOpen()
            report("[WIFI_AUDIO] OPEN OK mic=\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch -> 48k/2ch")
            return true
        } catch {
            isRunning = false
            inputRemoveTapSafely()
            audioEngine.stop()
            playerNode.stop()
            converter = nil
            report("[WIFI_AUDIO] START ERROR: \(error.localizedDescription)")
            return false
        }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let converter, !muted else { return }

        let estimated = AVAudioFrameCount(Double(buffer.frameLength) *
                                          targetFormat.sampleRate / buffer.format.sampleRate + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimated) else { return }

        var error: NSError?
        var supplied = false
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil,
              converted.frameLength > 0,
              let raw = interleavedPCMData(from: converted) else {
            if let error { report("[WIFI_AUDIO] MIC CONVERT ERROR: \(error.localizedDescription)") }
            return
        }

        pcmAccumulator.append(raw)
        let frameBytes = 960 * 2 * 2

        while pcmAccumulator.count >= frameBytes {
            let frame = Data(pcmAccumulator.prefix(frameBytes))
            pcmAccumulator.removeFirst(frameBytes)

            // Process the final 20 ms packet in its known format: interleaved S16_LE stereo.
            // This avoids int16ChannelData indexing against an interleaved AVAudioBuffer.
            let processed = applyMicSpeechLeveler(frame)
            txFrames += 1
            transport.sendAudioPCM(processed.data)

            if txFrames == 1 || txFrames % 50 == 0 {
                report(String(format: "[WIFI_AUDIO] MIC LEVELER TX #%d gain=%.2fx rawRMS=%.1f dBFS hpRMS=%.1f dBFS outRMS=%.1f dBFS rawPeak=%.1f dBFS outPeak=%.1f dBFS",
                              txFrames, processed.gain, processed.inputRMSDBFS, processed.filteredRMSDBFS,
                              processed.outputRMSDBFS, processed.inputPeakDBFS, processed.outputPeakDBFS))
            }
        }
    }

    private struct MicPCMResult {
        let data: Data
        let inputRMSDBFS: Double
        let filteredRMSDBFS: Double
        let outputRMSDBFS: Double
        let inputPeakDBFS: Double
        let outputPeakDBFS: Double
        let gain: Double
    }

    /// Processes ONLY iPhone microphone uplink PCM, after conversion and before UDP TX.
    /// Input packet is 20 ms, 48 kHz, interleaved S16_LE stereo (L,R,L,R...).
    /// The active route has previously reported a mono mic input, so use the converted
    /// left sample as the mono source and explicitly write it to both output channels.
    /// A high-pass attenuates wind/handling rumble; a smoothed RMS leveler lifts ordinary speech;
    /// a soft limiter controls strong peaks. No playback code is touched.
    private func applyMicSpeechLeveler(_ pcm: Data) -> MicPCMResult {
        var output = pcm
        var inputSumSquares = 0.0
        var filteredSumSquares = 0.0
        var inputPeak = 0.0
        let frameCount = pcm.count / 4 // two Int16 samples per stereo frame
        var metrics = (-120.0, -120.0, -120.0, -120.0, -120.0, 1.0)
        let startHPX = micHPPrevX
        let startHPY = micHPPrevY

        output.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard frameCount > 0, bytes.count >= frameCount * 4 else { return }

            // Pass 1: inspect original left-channel PCM and measure the level. No per-packet
            // sample-array allocation is needed on the real-time audio callback.
            var hpX = startHPX
            var hpY = startHPY
            for frame in 0..<frameCount {
                let offset = frame * 4
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let sample = Int16(bitPattern: bits)
                let x = Double(sample) / 32768.0
                inputSumSquares += x * x
                inputPeak = max(inputPeak, abs(x))

                let y = micHighPassAlpha * (hpY + x - hpX)
                hpX = x
                hpY = y
                filteredSumSquares += y * y
            }
            micHPPrevX = hpX
            micHPPrevY = hpY

            let divisor = Double(max(frameCount, 1))
            let inputRMS = sqrt(inputSumSquares / divisor)
            let filteredRMS = sqrt(filteredSumSquares / divisor)

            // Target about -18 dBFS. Unlike fixed makeup gain, this can attenuate loud gusts
            // as well as raise speech, while still limiting maximum boost to 18x.
            let desiredGain: Double
            if filteredRMS < micGateRMS {
                desiredGain = 1.0
            } else {
                desiredGain = min(micMaxGain, max(micMinGain, micTargetRMS / max(filteredRMS, 1.0e-6)))
            }

            // Quiet speech gets fast-but-smoothed gain-up. Loud transients trigger near-immediate
            // gain reduction so a close breath cannot inherit several packets of high speech gain.
            let smoothing: Double
            if filteredRMS < micGateRMS {
                smoothing = 0.85
            } else if desiredGain > micCurrentGain {
                smoothing = 0.38
            } else {
                smoothing = 0.92
            }
            micCurrentGain += (desiredGain - micCurrentGain) * smoothing
            micCurrentGain = min(micMaxGain, max(micMinGain, micCurrentGain))

            // Pass 2: apply the same high-pass from the packet's original filter state, gain,
            // limiter, and dual-mono mapping. Both channels are written identically.
            hpX = startHPX
            hpY = startHPY
            var outputSumSquares = 0.0
            var outputPeak = 0.0
            for frame in 0..<frameCount {
                let offset = frame * 4
                let inBits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let inputSample = Int16(bitPattern: inBits)
                let x = Double(inputSample) / 32768.0
                let filtered = micHighPassAlpha * (hpY + x - hpX)
                hpX = x
                hpY = filtered

                let boosted = filtered * micCurrentGain
                let magnitude = abs(boosted)
                let limitedMagnitude: Double
                if magnitude <= micLimiterKnee {
                    limitedMagnitude = magnitude
                } else {
                    let span = micLimiterCeiling - micLimiterKnee
                    let excess = magnitude - micLimiterKnee
                    limitedMagnitude = micLimiterKnee + span * (1.0 - exp(-excess / span))
                }
                let limited = boosted < 0.0 ? -limitedMagnitude : limitedMagnitude
                let bounded = Int32(max(-32768.0, min(32767.0, (limited * 32768.0).rounded())))
                let result = Int16(bounded)
                let outBits = UInt16(bitPattern: result)

                bytes[offset] = UInt8(truncatingIfNeeded: outBits)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: outBits >> 8)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: outBits)
                bytes[offset + 3] = UInt8(truncatingIfNeeded: outBits >> 8)

                let normalized = Double(result) / 32768.0
                outputSumSquares += normalized * normalized
                outputPeak = max(outputPeak, abs(normalized))
            }

            let outputRMS = sqrt(outputSumSquares / divisor)
            metrics = (
                levelDBFS(inputRMS), levelDBFS(filteredRMS), levelDBFS(outputRMS),
                levelDBFS(inputPeak), levelDBFS(outputPeak), micCurrentGain
            )
        }

        return MicPCMResult(data: output, inputRMSDBFS: metrics.0, filteredRMSDBFS: metrics.1,
                            outputRMSDBFS: metrics.2, inputPeakDBFS: metrics.3,
                            outputPeakDBFS: metrics.4, gain: metrics.5)
    }

    private func levelDBFS(_ normalizedLevel: Double) -> Double {
        guard normalizedLevel > 0 else { return -120.0 }
        return 20.0 * log10(normalizedLevel)
    }

    private func interleavedPCMData(from buffer: AVAudioPCMBuffer) -> Data? {
        let list = buffer.audioBufferList.pointee
        guard let mData = list.mBuffers.mData else { return nil }
        let byteCount = Int(buffer.frameLength) * Int(targetFormat.channelCount) * MemoryLayout<Int16>.size
        return Data(bytes: mData, count: byteCount)
    }

    private func configureSession(activate: Bool) {
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
        if !useSpeaker { options.remove(.defaultToSpeaker) }

        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try audioSession.setPreferredSampleRate(48_000)
            try audioSession.setPreferredIOBufferDuration(0.02)
            if activate {
                try audioSession.setActive(true)
            }
        } catch {
            report("[WIFI_AUDIO] SESSION ERROR: \(error.localizedDescription)")
        }
    }

    private func inputRemoveTapSafely() {
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func report(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(status)
        }
    }
}
