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

    // Outgoing iPhone microphone -> J7 -> GSM gain. Applied after conversion to
    // interleaved S16_LE stereo, just before UDP transmission. No playback-path changes.
    private let micPreGain: Double = 5.0

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
            let processed = applyMicGainAndSoftClip(frame, preGain: micPreGain)
            txFrames += 1
            transport.sendAudioPCM(processed.data)

            if txFrames == 1 || txFrames % 50 == 0 {
                report(String(format: "[WIFI_AUDIO] TX PCM #%d 3840B gain=%.1fx preRMS=%.1f dBFS postRMS=%.1f dBFS prePeak=%.1f dBFS postPeak=%.1f dBFS",
                              txFrames, micPreGain, processed.preRMSDBFS, processed.postRMSDBFS,
                              processed.prePeakDBFS, processed.postPeakDBFS))
            }
        }
    }

    private struct MicPCMResult {
        let data: Data
        let preRMSDBFS: Double
        let postRMSDBFS: Double
        let prePeakDBFS: Double
        let postPeakDBFS: Double
    }

    /// Applies 5x gain with tanh soft-clipping to one 20 ms S16_LE interleaved stereo packet.
    /// This is only the iPhone microphone uplink; J7 -> iPhone playback is untouched.
    private func applyMicGainAndSoftClip(_ pcm: Data, preGain: Double) -> MicPCMResult {
        var output = pcm
        var preSumSquares = 0.0
        var postSumSquares = 0.0
        var prePeak = 0.0
        var postPeak = 0.0
        var sampleCount = 0

        output.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            sampleCount = bytes.count / MemoryLayout<Int16>.size
            guard sampleCount > 0 else { return }

            for sampleIndex in 0..<sampleCount {
                let offset = sampleIndex * 2
                // The target PCM is S16_LE. Read/write explicitly so no alignment assumptions are made.
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let sample = Int16(bitPattern: bits)
                let normalized = Double(sample) / 32768.0

                preSumSquares += normalized * normalized
                prePeak = max(prePeak, abs(normalized))

                // At low levels this approaches linear 5x gain; louder peaks are smoothly limited.
                let shaped = tanh(normalized * preGain)
                let rounded = (shaped * 32768.0).rounded()
                let bounded = Int32(max(-32768.0, min(32767.0, rounded)))
                let processedSample = Int16(bounded)
                let outBits = UInt16(bitPattern: processedSample)
                bytes[offset] = UInt8(truncatingIfNeeded: outBits)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: outBits >> 8)

                let outNormalized = Double(processedSample) / 32768.0
                postSumSquares += outNormalized * outNormalized
                postPeak = max(postPeak, abs(outNormalized))
            }
        }

        let divisor = Double(max(sampleCount, 1))
        let preRMS = sqrt(preSumSquares / divisor)
        let postRMS = sqrt(postSumSquares / divisor)
        return MicPCMResult(
            data: output,
            preRMSDBFS: levelDBFS(preRMS),
            postRMSDBFS: levelDBFS(postRMS),
            prePeakDBFS: levelDBFS(prePeak),
            postPeakDBFS: levelDBFS(postPeak)
        )
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
