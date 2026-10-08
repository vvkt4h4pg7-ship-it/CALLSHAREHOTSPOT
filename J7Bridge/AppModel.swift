import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var callStatus = "IDLE"
    @Published var number = ""
    @Published var callerName = ""
    @Published var voiceStatus = "CLOSED"
    @Published var wifiStatus = "Disconnected"
    @Published var j7Host: String {
        didSet {
            UserDefaults.standard.set(j7Host, forKey: "j7bridge.j7Host")
            wifi.setJ7Host(j7Host)
        }
    }
    @Published var dialString = ""
    @Published var logs: [String] = []
    @Published var battery = "-"
    @Published var firmware = "-"
    @Published var imei = "-"
    @Published var isMuted = false
    @Published private(set) var callStartedAt: Date?

    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "j7bridge.autoConnect") }
    }
    @Published var resolveCallerNames: Bool {
        didSet { UserDefaults.standard.set(resolveCallerNames, forKey: "j7bridge.resolveCallerNames") }
    }
    @Published var missedCallNotifications: Bool {
        didSet { UserDefaults.standard.set(missedCallNotifications, forKey: "j7bridge.missedCallNotifications") }
    }
    @Published var speakerDefault: Bool {
        didSet {
            UserDefaults.standard.set(speakerDefault, forKey: "j7bridge.speakerDefault")
            wifiVoice.setSpeakerDefault(speakerDefault)
        }
    }
    @Published var simSlot: Int {
        didSet { UserDefaults.standard.set(simSlot, forKey: "j7bridge.simSlot") }
    }

    let callKit: CallKitManager
    let contacts: ContactsManager
    let history: CallHistoryStore
    let notifications = NotificationManager()
    let wifi: WiFiTransport
    let wifiVoice: WiFiVoiceEngine

    private var currentDirection: CallDirection?
    private var currentContactName: String?
    private var callAudioActive = false
    private var remoteVoiceOpen = false

    init() {
        autoConnect = UserDefaults.standard.object(forKey: "j7bridge.autoConnect") as? Bool ?? true
        resolveCallerNames = UserDefaults.standard.object(forKey: "j7bridge.resolveCallerNames") as? Bool ?? true
        missedCallNotifications = UserDefaults.standard.object(forKey: "j7bridge.missedCallNotifications") as? Bool ?? true
        speakerDefault = UserDefaults.standard.object(forKey: "j7bridge.speakerDefault") as? Bool ?? true
        simSlot = UserDefaults.standard.object(forKey: "j7bridge.simSlot") as? Int ?? 0
        let initialJ7Host = UserDefaults.standard.string(forKey: "j7bridge.j7Host") ?? "192.168.104.12"
        j7Host = initialJ7Host

        callKit = CallKitManager()
        wifi = WiFiTransport(j7Host: initialJ7Host, port: 50005)
        wifiVoice = WiFiVoiceEngine(transport: wifi)
        contacts = ContactsManager()
        history = CallHistoryStore()

        wifiVoice.setSpeakerDefault(speakerDefault)

        wifi.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.wifiStatus = status
                self?.log(status)
            }
        }
        wifi.onControl = { [weak self] control, payload in
            Task { @MainActor [weak self] in
                self?.handleWiFiControl(control, payload: payload)
            }
        }
        wifi.onAudioPCM = { [weak self] pcm, rate, channels, frames in
            self?.wifiVoice.receivePCM(pcm, sampleRate: rate, channels: channels, frames: frames)
        }
        wifiVoice.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.voiceStatus = status
                self?.log(status)
            }
        }

        callKit.onLog = { [weak self] line in
            self?.log(line)
        }

        callKit.onStart = { [weak self] number in self?.beginOutgoing(number) }
        callKit.onAnswer = { [weak self] in
            guard let self else { return }
            self.wifiVoice.prepareForCallAudio()
            self.wifi.sendAnswer()
            self.log("[CALLKIT] ANSWER -> J7 WIFI")
        }
        callKit.onEnd = { [weak self] in self?.endFromCallKit() }
        callKit.onMute = { [weak self] muted in
            self?.isMuted = muted
            self?.wifiVoice.setMuted(muted)
        }
        callKit.onDTMF = { [weak self] digits in
            self?.sendDTMFString(digits)
        }
        callKit.onAudioActivated = { [weak self] in
            self?.callAudioActive = true
            self?.maybeStartVoice()
        }
        callKit.onAudioDeactivated = { [weak self] in
            self?.callAudioActive = false
            self?.wifiVoice.stop()
        }

    }

    func start() {
        wifi.start()
        if contacts.authorization == .authorized { contacts.load() }
    }

    func answerTest() { wifi.sendAnswer() }

    func makeCall() {
        let cleaned = dialString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        beginCall(number: cleaned, direction: .outgoing, name: contacts.resolveName(for: cleaned))
        callKit.startOutgoing(number: cleaned)
    }

    func endCall() { callKit.endCurrentCall() }

    func tapDialpad(_ digit: String) {
        if callStatus == "ACTIVE" {
            sendDTMFString(digit)
        } else {
            dialString.append(digit)
        }
    }

    func backspaceDialpad() {
        guard callStatus != "ACTIVE", !dialString.isEmpty else { return }
        dialString.removeLast()
    }

    func requestContacts() {
        contacts.requestAccessAndLoad()
    }

    func clearHistory() { history.clear() }
    func requestDeviceInfo() {
        log("[WIFI] J7 diagnostics are not implemented in Wi-Fi R1")
    }

    func sendDTMFString(_ digits: String) {
        for character in digits {
            switch character {
            case "0"..."9", "*", "#":
                // The supplied K7 source exposes the DTMF opcode and a second
                // parameter byte, but does not document the value mapping.
                // ASCII is used here as the least-assumptive terminal encoding.
                wifi.sendDTMF(UInt8(String(character).utf8.first!))
            default:
                break
            }
        }
    }

    private func handleWiFiControl(_ control: WiFiTransport.Control, payload: Data) {
        switch control {
        case .hello, .pong:
            log("[WIFI] CONTROL \(control)")

        case .incomingCall:
            let incomingNumber = String(data: payload, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !incomingNumber.isEmpty else {
                log("[WIFI] INCOMING missing number")
                return
            }
            handleIncomingNumber(incomingNumber)

        case .callActive:
            callStatus = "ACTIVE"
            log("[CALL] WIFI ACTIVE EVENT")
            if currentDirection == .outgoing {
                callKit.reportOutgoingConnected()
            }
            callKit.fulfillAnswerIfNeeded()
            beginCallIfNeeded(direction: currentDirection ?? .incoming)
            maybeStartVoice()

        case .callEnd:
            handleRemoteEnd()

        case .voiceOpen:
            remoteVoiceOpen = true
            log("[WIFI] VOICE OPEN EVENT")
            maybeStartVoice()

        case .voiceClose:
            remoteVoiceOpen = false
            log("[WIFI] VOICE CLOSE EVENT")
            wifiVoice.stop()

        case .callAnswer:
            // J7 should not normally send this command back to iPhone; log it only.
            log("[WIFI] Unexpected ANSWER from J7")

        case .makeCall:
            callStatus = "DIALING"
            log("[CALL] WIFI MAKE_CALL EVENT")
            callKit.reportOutgoingConnecting()

        case .hangup:
            handleRemoteEnd()

        case .dtmf:
            log("[WIFI] DTMF EVENT \(K7Protocol.hex(payload))")
        }
    }

    private func handleIncomingNumber(_ incomingNumber: String) {
        guard callStatus == "IDLE" || callStatus == "ENDED" else {
            log("[CALL] duplicate incoming ignored")
            return
        }
        guard !incomingNumber.isEmpty else {
            log("[CALL] INCOMING missing number")
            return
        }
        let name = resolveCallerNames ? contacts.resolveName(for: incomingNumber) : nil
        number = incomingNumber
        callerName = name ?? ""
        currentContactName = name
        currentDirection = .incoming
        callStartedAt = Date()
        callAudioActive = false
        remoteVoiceOpen = false
        callStatus = "RINGING"
        log("[CALL] INCOMING \(name.map { "\($0) / " } ?? "")\(incomingNumber)")
        callKit.reportIncoming(number: incomingNumber, callerName: name)
    }

    private func beginOutgoing(_ outgoingNumber: String) {
        number = outgoingNumber
        callerName = contacts.resolveName(for: outgoingNumber) ?? ""
        currentContactName = callerName.isEmpty ? nil : callerName
        dialString = ""
        beginCall(number: outgoingNumber, direction: .outgoing, name: currentContactName)
        wifi.sendMakeCall(number: outgoingNumber)
        callStatus = "DIALING"
    }

    private func beginCall(number: String, direction: CallDirection, name: String?) {
        self.number = number
        currentDirection = direction
        currentContactName = name
        callStartedAt = Date()
        callAudioActive = false
        remoteVoiceOpen = false
        if direction == .outgoing { callStatus = "DIALING" }
    }

    private func beginCallIfNeeded(direction: CallDirection) {
        if callStartedAt == nil { callStartedAt = Date() }
        currentDirection = direction
        if direction == .incoming && callerName.isEmpty { callerName = currentContactName ?? "" }
    }

    private func maybeStartVoice() {
        guard callStatus == "ACTIVE", callAudioActive else { return }
        wifiVoice.start()
    }

    private func endFromCallKit() {
        wifi.sendVoiceClose()
        wifi.sendHangup()
        wifiVoice.stop()
        remoteVoiceOpen = false
        finishHistory(direction: currentDirection ?? .outgoing)
        callStatus = "ENDED"
        callKit.clearCurrentCall()
    }

    private func handleRemoteEnd() {
        let wasRinging = callStatus == "RINGING"
        let direction = currentDirection ?? .incoming
        wifiVoice.stop()
        remoteVoiceOpen = false
        finishHistory(direction: wasRinging ? .missed : direction)
        callStatus = "ENDED"
        log("[CALL] END EVENT")
        callKit.reportRemoteEnd()
    }

    private func finishHistory(direction: CallDirection) {
        let duration = callStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        if !number.isEmpty {
            history.add(number: number, name: currentContactName, direction: direction, duration: duration)
            if direction == .missed, missedCallNotifications {
                notifications.sendMissedCall(number: number, name: currentContactName)
            }
        }
        callStartedAt = nil
        currentDirection = nil
        currentContactName = nil
        callAudioActive = false
    }

    func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logs.append("[\(stamp)] \(line)")
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }
}
