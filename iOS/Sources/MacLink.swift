import Foundation
import CryptoKit
import Network
import Security
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Finds the Mac app on the local network with Bonjour and keeps a connection open.
final class MacLink: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var macName: String?
    /// Every Mac running Bluey on this Wi-Fi, by its Bonjour name.
    @Published private(set) var macs: [String] = []
    /// The Mac the phone is linked to (or trying to link to).
    @Published private(set) var currentMac: String?
    /// The Mac picked in the speaker panel. Remembered, so the phone goes back to it on launch.
    @Published private(set) var preferredMac: String? = UserDefaults.standard.string(forKey: "preferredMac")
    /// The Mac that needs a pairing code before it will talk to us (encryption is mandatory now).
    @Published private(set) var needsPairingFor: String?
    /// True after a pairing attempt failed (wrong code, or the window closed on the Mac).
    @Published private(set) var pairingFailed = false
    /// Commands from the Mac, like "wake" and "sleep".
    var onCommand: ((String) -> Void)?
    private var waiting: [String: (Packet?) -> Void] = [:]

    // MARK: Pairing

    private var pairBrowser: NWBrowser?
    private var pairLink: LineConnection?
    private var pairingMac: String?

    /// Link keys live in the iOS Keychain (not UserDefaults, which ends up in plain backups). Readable after the
    /// first unlock so background sessions can reconnect with the screen locked.
    private static var linkKeys: [String: String] {
        get {
            if let data = readKeychain(), let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] { return dict }
            // One-time move from the old UserDefaults storage.
            if let old = UserDefaults.standard.dictionary(forKey: "linkKeys") as? [String: String], !old.isEmpty {
                writeKeychain(old)
                UserDefaults.standard.removeObject(forKey: "linkKeys")
                return old
            }
            return [:]
        }
        set { writeKeychain(newValue) }
    }

    private static let keychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "co.visionairy.googly.linkkeys",
        kSecAttrAccount as String: "linkKeys",
    ]

    private static func readKeychain() -> Data? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private static func writeKeychain(_ dict: [String: String]) {
        SecItemDelete(keychainQuery as CFDictionary)
        guard !dict.isEmpty, let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        var item = keychainQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func linkKey(for mac: String) -> Data? {
        linkKeys[mac].flatMap { Data(base64Encoded: $0) }
    }

    /// Starts pairing: find the Mac's pairing service, prove the pairing code (TLS-PSK), and
    /// collect the long-term key it's handing out while its menu window is open.
    func pair(mac: String, code: String) {
        pairingFailed = false
        needsPairingFor = nil
        pairingMac = mac
        pairLink?.cancel()
        pairLink = nil
        pairBrowser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: GooglyService.pairType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] (results: Set<NWBrowser.Result>, _) in
            guard let self, self.pairLink == nil, let pairingMac = self.pairingMac,
                  let result = results.first(where: { Self.serviceName($0) == pairingMac }) else { return }
            let link = LineConnection(NWConnection(to: result.endpoint,
                                                   using: GooglySecurity.parameters(key: GooglySecurity.key(fromPairingCode: code),
                                                                                    identity: GooglySecurity.pairIdentity)))
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()  // the link key comes back sealed to this
            link.onState = { [weak self, weak link] state in
                guard let self, let link else { return }
                switch state {
                case .ready:
                    let offer = Packet(command: "pair", text: ephemeral.publicKey.rawRepresentation.base64EncodedString())
                    self.request(packet: offer, on: link) { [weak self] reply in
                        guard let self else { return }
                        if let key = reply?.text.flatMap({ GooglySecurity.openLinkKey($0, with: ephemeral) }) {
                            var keys = Self.linkKeys
                            keys[mac] = key.base64EncodedString()
                            Self.linkKeys = keys
                            self.endPairing()
                            self.link?.cancel()
                            self.link = nil
                            self.choose(mac)
                        } else {
                            self.pairingFailed = true
                            self.needsPairingFor = mac
                            self.endPairing()
                        }
                    }
                case .failed, .cancelled:
                    guard self.pairLink === link else { return }
                    self.pairingFailed = true
                    self.needsPairingFor = mac
                    self.endPairing()
                default:
                    break
                }
            }
            link.start()
            self.pairLink = link
        }
        pairBrowser = browser
        browser.start(queue: .main)
    }

    private func request(packet: Packet, on link: LineConnection, _ done: @escaping (Packet?) -> Void) {
        let id = UUID().uuidString
        pairWaiting[id] = done
        var packet = packet
        packet.callID = id
        link.onPacket = { [weak self] packet in
            guard let self, let callID = packet.callID, let done = self.pairWaiting.removeValue(forKey: callID) else { return }
            done(packet)
        }
        link.send(packet)
    }

    private var pairWaiting: [String: (Packet?) -> Void] = [:]

    private func endPairing() {
        pairingMac = nil
        pairBrowser?.cancel()
        pairBrowser = nil
        pairLink?.cancel()
        pairLink = nil
        pairWaiting = [:]
    }

    /// Forget the stored key: the Mac will want the code again.
    func unpair(_ mac: String) {
        var keys = Self.linkKeys
        keys.removeValue(forKey: mac)
        Self.linkKeys = keys
        if currentMac == mac { link?.cancel(); link = nil; connectIfNeeded() }
    }

    var onFace: ((FaceState) -> Void)?

    private var browser: NWBrowser?
    private var link: LineConnection?
    private var retry: DispatchWorkItem?
    /// Handshake failures per Mac: a rotated key fails forever, so after a few we ask to re-pair.
    private var failures: [String: Int] = [:]

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: GooglyService.type, domain: nil), using: .googly)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.macs = results.compactMap(Self.serviceName).sorted()
            // Move over when the picked Mac shows up while linked to a different one.
            if let preferred = self.preferredMac, self.currentMac != preferred, self.macs.contains(preferred) {
                self.link?.cancel()
            }
            self.connectIfNeeded()
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.restart() }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        retry?.cancel()
        browser?.cancel()
        browser = nil
        link?.cancel()
        link = nil
        connected = false
    }

    private func restart() {
        stop()
        scheduleRetry()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.browser == nil { self.start() } else { self.connectIfNeeded() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Switches to another Mac and remembers the choice.
    func choose(_ name: String) {
        preferredMac = name
        UserDefaults.standard.set(name, forKey: "preferredMac")
        if currentMac != name { link?.cancel() }
        connectIfNeeded()
    }

    private static func serviceName(_ result: NWBrowser.Result) -> String? {
        if case let .service(name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func connectIfNeeded() {
        guard link == nil, let results = browser?.browseResults, !results.isEmpty else { return }
        let result = results.first { Self.serviceName($0) == preferredMac } ?? results.first!
        let name = Self.serviceName(result)
        currentMac = name
        let params: NWParameters
        if let name, let key = Self.linkKey(for: name) {
            params = GooglySecurity.parameters(key: key, identity: GooglySecurity.linkIdentity)
        } else {
            // No key for this Mac: it will refuse the TLS handshake. Ask the user for the code.
            needsPairingFor = name
            return
        }
        needsPairingFor = nil
        let link = LineConnection(NWConnection(to: result.endpoint, using: params))
        link.onState = { [weak self, weak link] state in
            guard let self, let link, link === self.link else { return }
            switch state {
            case .ready:
                if let name = self.currentMac { self.failures[name] = 0 }
                self.connected = true
                link.send(Packet(hello: Self.deviceName))
            case .failed, .cancelled:
                if let name = self.currentMac {
                    self.failures[name, default: 0] += 1
                    // A Mac that rotated its key ("Unpair All Phones") will never accept this one again.
                    if self.failures[name, default: 0] >= 4, Self.linkKey(for: name) != nil {
                        self.needsPairingFor = name
                    }
                }
                self.connected = false
                let waiting = self.waiting
                self.waiting = [:]
                waiting.values.forEach { $0(nil) }
                self.macName = nil
                self.link = nil
                self.scheduleRetry()
            case .waiting:
                link.cancel()
            default:
                break
            }
        }
        link.onPacket = { [weak self] packet in
            if let name = packet.hello { self?.macName = name }
            if let face = packet.face { self?.onFace?(face) }
            guard let self, let command = packet.command else { return }
            if let callID = packet.callID, let done = self.waiting.removeValue(forKey: callID) {
                done(packet)
            } else {
                self.onCommand?(command)
            }
        }
        self.link = link
        link.start()
    }

    func send(_ packet: Packet) {
        link?.send(packet)
    }

    /// Sends a request to the Mac and calls back with its reply (nil if the Mac went away).
    func request(_ packet: Packet, _ done: @escaping (Packet?) -> Void) {
        guard let link, connected else { done(nil); return }
        var packet = packet
        let id = UUID().uuidString
        packet.callID = id
        waiting[id] = done
        link.send(packet)
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Phone"
        #endif
    }
}
