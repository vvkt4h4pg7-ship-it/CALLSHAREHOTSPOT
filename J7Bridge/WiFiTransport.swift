import Foundation
import Network

final class WiFiTransport {
    enum Control: UInt8 {
        case hello = 0x01
        case incomingCall = 0x10
        case callAnswer = 0x11
        case callActive = 0x12
        case callEnd = 0x13
        case voiceOpen = 0x14
        case voiceClose = 0x15
        case makeCall = 0x20
        case hangup = 0x21
        case dtmf = 0x22
        case pong = 0x31
    }

    // Project-level Wi-Fi signaling. Audio uses the already-proven J7WV packet
    // format produced by j7_wifi_voice_core R1.
    private static let controlMagic: [UInt8] = [0x4A, 0x37, 0x57, 0x43] // J7WC
    private static let audioMagic: [UInt8] = [0x4A, 0x37, 0x57, 0x56]   // J7WV
    private static let version: UInt8 = 1
    private static let controlHeaderSize = 12
    private static let audioHeaderSize = 20

    private var _j7Host: String
    let port: UInt16

    var j7Host: String { _j7Host }

    var onControl: ((Control, Data) -> Void)?
    var onAudioPCM: ((Data, UInt32, UInt16, UInt16) -> Void)?
    var onStatus: ((String) -> Void)?

    private let rxQueue = DispatchQueue(label: "com.callshare.wifi.rx", qos: .userInitiated)
    private let txQueue = DispatchQueue(label: "com.callshare.wifi.tx", qos: .userInitiated)

    private var listener: NWListener?
    private var uplink: NWConnection?
    private var sequence: UInt32 = 0
    private var pendingTX: [Data] = []
    private let maxPendingTX = 5
    private var started = false

    init(j7Host: String = "192.168.104.12", port: UInt16 = 50005) {
        self._j7Host = j7Host
        self.port = port
    }

    deinit {
        stop()
    }

    func start() {
        txQueue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.startListener()
            self.startUplink()
        }
    }

    func stop() {
        txQueue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.listener?.cancel()
            self.listener = nil
            self.uplink?.cancel()
            self.uplink = nil
            self.pendingTX.removeAll(keepingCapacity: false)
        }
    }

    func setJ7Host(_ host: String) {
        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        txQueue.async { [weak self] in
            guard let self else { return }
            guard self._j7Host != cleaned else { return }
            self._j7Host = cleaned
            self.uplink?.cancel()
            self.uplink = nil
            if self.started { self.startUplink() }
            self.onStatus?("[WIFI] J7 HOST = \(cleaned)")
        }
    }

    func sendHello() {
        sendControl(.hello, payload: Data())
    }

    func sendAnswer() {
        sendControl(.callAnswer, payload: Data())
    }

    func sendHangup() {
        sendControl(.hangup, payload: Data())
    }

    func sendVoiceOpen() {
        sendControl(.voiceOpen, payload: Data())
    }

    func sendVoiceClose() {
        sendControl(.voiceClose, payload: Data())
    }

    func sendMakeCall(number: String) {
        sendControl(.makeCall, payload: Data(number.utf8))
    }

    func sendDTMF(_ value: UInt8) {
        sendControl(.dtmf, payload: Data([value]))
    }

    func sendAudioPCM(_ pcm: Data, sampleRate: UInt32 = 48_000, channels: UInt16 = 2, frames: UInt16 = 960) {
        guard pcm.count == Int(frames) * Int(channels) * 2 else {
            onStatus?("[WIFI] TX PCM size invalid: \(pcm.count)")
            return
        }

        txQueue.async { [weak self] in
            guard let self else { return }
            let packet = self.makeAudioPacket(
                pcm: pcm,
                sampleRate: sampleRate,
                channels: channels,
                frames: frames
            )
            self.enqueueOrSend(packet)
        }
    }

    private func startListener() {
        do {
            let parameters = NWParameters.udp
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                self?.onStatus?("[WIFI] UDP LISTENER \(String(describing: state))")
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.stateUpdateHandler = { [weak self] state in
                    self?.onStatus?("[WIFI] RX PEER \(String(describing: state))")
                }
                connection.start(queue: self.rxQueue)
                self.receiveLoop(connection)
            }

            listener.start(queue: rxQueue)
            onStatus?("[WIFI] LISTENING UDP \(port)")
        } catch {
            onStatus?("[WIFI] LISTENER ERROR: \(error.localizedDescription)")
        }
    }

    private func startUplink() {
        let connection = NWConnection(
            host: NWEndpoint.Host(j7Host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        uplink = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.onStatus?("[WIFI] J7 UPLINK \(String(describing: state))")
            if case .ready = state {
                self.flushPendingTX()
                self.sendHello()
            } else if case .failed = state {
                connection.cancel()
                self.uplink = nil
            }
        }

        connection.start(queue: txQueue)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                self.onStatus?("[WIFI] RX ERROR: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            if let data, !data.isEmpty {
                self.handleDatagram(data)
            }

            self.receiveLoop(connection)
        }
    }

    private func handleDatagram(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return }

        if Array(bytes.prefix(4)) == Self.audioMagic {
            parseAudioDatagram(data)
            return
        }

        if Array(bytes.prefix(4)) == Self.controlMagic {
            parseControlDatagram(data)
            return
        }

        onStatus?("[WIFI] RX UNKNOWN DATAGRAM len=\(data.count)")
    }

    private func parseControlDatagram(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.controlHeaderSize else {
            onStatus?("[WIFI] CONTROL DROP short=\(data.count)")
            return
        }
        guard Array(bytes[0..<4]) == Self.controlMagic, bytes[4] == Self.version else { return }

        let typeRaw = bytes[5]
        guard let type = Control(rawValue: typeRaw) else {
            onStatus?("[WIFI] CONTROL DROP type=0x\(String(format: "%02X", typeRaw))")
            return
        }

        let payloadLength = Int(UInt16(bytes[10]) | (UInt16(bytes[11]) << 8))
        guard payloadLength == bytes.count - Self.controlHeaderSize else {
            onStatus?("[WIFI] CONTROL DROP length")
            return
        }

        let payload = Data(bytes[Self.controlHeaderSize..<bytes.count])
        onControl?(type, payload)
    }

    private func parseAudioDatagram(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.audioHeaderSize else {
            onStatus?("[WIFI] AUDIO DROP short=\(data.count)")
            return
        }
        guard Array(bytes[0..<4]) == Self.audioMagic else { return }

        let sampleRate = readLE32(bytes, 8)
        let channels = readLE16(bytes, 12)
        let format = readLE16(bytes, 14)
        let frames = readLE16(bytes, 16)
        let flags = readLE16(bytes, 18)

        guard sampleRate > 0, channels > 0, channels <= 2, format == 1, frames > 0 else {
            onStatus?("[WIFI] AUDIO DROP bad header")
            return
        }
        guard (flags & 0x0001) != 0 else { return }

        let payload = Data(bytes[Self.audioHeaderSize..<bytes.count])
        let expected = Int(frames) * Int(channels) * 2
        guard payload.count == expected else {
            onStatus?("[WIFI] AUDIO DROP size=\(payload.count) expected=\(expected)")
            return
        }

        onAudioPCM?(payload, sampleRate, channels, frames)
    }

    private func sendControl(_ control: Control, payload: Data) {
        txQueue.async { [weak self] in
            guard let self else { return }
            let packet = self.makeControlPacket(type: control, payload: payload)
            self.enqueueOrSend(packet)
        }
    }

    private func enqueueOrSend(_ packet: Data) {
        guard let uplink else {
            if pendingTX.count >= maxPendingTX { pendingTX.removeFirst() }
            pendingTX.append(packet)
            return
        }

        uplink.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.onStatus?("[WIFI] TX ERROR: \(error.localizedDescription)")
            }
        })
    }

    private func flushPendingTX() {
        guard !pendingTX.isEmpty else { return }
        let items = pendingTX
        pendingTX.removeAll(keepingCapacity: true)
        for item in items { enqueueOrSend(item) }
    }

    private func makeControlPacket(type: Control, payload: Data) -> Data {
        let seq = nextSequence()
        var out = Data(Self.controlMagic)
        out.append(Self.version)
        out.append(type.rawValue)
        appendLE32(&out, seq)
        appendLE16(&out, UInt16(min(payload.count, Int(UInt16.max))))
        out.append(payload.prefix(Int(UInt16.max)))
        return out
    }

    private func makeAudioPacket(pcm: Data, sampleRate: UInt32, channels: UInt16, frames: UInt16) -> Data {
        let seq = nextSequence()
        var out = Data(Self.audioMagic)
        appendLE32(&out, seq)
        appendLE32(&out, sampleRate)
        appendLE16(&out, channels)
        appendLE16(&out, 1) // S16_LE
        appendLE16(&out, frames)
        appendLE16(&out, 1) // audio flag
        out.append(pcm)
        return out
    }

    private func nextSequence() -> UInt32 {
        let value = sequence
        sequence &+= 1
        return value
    }

    private func readLE16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private func readLE32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) |
        (UInt32(b[i + 1]) << 8) |
        (UInt32(b[i + 2]) << 16) |
        (UInt32(b[i + 3]) << 24)
    }

    private func appendLE16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendLE32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
