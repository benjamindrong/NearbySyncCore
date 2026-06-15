import Foundation

public struct TrustedPeer: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public var trustedAt: Date
    public var lastSeenAt: Date?

    public init(id: String, displayName: String, trustedAt: Date = Date(), lastSeenAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.trustedAt = trustedAt
        self.lastSeenAt = lastSeenAt
    }
}

public protocol TrustedPeerStore: Sendable {
    func trustedPeers() -> [TrustedPeer]
    func trust(_ peer: TrustedPeer)
    func forget(peerID: String)
    func contains(peerID: String) -> Bool
    func markSeen(peerID: String, at date: Date)
}

public final class UserDefaultsTrustedPeerStore: TrustedPeerStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard, key: String = "trustedPeers") {
        self.defaults = defaults
        self.key = key
    }

    public func trustedPeers() -> [TrustedPeer] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? decoder.decode([TrustedPeer].self, from: data)) ?? []
    }

    public func trust(_ peer: TrustedPeer) {
        var peers = trustedPeers().filter { $0.id != peer.id }
        peers.append(peer)
        save(peers)
    }

    public func forget(peerID: String) {
        save(trustedPeers().filter { $0.id != peerID })
    }

    public func contains(peerID: String) -> Bool {
        trustedPeers().contains { $0.id == peerID }
    }

    public func markSeen(peerID: String, at date: Date = Date()) {
        var peers = trustedPeers()
        guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return }
        peers[index].lastSeenAt = date
        save(peers)
    }

    private func save(_ peers: [TrustedPeer]) {
        guard let data = try? encoder.encode(peers) else { return }
        defaults.set(data, forKey: key)
    }
}
