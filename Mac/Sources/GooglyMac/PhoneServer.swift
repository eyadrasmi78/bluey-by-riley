import Foundation
import AppKit
import Network
import GooglyShared

/// Advertises the Mac on the local network and streams face updates to any phone that connects.
final class PhoneServer {
    private var listener: NWListener?
    private var phones: [ObjectIdentifier: (link: LineConnection, name: String?)] = [:]
    private var pending: [ObjectIdentifier: LineConnection] = [:]
    private var lastSent: FaceState?
    private var lastSentAt = Date.distantPast
    private var restartWork: DispatchWorkItem?
    /// The short-lived pairing listener (menu "Pair a Phone…"), and its expiry timer.
    private var pairListener: NWListener?
    private var pairExpiry: DispatchWorkItem?

    /// Called with the names of connected phones whenever that list changes.
    var onPhonesChanged: (([String]) -> Void)?

    /// Called when a phone asks for something. The second argument replies to that phone.
    var onRequest: ((Packet, @escaping (Packet) -> Void) -> Void)?

    var phoneNames: [String] { phones.values.map { $0.name ?? "iPhone" } }

    /// The long-term key phones prove themselves with. Created once, rotated via "Unpair All Phones".
    static func linkKey() -> Data {
        if let saved = Keychain.get(.linkKey), let key = Data(base64Encoded: saved) { return key }
        let key = GooglySecurity.newLinkKey()
        Keychain.set(.linkKey, key.base64EncodedString())
        return key
    }

    /// Open the pairing window (menu "Pair a Phone…"): a short-lived second listener whose TLS PSK
    /// is derived from the pairing code. Whoever types the code gets the long-term link key.
    func beginPairing(code: String, seconds: TimeInterval = 600) {
        NSLog("Googly: pairing window requested")
        endPairing()
        pairingFailures = 0
        pairingDelivered = false
        do {
            let listener = try NWListener(using: GooglySecurity.parameters(key: GooglySecurity.key(fromPairingCode: code),
                                                                           identity: GooglySecurity.pairIdentity))
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: GooglyService.pairType)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                guard self.pairingClients.count < 2 else { connection.cancel(); return }  // no pile-ups of guesses
                let link = LineConnection(connection)
                var handshakeDone = false
                var counted = false
                link.onState = { [weak self, weak link] state in
                    guard let self else { return }
                    switch state {
                    case .ready: handshakeDone = true
                    case .failed, .cancelled:
                        if let link { self.pairingClients.removeAll { $0 === link } }
                        // A wrong code fails the TLS handshake; a stalled attempt is cancelled before it is
                        // ready. Both count. Five misses and the window closes.
                        guard !handshakeDone, !counted, self.pairListener != nil else { return }
                        counted = true
                        self.pairingFailures += 1
                        if self.pairingFailures >= 5 { self.endPairing() }
                    default: break
                    }
                }
                link.onPacket = { [weak self, weak link] packet in
                    guard let self, packet.command == "pair", !self.pairingDelivered,
                          let phonePublic = packet.text.flatMap({ Data(base64Encoded: $0) }),
                          let sealed = GooglySecurity.sealLinkKey(Self.linkKey(), forPhonePublicKey: phonePublic) else { return }
                    // Single use: the first successful request gets the key, and the door shuts immediately.
                    self.pairingDelivered = true
                    self.pairListener?.cancel()
                    self.pairListener = nil
                    link?.send(Packet(command: "paired", callID: packet.callID, text: sealed))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.endPairing() }
                }
                link.start()
                self.pairingClients.append(link)
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak link] in link?.cancel() }
            }
            listener.stateUpdateHandler = { state in
                NSLog("Googly: pairing listener state: \(state)")
                if case .failed(let error) = state {
                    NSLog("Googly: pairing listener failed: \(error)")
                    DispatchQueue.main.async { NSSound.beep() }
                }
            }
            listener.start(queue: .main)
            pairListener = listener
            let work = DispatchWorkItem { [weak self] in self?.endPairing() }
            pairExpiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        } catch {
            NSLog("Googly: could not start pairing listener: \(error)")
            DispatchQueue.main.async { NSSound.beep() }
        }
    }

    private var pairingClients: [LineConnection] = []
    private var pairingFailures = 0
    private var pairingDelivered = false

    /// Close the pairing window (also called when it expires).
    func endPairing() {
        pairExpiry?.cancel()
        pairExpiry = nil
        pairListener?.cancel()
        pairListener = nil
        pairingClients.forEach { $0.cancel() }
        pairingClients = []
    }

    func start() {
        do {
            let parameters = GooglySecurity.parameters(key: Self.linkKey(), identity: GooglySecurity.linkIdentity)
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: GooglyService.type)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.scheduleRestart() }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("Googly: could not start listener: \(error)")
            scheduleRestart()
        }
    }

    /// Drops everyone and re-listens (used when the link key rotates).
    func restart() { scheduleRestart() }

    private func scheduleRestart() {
        listener?.cancel()
        listener = nil
        // Key rotation (or a listener failure) must also drop phones that are already connected:
        // an established TLS session would otherwise keep working with the old key.
        phones.values.forEach { $0.link.cancel() }
        pending.values.forEach { $0.cancel() }
        phones = [:]
        pending = [:]
        endPairing()
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func accept(_ connection: NWConnection) {
        let link = LineConnection(connection)
        let id = ObjectIdentifier(link)
        pending[id] = link  // keep it alive until it is ready
        link.onState = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .ready:
                self.pending[id] = nil
                self.phones[id] = (link, nil)
                link.send(Packet(hello: Host.current().localizedName ?? "Mac"))
                if let face = self.lastSent { link.send(Packet(face: face)) }
                self.onPhonesChanged?(self.phoneNames)
            case .failed, .cancelled:
                self.pending[id] = nil
                self.phones[id] = nil
                self.onPhonesChanged?(self.phoneNames)
            default:
                break
            }
        }
        link.onPacket = { [weak self, weak link] packet in
            guard let self, let link, self.phones[id] != nil else { return }
            if let name = packet.hello {
                self.phones[id]?.name = name
                self.onPhonesChanged?(self.phoneNames)
            }
            if packet.command != nil {
                self.onRequest?(packet) { [weak link] response in link?.send(response) }
            }
        }
        link.start()
    }

    /// Sends a command to every phone (e.g. "wake", "sleep").
    func broadcast(_ packet: Packet) {
        for phone in phones.values { phone.link.send(packet) }
    }

    /// Sends the face to every phone, skipping updates too small to see.
    func send(_ face: FaceState) {
        // Resend at least once a second even when nothing changed, so the phone knows the Mac is still driving.
        let now = Date()
        if let last = lastSent, now.timeIntervalSince(lastSentAt) < 1,
           last.mood == face.mood,
           abs(last.gazeX - face.gazeX) < 0.004,
           abs(last.gazeY - face.gazeY) < 0.004,
           abs(last.talk - face.talk) < 0.02 {
            return
        }
        lastSent = face
        lastSentAt = now
        for phone in phones.values { phone.link.send(Packet(face: face)) }
    }
}
