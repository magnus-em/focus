import Foundation
import MultipeerConnectivity

/// Same-wifi instant timer state broadcast over Bonjour + Apple's
/// MultipeerConnectivity. Used as a fast-path on top of the
/// CloudKit-backed `TimerStateSync` — when both devices are on the
/// same local network, state changes propagate in tens of ms.
///
/// When peers can't see each other (different networks, or local-network
/// permission denied), nothing breaks: CloudKit eventually delivers the
/// same update via SwiftData. Local broadcast is purely an accelerator.
public final class LocalTimerBroadcast: NSObject, ObservableObject {
    /// Bonjour service type. Must be 1-15 chars, alphanumeric + hyphen.
    /// Apple advertises as `_focus-timer._tcp.local.`
    public static let serviceType = "focus-timer"

    public struct Message: Codable, Sendable {
        public let deviceID: String
        public let phase: String       // "idle" | "work" | "breakPhase"
        public let isRunning: Bool
        public let totalSeconds: Double
        public let label: String
        public let breakKindsRaw: [String]
        public let startTime: Date?
        public let endTime: Date?
        public let remainingSeconds: Double
        public let timestamp: Date

        public init(deviceID: String, phase: String, isRunning: Bool,
                    totalSeconds: Double, label: String, breakKindsRaw: [String],
                    startTime: Date?, endTime: Date?,
                    remainingSeconds: Double, timestamp: Date) {
            self.deviceID = deviceID
            self.phase = phase
            self.isRunning = isRunning
            self.totalSeconds = totalSeconds
            self.label = label
            self.breakKindsRaw = breakKindsRaw
            self.startTime = startTime
            self.endTime = endTime
            self.remainingSeconds = remainingSeconds
            self.timestamp = timestamp
        }
    }

    public let deviceID: String
    private let peer: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    /// Called on the main thread when a peer sends us state.
    public var onMessage: ((Message) -> Void)?

    /// Called on the main thread the moment a new peer transitions to
    /// `.connected`. The engine should respond by re-broadcasting its
    /// current state so the new peer learns about an already-running
    /// session that started BEFORE Multipeer was reachable.
    ///
    /// Without this, the canonical bug is: device A starts a timer (no
    /// peers connected → `mpSendSkipNoPeers`), then device B launches and
    /// connects to A via Multipeer. B receives no state. CloudKit's silent
    /// push may or may not arrive on B (often doesn't on macOS), so B
    /// stays idle while A is running for an unbounded amount of time.
    public var onPeerConnected: (() -> Void)?

    public init(deviceID: String) {
        self.deviceID = deviceID

        #if os(macOS)
        let displayName = "Mac-\(deviceID.prefix(8))"
        #else
        let displayName = "iPad-\(deviceID.prefix(8))"
        #endif

        self.peer = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        self.advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: Self.serviceType)
        self.browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)

        super.init()

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self

        #if !targetEnvironment(simulator)
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        #endif
    }

    deinit {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    public func send(_ message: Message) {
        guard !session.connectedPeers.isEmpty else {
            SyncLog.event("mpSendSkipNoPeers", [
                "phase": message.phase,
                "isRunning": message.isRunning,
            ])
            return
        }
        guard let data = try? JSONEncoder().encode(message) else { return }
        SyncLog.event("mpSend", [
            "phase": message.phase,
            "isRunning": message.isRunning,
            "totalSeconds": message.totalSeconds,
            "label": message.label,
            "startTime": SyncLog.opt(message.startTime),
            "endTime": SyncLog.opt(message.endTime),
            "remaining": message.remainingSeconds,
            "peers": session.connectedPeers.count,
        ])
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    public var connectedPeerCount: Int { session.connectedPeers.count }
}

// MARK: - Delegates

extension LocalTimerBroadcast: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // Connection state changes — log to console for debugging.
        let stateName: String
        switch state {
        case .notConnected: stateName = "notConnected"
        case .connecting:   stateName = "connecting"
        case .connected:    stateName = "connected"
        @unknown default:   stateName = "unknown"
        }
        SyncLog.event("mpPeerState", [
            "peer": peerID.displayName,
            "state": stateName,
            "totalPeers": session.connectedPeers.count,
        ])
        if state == .connected {
            // New peer reachable — let the engine push current state so the
            // peer doesn't miss a session that started before connection.
            let cb = onPeerConnected
            DispatchQueue.main.async { cb?() }
        }
        // NOTE: do NOT stop/restart advertiser+browser on disconnect.
        // MCNearbyServiceBrowser/Advertiser drive an internal NSNetService
        // on its own sync queue; rapid stop+start leaves a stale
        // CFRunLoopSource that crashes the next runloop iteration with
        // `_CFAssertMismatchedTypeID` inside `_BrowserCancel`. The
        // advertiser and browser are already running continuously —
        // when the peer comes back, `foundPeer` fires naturally.
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let msg = try? JSONDecoder().decode(Message.self, from: data) else {
            SyncLog.event("mpRecvDecodeFail", ["peer": peerID.displayName])
            return
        }
        guard msg.deviceID != deviceID else { return }   // ignore self-echo
        SyncLog.event("mpRecv", [
            "peer": peerID.displayName,
            "fromDevice": String(msg.deviceID.prefix(8)),
            "phase": msg.phase,
            "isRunning": msg.isRunning,
            "totalSeconds": msg.totalSeconds,
            "label": msg.label,
            "startTime": SyncLog.opt(msg.startTime),
            "endTime": SyncLog.opt(msg.endTime),
            "remaining": msg.remainingSeconds,
            "msgTimestamp": msg.timestamp,
        ])
        DispatchQueue.main.async { [weak self] in
            self?.onMessage?(msg)
        }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension LocalTimerBroadcast: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Auto-accept invitations from peers (we authenticate by sharing the
        // same iCloud account anyway — the data is harmless either way).
        invitationHandler(true, session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("[LocalTimerBroadcast] failed to start advertising: \(error)")
    }
}

extension LocalTimerBroadcast: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser,
                        foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String : String]?) {
        // Only one side needs to invite — use deterministic ordering by
        // displayName so we don't both try to invite each other.
        guard peerID.displayName > peer.displayName else { return }
        guard !session.connectedPeers.contains(peerID) else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[LocalTimerBroadcast] failed to start browsing: \(error)")
    }
}
