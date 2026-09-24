// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

public struct PeerConfiguration {
    public var publicKey: PublicKey
    public var preSharedKey: PreSharedKey?
    public var allowedIPs = [IPAddressRange]()
    public var endpoint: Endpoint?
    public var persistentKeepAlive: UInt16?
    public var rxBytes: UInt64?
    public var txBytes: UInt64?
    public var lastHandshakeTime: Date?
    public var wsMode: WsMode?
    public var wsUrl: WsUrl?
    public var wstunnelTarget: String?
    public var wsBearer: String?
    public var wsMask = false
    public var wsTlsCa: String?
    public var wsTlsCert: String?
    public var wsTlsKey: String?
    public var wsTlsInsecure = false
    public var wsPingIntervalMs: UInt32?
    public var wsBackoffMinMs: UInt32?
    public var wsBackoffMaxMs: UInt32?

    /// The UAPI `transport=` value for this peer: `udp`, `websocket`, or `wstunnel`.
    public var uapiTransport: String {
        return wsMode?.rawValue ?? "udp"
    }

    public init(publicKey: PublicKey) {
        self.publicKey = publicKey
    }
}

extension PeerConfiguration: Equatable {
    public static func == (lhs: PeerConfiguration, rhs: PeerConfiguration) -> Bool {
        return lhs.publicKey == rhs.publicKey &&
            lhs.preSharedKey == rhs.preSharedKey &&
            Set(lhs.allowedIPs) == Set(rhs.allowedIPs) &&
            lhs.endpoint == rhs.endpoint &&
            lhs.persistentKeepAlive == rhs.persistentKeepAlive &&
            lhs.wsMode == rhs.wsMode &&
            lhs.wsUrl == rhs.wsUrl &&
            lhs.wstunnelTarget == rhs.wstunnelTarget &&
            lhs.wsBearer == rhs.wsBearer &&
            lhs.wsMask == rhs.wsMask &&
            lhs.wsTlsCa == rhs.wsTlsCa &&
            lhs.wsTlsCert == rhs.wsTlsCert &&
            lhs.wsTlsKey == rhs.wsTlsKey &&
            lhs.wsTlsInsecure == rhs.wsTlsInsecure &&
            lhs.wsPingIntervalMs == rhs.wsPingIntervalMs &&
            lhs.wsBackoffMinMs == rhs.wsBackoffMinMs &&
            lhs.wsBackoffMaxMs == rhs.wsBackoffMaxMs
    }
}

extension PeerConfiguration: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
        hasher.combine(preSharedKey)
        hasher.combine(Set(allowedIPs))
        hasher.combine(endpoint)
        hasher.combine(persistentKeepAlive)
        hasher.combine(wsMode)
        hasher.combine(wsUrl)
        hasher.combine(wstunnelTarget)
        hasher.combine(wsBearer)
        hasher.combine(wsMask)
        hasher.combine(wsTlsCa)
        hasher.combine(wsTlsCert)
        hasher.combine(wsTlsKey)
        hasher.combine(wsTlsInsecure)
        hasher.combine(wsPingIntervalMs)
        hasher.combine(wsBackoffMinMs)
        hasher.combine(wsBackoffMaxMs)
    }
}
