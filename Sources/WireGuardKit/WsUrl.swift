// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

/// A per-peer WebSocket URL (`ws(s)://host:port[/path]`). Stored verbatim; the host and port are
/// also exposed for building the routable `Endpoint`. The scheme must be `ws` or `wss`
/// (case-insensitive), the host is required, and an explicit port is required (parity with the
/// routable endpoint). A path is optional and preserved verbatim; a query/fragment is accepted
/// only after a path, and userinfo is rejected (the wireguard-tools fork's acceptance set — the
/// byte-compat authority).
public struct WsUrl {
    public let urlString: String
    public let host: String
    public let port: UInt16

    public init?(from string: String) {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              components.user == nil, components.password == nil,
              var host = components.host, !host.isEmpty,
              let portValue = components.port,
              let port = UInt16(exactly: portValue) else { return nil }
        if components.path.isEmpty && (components.query != nil || components.fragment != nil) {
            return nil
        }
        // Some Foundation versions return an IPv6 literal host WITH its surrounding brackets;
        // strip them so `host` is the bare literal and `endpoint()` brackets exactly once.
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count > 1 {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        self.urlString = string
        self.host = host
        self.port = port
    }

    public static func isWsUrl(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        return lowercased.hasPrefix("ws://") || lowercased.hasPrefix("wss://")
    }

    /// The routable endpoint (`host:port`) dialed for this URL, exactly as a UDP endpoint would
    /// be parsed. IPv6 literal hosts are (re-)bracketed.
    public func endpoint() -> Endpoint? {
        let hostPort = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        return Endpoint(from: hostPort)
    }
}

extension WsUrl: Equatable {
    public static func == (lhs: WsUrl, rhs: WsUrl) -> Bool {
        return lhs.urlString == rhs.urlString
    }
}

extension WsUrl: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(urlString)
    }
}
