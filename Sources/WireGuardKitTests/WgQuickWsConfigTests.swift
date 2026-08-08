// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import XCTest

class WgQuickWsConfigTests: XCTestCase {

    private let interfacePrivateKey = PrivateKey()
    private let peerPublicKey = PrivateKey().publicKey

    private func makeConfigText(peerLines: [String]) -> String {
        var lines = ["[Interface]", "PrivateKey = \(interfacePrivateKey.base64Key)", "[Peer]", "PublicKey = \(peerPublicKey.base64Key)"]
        lines.append(contentsOf: peerLines)
        return lines.joined(separator: "\n")
    }

    private func parse(peerLines: [String]) throws -> TunnelConfiguration {
        return try TunnelConfiguration(fromWgQuickConfig: makeConfigText(peerLines: peerLines), called: "test")
    }

    private func assertParseThrows(peerLines: [String], _ verifyError: (TunnelConfiguration.ParseError) -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(peerLines: peerLines), file: file, line: line) { error in
            guard let parseError = error as? TunnelConfiguration.ParseError, verifyError(parseError) else {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
                return
            }
        }
    }

    func test_parse_wsEndpointWithMode_dialingWebsocket() throws {
        let config = try parse(peerLines: ["Endpoint = wss://vpn.example.com:8443/tunnel", "WSMode = websocket"])

        let peer = config.peers[0]
        XCTAssertEqual(peer.wsMode, .websocket)
        XCTAssertEqual(peer.wsUrl?.urlString, "wss://vpn.example.com:8443/tunnel")
        XCTAssertEqual(peer.endpoint, Endpoint(from: "vpn.example.com:8443"))
    }

    func test_parse_wstunnelRequiresTarget() {
        assertParseThrows(peerLines: ["Endpoint = wss://vpn.example.com:8443", "WSMode = wstunnel"]) {
            if case .peerWstunnelRequiresTarget = $0 { return true } else { return false }
        }
    }

    func test_parse_websocketRejectsTarget() {
        assertParseThrows(peerLines: ["Endpoint = wss://vpn.example.com:8443", "WSMode = websocket", "WSTunnelTarget = 127.0.0.1:51820"]) {
            if case .peerWsTunnelTargetForbidden = $0 { return true } else { return false }
        }
    }

    func test_parse_wsModeWithoutEndpoint_inbound() throws {
        let config = try parse(peerLines: ["WSMode = websocket"])

        let peer = config.peers[0]
        XCTAssertEqual(peer.wsMode, .websocket)
        XCTAssertNil(peer.wsUrl)
        XCTAssertNil(peer.endpoint)
    }

    func test_parse_inboundWstunnel_rejected() {
        assertParseThrows(peerLines: ["WSMode = wstunnel"]) {
            if case .peerInboundWstunnelForbidden = $0 { return true } else { return false }
        }
    }

    func test_parse_wsUrlWithoutMode_rejected() {
        assertParseThrows(peerLines: ["Endpoint = wss://vpn.example.com:8443"]) {
            if case .peerWsUrlRequiresWsMode = $0 { return true } else { return false }
        }
    }

    func test_parse_hostPortEndpointWithMode_rejected() {
        assertParseThrows(peerLines: ["Endpoint = 192.0.2.1:51820", "WSMode = websocket"]) {
            if case .peerWsModeForbidsHostPortEndpoint = $0 { return true } else { return false }
        }
    }

    func test_parse_wsKeysOnUdpPeer_rejected() {
        let offendingLines = [
            "WSBearer = secret-token",
            "WSMask = false",
            "WSTLSCA = /tmp/ca.pem",
            "WSTLSCert = /tmp/cert.pem",
            "WSTLSKey = /tmp/key.pem",
            "WSTLSInsecure = false",
            "WSPingInterval = 0",
            "WSBackoffMin = 500",
            "WSBackoffMax = 30000"
        ]
        for offendingLine in offendingLines {
            assertParseThrows(peerLines: [offendingLine]) {
                if case .peerHasWsKeyWithoutWsMode = $0 { return true } else { return false }
            }
        }
    }

    func test_parse_wstunnelTargetOnUdpPeer_rejected() {
        assertParseThrows(peerLines: ["WSTunnelTarget = 127.0.0.1:51820"]) {
            if case .peerWsTunnelTargetForbidden = $0 { return true } else { return false }
        }
    }

    func test_parse_badBoolAndMillis_rejected() {
        assertParseThrows(peerLines: ["Endpoint = wss://h.example.com:443", "WSMode = websocket", "WSMask = yes"]) {
            if case .peerHasInvalidWsBoolean("yes") = $0 { return true } else { return false }
        }
        assertParseThrows(peerLines: ["Endpoint = wss://h.example.com:443", "WSMode = websocket", "WSPingInterval = abc"]) {
            if case .peerHasInvalidWsMillis("abc") = $0 { return true } else { return false }
        }
        assertParseThrows(peerLines: ["Endpoint = wss://h.example.com:443", "WSMode = websocket", "WSPingInterval = -1"]) {
            if case .peerHasInvalidWsMillis("-1") = $0 { return true } else { return false }
        }
    }

    func test_parse_invalidWsMode_rejected() {
        assertParseThrows(peerLines: ["Endpoint = wss://h.example.com:443", "WSMode = tcp"]) {
            if case .peerHasInvalidWsMode("tcp") = $0 { return true } else { return false }
        }
    }

    func test_parse_malformedWstunnelTarget_rejected() {
        assertParseThrows(peerLines: ["Endpoint = wss://h.example.com:443", "WSMode = wstunnel", "WSTunnelTarget = nocolon"]) {
            if case .peerHasInvalidWsTunnelTarget("nocolon") = $0 { return true } else { return false }
        }
    }

    func test_parse_emptyBearer_rejected() {
        assertParseThrows(peerLines: ["Endpoint = wss://h.example.com:443", "WSMode = websocket", "WSBearer ="]) { error in
            if case .peerHasInvalidWsBearer = error {
                XCTAssertFalse("\(error)".contains("secret"))
                return true
            }
            return false
        }
    }

    func test_parse_zeroMillis_absentAfterRoundTrip() throws {
        let config = try parse(peerLines: ["Endpoint = wss://h.example.com:443", "WSMode = websocket", "WSPingInterval = 0"])

        XCTAssertNil(config.peers[0].wsPingIntervalMs)
        XCTAssertFalse(config.asWgQuickConfig().contains("WSPingInterval"))
    }

    func test_asWgQuickConfig_roundTrip_wsPeer() throws {
        let peerLines = [
            "Endpoint = wss://vpn.example.com:8443/tunnel",
            "WSMode = wstunnel",
            "WSTunnelTarget = 127.0.0.1:51820",
            "WSBearer = secret-token",
            "WSMask = true",
            "WSTLSCA = /tmp/ca.pem",
            "WSTLSInsecure = true",
            "WSPingInterval = 25000",
            "WSBackoffMin = 500",
            "WSBackoffMax = 30000"
        ]
        let config = try parse(peerLines: peerLines)

        let emitted = config.asWgQuickConfig()
        let reparsed = try TunnelConfiguration(fromWgQuickConfig: emitted, called: "test")

        XCTAssertTrue(emitted.contains("Endpoint = wss://vpn.example.com:8443/tunnel\n"))
        XCTAssertEqual(reparsed.peers, config.peers)
    }

    func test_asWgQuickConfig_udpPeerUnchanged() throws {
        let config = try parse(peerLines: ["Endpoint = 192.0.2.1:51820", "AllowedIPs = 0.0.0.0/0"])

        XCTAssertFalse(config.asWgQuickConfig().contains("WS"))
    }

    func test_parse_caseInsensitiveKeysAndValues() throws {
        let config = try parse(peerLines: ["Endpoint = wss://vpn.example.com:8443", "wsmode = WEBSOCKET"])

        XCTAssertEqual(config.peers[0].wsMode, .websocket)
    }
}
