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

    /// Standalone lab mode for the first milestone: no CallKit required.
    func startStandaloneTest() {
        configureSession(activate: true)
        startEngine()
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
            if !self.isRunning || !self.audioEngine.isRunning {
                if self.preStartRX.count >= self.maxPreStartRX { self.preStartRX.removeFirst() }
                self.preStartRX.append((pcm, sampleRate, channels, frames))
                if self.preStartRX.count == 1 {
                    self.report("[WIFI_AUDIO] RX buffered before audio activation")
                }
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
            let frame = pcmAccumulator.prefix(frameBytes)
            let data = Data(frame)
            pcmAccumulator.removeFirst(frameBytes)
            txFrames += 1
            transport.sendAudioPCM(data)

            if txFrames == 1 || txFrames % 50 == 0 {
                report("[WIFI_AUDIO] TX PCM #\(txFrames) 3840B")
            }
        }
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
