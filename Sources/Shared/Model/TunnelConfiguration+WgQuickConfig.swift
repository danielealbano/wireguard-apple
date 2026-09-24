// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

extension TunnelConfiguration {

    enum ParserState {
        case inInterfaceSection
        case inPeerSection
        case notInASection
    }

    enum ParseError: Error {
        case invalidLine(String.SubSequence)
        case noInterface
        case multipleInterfaces
        case interfaceHasNoPrivateKey
        case interfaceHasInvalidPrivateKey(String)
        case interfaceHasInvalidListenPort(String)
        case interfaceHasInvalidAddress(String)
        case interfaceHasInvalidDNS(String)
        case interfaceHasInvalidMTU(String)
        case interfaceHasUnrecognizedKey(String)
        case peerHasNoPublicKey
        case peerHasInvalidPublicKey(String)
        case peerHasInvalidPreSharedKey(String)
        case peerHasInvalidAllowedIP(String)
        case peerHasInvalidEndpoint(String)
        case peerHasInvalidPersistentKeepAlive(String)
        case peerHasInvalidTransferBytes(String)
        case peerHasInvalidLastHandshakeTime(String)
        case peerHasUnrecognizedKey(String)
        case multiplePeersWithSamePublicKey
        case multipleEntriesForKey(String)
        case peerHasInvalidWsMode(String)
        case peerHasInvalidWsTunnelTarget(String)
        case peerHasInvalidWsBearer // carries no value: the bearer is a secret
        case peerHasInvalidWsBoolean(String)
        case peerHasInvalidWsMillis(String)
        case peerHasEmptyWsValue(String) // offending key (canonical spelling)
        case peerHasInvalidTransport(String)
        case peerWsUrlRequiresWsMode
        case peerWsModeForbidsHostPortEndpoint
        case peerInboundWstunnelForbidden
        case peerWstunnelRequiresTarget
        case peerWsTunnelTargetForbidden
        case peerHasWsKeyWithoutWsMode(String) // offending key (canonical spelling)
    }

    convenience init(fromWgQuickConfig wgQuickConfig: String, called name: String? = nil) throws {
        var interfaceConfiguration: InterfaceConfiguration?
        var peerConfigurations = [PeerConfiguration]()

        let lines = wgQuickConfig.split { $0.isNewline }

        var parserState = ParserState.notInASection
        var attributes = [String: String]()

        for (lineIndex, line) in lines.enumerated() {
            var trimmedLine: String
            if let commentRange = line.range(of: "#") {
                trimmedLine = String(line[..<commentRange.lowerBound])
            } else {
                trimmedLine = String(line)
            }

            trimmedLine = trimmedLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedLine = trimmedLine.lowercased()

            if !trimmedLine.isEmpty {
                if let equalsIndex = trimmedLine.firstIndex(of: "=") {
                    // Line contains an attribute
                    let keyWithCase = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = keyWithCase.lowercased()
                    let value = trimmedLine[trimmedLine.index(equalsIndex, offsetBy: 1)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    let keysWithMultipleEntriesAllowed: Set<String> = ["address", "allowedips", "dns"]
                    if let presentValue = attributes[key] {
                        if keysWithMultipleEntriesAllowed.contains(key) {
                            attributes[key] = presentValue + "," + value
                        } else {
                            throw ParseError.multipleEntriesForKey(keyWithCase)
                        }
                    } else {
                        attributes[key] = value
                    }
                    let interfaceSectionKeys: Set<String> = ["privatekey", "listenport", "address", "dns", "mtu"]
                    let peerSectionKeys: Set<String> = ["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive",
                                                       "wsmode", "wstunneltarget", "wsbearer", "wsmask", "wstlsca", "wstlscert",
                                                       "wstlskey", "wstlsinsecure", "wspinginterval", "wsbackoffmin", "wsbackoffmax"]
                    if parserState == .inInterfaceSection {
                        guard interfaceSectionKeys.contains(key) else {
                            throw ParseError.interfaceHasUnrecognizedKey(keyWithCase)
                        }
                    } else if parserState == .inPeerSection {
                        guard peerSectionKeys.contains(key) else {
                            throw ParseError.peerHasUnrecognizedKey(keyWithCase)
                        }
                    }
                } else if lowercasedLine != "[interface]" && lowercasedLine != "[peer]" {
                    throw ParseError.invalidLine(line)
                }
            }

            let isLastLine = lineIndex == lines.count - 1

            if isLastLine || lowercasedLine == "[interface]" || lowercasedLine == "[peer]" {
                // Previous section has ended; process the attributes collected so far
                if parserState == .inInterfaceSection {
                    let interface = try TunnelConfiguration.collate(interfaceAttributes: attributes)
                    guard interfaceConfiguration == nil else { throw ParseError.multipleInterfaces }
                    interfaceConfiguration = interface
                } else if parserState == .inPeerSection {
                    let peer = try TunnelConfiguration.collate(peerAttributes: attributes)
                    peerConfigurations.append(peer)
                }
            }

            if lowercasedLine == "[interface]" {
                parserState = .inInterfaceSection
                attributes.removeAll()
            } else if lowercasedLine == "[peer]" {
                parserState = .inPeerSection
                attributes.removeAll()
            }
        }

        let peerPublicKeysArray = peerConfigurations.map { $0.publicKey }
        let peerPublicKeysSet = Set<PublicKey>(peerPublicKeysArray)
        if peerPublicKeysArray.count != peerPublicKeysSet.count {
            throw ParseError.multiplePeersWithSamePublicKey
        }

        if let interfaceConfiguration = interfaceConfiguration {
            self.init(name: name, interface: interfaceConfiguration, peers: peerConfigurations)
        } else {
            throw ParseError.noInterface
        }
    }

    func asWgQuickConfig() -> String {
        var output = "[Interface]\n"
        output.append("PrivateKey = \(interface.privateKey.base64Key)\n")
        if let listenPort = interface.listenPort {
            output.append("ListenPort = \(listenPort)\n")
        }
        if !interface.addresses.isEmpty {
            let addressString = interface.addresses.map { $0.stringRepresentation }.joined(separator: ", ")
            output.append("Address = \(addressString)\n")
        }
        if !interface.dns.isEmpty || !interface.dnsSearch.isEmpty {
            var dnsLine = interface.dns.map { $0.stringRepresentation }
            dnsLine.append(contentsOf: interface.dnsSearch)
            let dnsString = dnsLine.joined(separator: ", ")
            output.append("DNS = \(dnsString)\n")
        }
        if let mtu = interface.mtu {
            output.append("MTU = \(mtu)\n")
        }

        for peer in peers {
            output.append("\n[Peer]\n")
            output.append("PublicKey = \(peer.publicKey.base64Key)\n")
            if let preSharedKey = peer.preSharedKey?.base64Key {
                output.append("PresharedKey = \(preSharedKey)\n")
            }
            if !peer.allowedIPs.isEmpty {
                let allowedIPsString = peer.allowedIPs.map { $0.stringRepresentation }.joined(separator: ", ")
                output.append("AllowedIPs = \(allowedIPsString)\n")
            }
            if let wsUrl = peer.wsUrl {
                output.append("Endpoint = \(wsUrl.urlString)\n")
            } else if let endpoint = peer.endpoint {
                output.append("Endpoint = \(endpoint.stringRepresentation)\n")
            }
            if let persistentKeepAlive = peer.persistentKeepAlive {
                output.append("PersistentKeepalive = \(persistentKeepAlive)\n")
            }
            if let wsMode = peer.wsMode {
                output.append("WSMode = \(wsMode.rawValue)\n")
            }
            if let wstunnelTarget = peer.wstunnelTarget {
                output.append("WSTunnelTarget = \(wstunnelTarget)\n")
            }
            if peer.wsMask {
                output.append("WSMask = true\n")
            }
            if let wsTlsCa = peer.wsTlsCa {
                output.append("WSTLSCA = \(wsTlsCa)\n")
            }
            if let wsTlsCert = peer.wsTlsCert {
                output.append("WSTLSCert = \(wsTlsCert)\n")
            }
            if let wsTlsKey = peer.wsTlsKey {
                output.append("WSTLSKey = \(wsTlsKey)\n")
            }
            if peer.wsTlsInsecure {
                output.append("WSTLSInsecure = true\n")
            }
            if let wsPingIntervalMs = peer.wsPingIntervalMs {
                output.append("WSPingInterval = \(wsPingIntervalMs)\n")
            }
            if let wsBackoffMinMs = peer.wsBackoffMinMs {
                output.append("WSBackoffMin = \(wsBackoffMinMs)\n")
            }
            if let wsBackoffMaxMs = peer.wsBackoffMaxMs {
                output.append("WSBackoffMax = \(wsBackoffMaxMs)\n")
            }
            if let wsBearer = peer.wsBearer {
                output.append("WSBearer = \(wsBearer)\n")
            }
        }

        return output
    }

    private static func collate(interfaceAttributes attributes: [String: String]) throws -> InterfaceConfiguration {
        guard let privateKeyString = attributes["privatekey"] else {
            throw ParseError.interfaceHasNoPrivateKey
        }
        guard let privateKey = PrivateKey(base64Key: privateKeyString) else {
            throw ParseError.interfaceHasInvalidPrivateKey(privateKeyString)
        }
        var interface = InterfaceConfiguration(privateKey: privateKey)
        if let listenPortString = attributes["listenport"] {
            guard let listenPort = UInt16(listenPortString) else {
                throw ParseError.interfaceHasInvalidListenPort(listenPortString)
            }
            interface.listenPort = listenPort
        }
        if let addressesString = attributes["address"] {
            var addresses = [IPAddressRange]()
            for addressString in addressesString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
                guard let address = IPAddressRange(from: addressString) else {
                    throw ParseError.interfaceHasInvalidAddress(addressString)
                }
                addresses.append(address)
            }
            interface.addresses = addresses
        }
        if let dnsString = attributes["dns"] {
            var dnsServers = [DNSServer]()
            var dnsSearch = [String]()
            for dnsServerString in dnsString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
                if let dnsServer = DNSServer(from: dnsServerString) {
                    dnsServers.append(dnsServer)
                } else {
                    dnsSearch.append(dnsServerString)
                }
            }
            interface.dns = dnsServers
            interface.dnsSearch = dnsSearch
        }
        if let mtuString = attributes["mtu"] {
            guard let mtu = UInt16(mtuString) else {
                throw ParseError.interfaceHasInvalidMTU(mtuString)
            }
            interface.mtu = mtu
        }
        return interface
    }

    private static func collate(peerAttributes attributes: [String: String]) throws -> PeerConfiguration {
        guard let publicKeyString = attributes["publickey"] else {
            throw ParseError.peerHasNoPublicKey
        }
        guard let publicKey = PublicKey(base64Key: publicKeyString) else {
            throw ParseError.peerHasInvalidPublicKey(publicKeyString)
        }
        var peer = PeerConfiguration(publicKey: publicKey)
        if let preSharedKeyString = attributes["presharedkey"] {
            guard let preSharedKey = PreSharedKey(base64Key: preSharedKeyString) else {
                throw ParseError.peerHasInvalidPreSharedKey(preSharedKeyString)
            }
            peer.preSharedKey = preSharedKey
        }
        if let allowedIPsString = attributes["allowedips"] {
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
            if WsUrl.isWsUrl(endpointString) {
                guard let wsUrl = WsUrl(from: endpointString), let endpoint = wsUrl.endpoint() else {
                    throw ParseError.peerHasInvalidEndpoint(endpointString)
                }
                peer.wsUrl = wsUrl
                peer.endpoint = endpoint
            } else {
                guard let endpoint = Endpoint(from: endpointString) else {
                    throw ParseError.peerHasInvalidEndpoint(endpointString)
                }
                peer.endpoint = endpoint
            }
        }
        if let persistentKeepAliveString = attributes["persistentkeepalive"] {
            guard let persistentKeepAlive = UInt16(persistentKeepAliveString) else {
                throw ParseError.peerHasInvalidPersistentKeepAlive(persistentKeepAliveString)
            }
            peer.persistentKeepAlive = persistentKeepAlive
        }
        if let wsModeString = attributes["wsmode"] {
            guard let wsMode = WsMode(fromWireFormat: wsModeString) else {
                throw ParseError.peerHasInvalidWsMode(wsModeString)
            }
            peer.wsMode = wsMode
        }
        if let wstunnelTargetString = attributes["wstunneltarget"] {
            // Validate the host:port shape; store the raw string. The inner target is resolved
            // by the wstunnel relay, never by this app.
            guard Endpoint(from: wstunnelTargetString) != nil else {
                throw ParseError.peerHasInvalidWsTunnelTarget(wstunnelTargetString)
            }
            peer.wstunnelTarget = wstunnelTargetString
        }
        if let wsBearerString = attributes["wsbearer"] {
            guard !wsBearerString.isEmpty else { throw ParseError.peerHasInvalidWsBearer }
            peer.wsBearer = wsBearerString
        }
        peer.wsMask = try parseWsBoolean(attributes, key: "wsmask")
        peer.wsTlsCa = try parseWsNonEmpty(attributes, key: "wstlsca", canonical: "WSTLSCA")
        peer.wsTlsCert = try parseWsNonEmpty(attributes, key: "wstlscert", canonical: "WSTLSCert")
        peer.wsTlsKey = try parseWsNonEmpty(attributes, key: "wstlskey", canonical: "WSTLSKey")
        peer.wsTlsInsecure = try parseWsBoolean(attributes, key: "wstlsinsecure")
        peer.wsPingIntervalMs = try parseWsMillis(attributes, key: "wspinginterval")
        peer.wsBackoffMinMs = try parseWsMillis(attributes, key: "wsbackoffmin")
        peer.wsBackoffMaxMs = try parseWsMillis(attributes, key: "wsbackoffmax")
        try validateWs(peer: peer, attributes: attributes)
        return peer
    }

    private static func parseWsBoolean(_ attributes: [String: String], key: String) throws -> Bool {
        guard let value = attributes[key] else { return false }
        switch value {
        case "true": return true
        case "false": return false
        default: throw ParseError.peerHasInvalidWsBoolean(value)
        }
    }

    private static func parseWsNonEmpty(_ attributes: [String: String], key: String, canonical: String) throws -> String? {
        guard let value = attributes[key] else { return nil }
        guard !value.isEmpty else { throw ParseError.peerHasEmptyWsValue(canonical) }
        return value
    }

    // A UAPI ws_* timing of 0 means "use the default", so it is not carried or emitted.
    private static func parseWsMillis(_ attributes: [String: String], key: String) throws -> UInt32? {
        guard let value = attributes[key] else { return nil }
        guard let millis = UInt32(value) else { throw ParseError.peerHasInvalidWsMillis(value) }
        return millis == 0 ? nil : millis
    }

    private static func validateWs(peer: PeerConfiguration, attributes: [String: String]) throws {
        let isWstunnel = peer.wsMode == .wstunnel
        if peer.wsUrl != nil && peer.wsMode == nil {
            throw ParseError.peerWsUrlRequiresWsMode
        }
        if peer.wsUrl == nil && peer.wsMode != nil && peer.endpoint != nil {
            throw ParseError.peerWsModeForbidsHostPortEndpoint
        }
        if isWstunnel && peer.wsUrl == nil {
            throw ParseError.peerInboundWstunnelForbidden
        }
        if isWstunnel && peer.wsUrl != nil && peer.wstunnelTarget == nil {
            throw ParseError.peerWstunnelRequiresTarget
        }
        if peer.wstunnelTarget != nil && !(isWstunnel && peer.wsUrl != nil) {
            throw ParseError.peerWsTunnelTargetForbidden
        }
        if peer.wsMode == nil {
            // Presence, not value, is the trigger (a `WSMask = false` on a UDP peer is an error).
            // `WSTunnelTarget` is absent here on purpose: the target-placement check above
            // already threw `.peerWsTunnelTargetForbidden` for it.
            let wsKeys: [(String, String)] = [
                ("wsbearer", "WSBearer"), ("wsmask", "WSMask"),
                ("wstlsca", "WSTLSCA"), ("wstlscert", "WSTLSCert"), ("wstlskey", "WSTLSKey"),
                ("wstlsinsecure", "WSTLSInsecure"), ("wspinginterval", "WSPingInterval"),
                ("wsbackoffmin", "WSBackoffMin"), ("wsbackoffmax", "WSBackoffMax")
            ]
            for (key, canonical) in wsKeys where attributes[key] != nil {
                throw ParseError.peerHasWsKeyWithoutWsMode(canonical)
            }
        }
    }

}
