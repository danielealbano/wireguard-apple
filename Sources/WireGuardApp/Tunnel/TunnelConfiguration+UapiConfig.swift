// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

extension TunnelConfiguration {
    convenience init(fromUapiConfig uapiConfig: String, basedOn base: TunnelConfiguration? = nil) throws {
        var interfaceConfiguration: InterfaceConfiguration?
        var peerConfigurations = [PeerConfiguration]()

        var lines = uapiConfig.split(separator: "\n")
        lines.append("")

        var parserState = ParserState.inInterfaceSection
        var attributes = [String: String]()

        for line in lines {
            var key = ""
            var value = ""

            if !line.isEmpty {
                guard let equalsIndex = line.firstIndex(of: "=") else { throw ParseError.invalidLine(line) }
                key = String(line[..<equalsIndex])
                value = String(line[line.index(equalsIndex, offsetBy: 1)...])
            }

            if line.isEmpty || key == "public_key" {
                // Previous section has ended; process the attributes collected so far
                if parserState == .inInterfaceSection {
                    let interface = try TunnelConfiguration.collate(interfaceAttributes: attributes)
                    guard interfaceConfiguration == nil else { throw ParseError.multipleInterfaces }
                    interfaceConfiguration = interface
                    parserState = .inPeerSection
                } else if parserState == .inPeerSection {
                    let peer = try TunnelConfiguration.collate(peerAttributes: attributes)
                    peerConfigurations.append(peer)
                }
                attributes.removeAll()
                if line.isEmpty {
                    break
                }
            }

            if let presentValue = attributes[key] {
                if key == "allowed_ip" {
                    attributes[key] = presentValue + "," + value
                } else {
                    throw ParseError.multipleEntriesForKey(key)
                }
            } else {
                attributes[key] = value
            }

            let interfaceSectionKeys: Set<String> = ["private_key", "listen_port", "fwmark"]
            let peerSectionKeys: Set<String> = ["public_key", "preshared_key", "allowed_ip", "endpoint", "persistent_keepalive_interval",
                                               "last_handshake_time_sec", "last_handshake_time_nsec", "rx_bytes", "tx_bytes", "protocol_version",
                                               "transport", "ws_url", "wstunnel_target", "ws_bearer", "ws_mask", "ws_tls_ca", "ws_tls_cert",
                                               "ws_tls_key", "ws_tls_insecure", "ws_ping_interval", "ws_backoff_min", "ws_backoff_max"]

            if parserState == .inInterfaceSection {
                guard interfaceSectionKeys.contains(key) else {
                    throw ParseError.interfaceHasUnrecognizedKey(key)
                }
            }
            if parserState == .inPeerSection {
                guard peerSectionKeys.contains(key) else {
                    throw ParseError.peerHasUnrecognizedKey(key)
                }
            }
        }

        let peerPublicKeysArray = peerConfigurations.map { $0.publicKey }
        let peerPublicKeysSet = Set<PublicKey>(peerPublicKeysArray)
        if peerPublicKeysArray.count != peerPublicKeysSet.count {
            throw ParseError.multiplePeersWithSamePublicKey
        }

        interfaceConfiguration?.addresses = base?.interface.addresses ?? []
        interfaceConfiguration?.dns = base?.interface.dns ?? []
        interfaceConfiguration?.dnsSearch = base?.interface.dnsSearch ?? []
        interfaceConfiguration?.mtu = base?.interface.mtu

        if let interfaceConfiguration = interfaceConfiguration {
            self.init(name: base?.name, interface: interfaceConfiguration, peers: peerConfigurations)
        } else {
            throw ParseError.noInterface
        }
    }

    private static func collate(interfaceAttributes attributes: [String: String]) throws -> InterfaceConfiguration {
        guard let privateKeyString = attributes["private_key"] else {
            throw ParseError.interfaceHasNoPrivateKey
        }
        guard let privateKey = PrivateKey(hexKey: privateKeyString) else {
            throw ParseError.interfaceHasInvalidPrivateKey(privateKeyString)
        }
        var interface = InterfaceConfiguration(privateKey: privateKey)
        if let listenPortString = attributes["listen_port"] {
            guard let listenPort = UInt16(listenPortString) else {
                throw ParseError.interfaceHasInvalidListenPort(listenPortString)
            }
            if listenPort != 0 {
                interface.listenPort = listenPort
            }
        }
        return interface
    }

    private static func collate(peerAttributes attributes: [String: String]) throws -> PeerConfiguration {
        guard let publicKeyString = attributes["public_key"] else {
            throw ParseError.peerHasNoPublicKey
        }
        guard let publicKey = PublicKey(hexKey: publicKeyString) else {
            throw ParseError.peerHasInvalidPublicKey(publicKeyString)
        }
        var peer = PeerConfiguration(publicKey: publicKey)
        if let preSharedKeyString = attributes["preshared_key"] {
            guard let preSharedKey = PreSharedKey(hexKey: preSharedKeyString) else {
                throw ParseError.peerHasInvalidPreSharedKey(preSharedKeyString)
            }
            // TODO(zx2c4): does the compiler optimize this away?
            var accumulator: UInt8 = 0
            for index in 0..<preSharedKey.rawValue.count {
                accumulator |= preSharedKey.rawValue[index]
            }
            if accumulator != 0 {
                peer.preSharedKey = preSharedKey
            }
        }
        if let allowedIPsString = attributes["allowed_ip"] {
            var allowedIPs = [IPAddressRange]()
            for allowedIPString in allowedIPsString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
                guard let allowedIP = IPAddressRange(from: allowedIPString) else {
                    throw ParseError.peerHasInvalidAllowedIP(allowedIPString)
                }
                allowedIPs.append(allowedIP)
            }
            peer.allowedIPs = allowedIPs
        }
        if let endpointString = attributes["endpoint"] {
            guard let endpoint = Endpoint(from: endpointString) else {
                throw ParseError.peerHasInvalidEndpoint(endpointString)
            }
            peer.endpoint = endpoint
        }
        if let persistentKeepAliveString = attributes["persistent_keepalive_interval"] {
            guard let persistentKeepAlive = UInt16(persistentKeepAliveString) else {
                throw ParseError.peerHasInvalidPersistentKeepAlive(persistentKeepAliveString)
            }
            if persistentKeepAlive != 0 {
                peer.persistentKeepAlive = persistentKeepAlive
            }
        }
        if let rxBytesString = attributes["rx_bytes"] {
            guard let rxBytes = UInt64(rxBytesString) else {
                throw ParseError.peerHasInvalidTransferBytes(rxBytesString)
            }
            if rxBytes != 0 {
                peer.rxBytes = rxBytes
            }
        }
        if let txBytesString = attributes["tx_bytes"] {
            guard let txBytes = UInt64(txBytesString) else {
                throw ParseError.peerHasInvalidTransferBytes(txBytesString)
            }
            if txBytes != 0 {
                peer.txBytes = txBytes
            }
        }
        if let lastHandshakeTimeSecString = attributes["last_handshake_time_sec"] {
            var lastHandshakeTimeSince1970: TimeInterval = 0
            guard let lastHandshakeTimeSec = UInt64(lastHandshakeTimeSecString) else {
                throw ParseError.peerHasInvalidLastHandshakeTime(lastHandshakeTimeSecString)
            }
            if lastHandshakeTimeSec != 0 {
                lastHandshakeTimeSince1970 += Double(lastHandshakeTimeSec)
                if let lastHandshakeTimeNsecString = attributes["last_handshake_time_nsec"] {
                    guard let lastHandshakeTimeNsec = UInt64(lastHandshakeTimeNsecString) else {
                        throw ParseError.peerHasInvalidLastHandshakeTime(lastHandshakeTimeNsecString)
                    }
                    lastHandshakeTimeSince1970 += Double(lastHandshakeTimeNsec) / 1000000000.0
                }
                peer.lastHandshakeTime = Date(timeIntervalSince1970: lastHandshakeTimeSince1970)
            }
        }
        if let transportString = attributes["transport"] {
            switch transportString {
            case "udp":
                break
            case "websocket":
                peer.wsMode = .websocket
            case "wstunnel":
                peer.wsMode = .wstunnel
            default:
                throw ParseError.peerHasInvalidTransport(transportString)
            }
        }
        if let wsUrlString = attributes["ws_url"] {
            guard let wsUrl = WsUrl(from: wsUrlString) else {
                throw ParseError.peerHasInvalidEndpoint(wsUrlString)
            }
            peer.wsUrl = wsUrl
        }
        if let wstunnelTargetString = attributes["wstunnel_target"] {
            guard Endpoint(from: wstunnelTargetString) != nil else {
                throw ParseError.peerHasInvalidWsTunnelTarget(wstunnelTargetString)
            }
            peer.wstunnelTarget = wstunnelTargetString
        }
        if let wsBearerString = attributes["ws_bearer"] {
            guard !wsBearerString.isEmpty else { throw ParseError.peerHasInvalidWsBearer }
            peer.wsBearer = wsBearerString
        }
        if let wsMaskString = attributes["ws_mask"] {
            peer.wsMask = wsMaskString == "true"
        }
        peer.wsTlsCa = attributes["ws_tls_ca"]
        peer.wsTlsCert = attributes["ws_tls_cert"]
        peer.wsTlsKey = attributes["ws_tls_key"]
        if let wsTlsInsecureString = attributes["ws_tls_insecure"] {
            peer.wsTlsInsecure = wsTlsInsecureString == "true"
        }
        if let wsPingIntervalString = attributes["ws_ping_interval"] {
            guard let millis = UInt32(wsPingIntervalString) else {
                throw ParseError.peerHasInvalidWsMillis(wsPingIntervalString)
            }
            peer.wsPingIntervalMs = millis == 0 ? nil : millis
        }
        if let wsBackoffMinString = attributes["ws_backoff_min"] {
            guard let millis = UInt32(wsBackoffMinString) else {
                throw ParseError.peerHasInvalidWsMillis(wsBackoffMinString)
            }
            peer.wsBackoffMinMs = millis == 0 ? nil : millis
        }
        if let wsBackoffMaxString = attributes["ws_backoff_max"] {
            guard let millis = UInt32(wsBackoffMaxString) else {
                throw ParseError.peerHasInvalidWsMillis(wsBackoffMaxString)
            }
            peer.wsBackoffMaxMs = millis == 0 ? nil : millis
        }
        return peer
    }
}
