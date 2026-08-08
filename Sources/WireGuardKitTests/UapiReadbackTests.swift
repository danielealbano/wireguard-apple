// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import XCTest

class UapiReadbackTests: XCTestCase {

    private let interfacePrivateKey = PrivateKey()
    private let peerPublicKey = PrivateKey().publicKey

    private func makeUapiText(peerLines: [String]) -> String {
        var lines = ["private_key=\(interfacePrivateKey.hexKey)", "listen_port=0", "public_key=\(peerPublicKey.hexKey)"]
        lines.append(contentsOf: peerLines)
        return lines.joined(separator: "\n") + "\n"
    }

    func test_fromUapiConfig_udpPeerWithTransportLine() throws {
        let uapiText = makeUapiText(peerLines: [
            "protocol_version=1",
            "transport=udp",
            "endpoint=192.0.2.1:51820",
            "last_handshake_time_sec=0",
            "last_handshake_time_nsec=0",
            "tx_bytes=128",
            "rx_bytes=256",
            "persistent_keepalive_interval=0",
            "allowed_ip=0.0.0.0/0"
        ])

        let config = try TunnelConfiguration(fromUapiConfig: uapiText)

        let peer = config.peers[0]
        XCTAssertNil(peer.wsMode)
        XCTAssertEqual(peer.endpoint, Endpoint(from: "192.0.2.1:51820"))
        XCTAssertEqual(peer.txBytes, 128)
        XCTAssertEqual(peer.rxBytes, 256)
    }

    func test_fromUapiConfig_wstunnelPeerFullBlock() throws {
        let uapiText = makeUapiText(peerLines: [
            "protocol_version=1",
            "transport=wstunnel",
            "endpoint=192.0.2.1:8443",
            "ws_url=wss://vpn.example.com:8443/tunnel",
            "wstunnel_target=127.0.0.1:51820",
            "ws_bearer=secret-token",
            "ws_mask=true",
            "ws_tls_ca=/tmp/ca.pem",
            "ws_tls_insecure=true",
            "ws_ping_interval=25000",
            "last_handshake_time_sec=1",
            "last_handshake_time_nsec=0",
            "tx_bytes=128",
            "rx_bytes=256",
            "persistent_keepalive_interval=25",
            "allowed_ip=0.0.0.0/0"
        ])

        let config = try TunnelConfiguration(fromUapiConfig: uapiText)

        let peer = config.peers[0]
        XCTAssertEqual(peer.wsMode, .wstunnel)
        XCTAssertEqual(peer.wsUrl?.urlString, "wss://vpn.example.com:8443/tunnel")
        XCTAssertEqual(peer.wstunnelTarget, "127.0.0.1:51820")
        XCTAssertEqual(peer.wsBearer, "secret-token")
        XCTAssertTrue(peer.wsMask)
        XCTAssertEqual(peer.wsTlsCa, "/tmp/ca.pem")
        XCTAssertTrue(peer.wsTlsInsecure)
        XCTAssertEqual(peer.wsPingIntervalMs, 25000)
        XCTAssertEqual(peer.endpoint, Endpoint(from: "192.0.2.1:8443"))
        XCTAssertNotNil(peer.lastHandshakeTime)
    }

    func test_fromUapiConfig_invalidTransport_rejected() {
        let uapiText = makeUapiText(peerLines: ["transport=tcp"])

        XCTAssertThrowsError(try TunnelConfiguration(fromUapiConfig: uapiText)) { error in
            guard let parseError = error as? TunnelConfiguration.ParseError,
                  case .peerHasInvalidTransport("tcp") = parseError else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func test_fromUapiConfig_zeroTimingNormalizedToNil() throws {
        let uapiText = makeUapiText(peerLines: [
            "transport=websocket",
            "endpoint=192.0.2.1:8443",
            "ws_url=wss://vpn.example.com:8443",
            "ws_ping_interval=0"
        ])

        let config = try TunnelConfiguration(fromUapiConfig: uapiText)

        XCTAssertNil(config.peers[0].wsPingIntervalMs)
    }
}
