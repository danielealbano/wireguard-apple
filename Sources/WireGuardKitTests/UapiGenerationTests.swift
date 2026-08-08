// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import XCTest

class UapiGenerationTests: XCTestCase {

    private let interfacePrivateKey = PrivateKey()
    private let peerPublicKey = PrivateKey().publicKey

    private func makeTunnelConfiguration(peer: PeerConfiguration) -> TunnelConfiguration {
        let interface = InterfaceConfiguration(privateKey: interfacePrivateKey)
        return TunnelConfiguration(name: "test", interface: interface, peers: [peer])
    }

    private func makeWstunnelPeer() -> PeerConfiguration {
        var peer = PeerConfiguration(publicKey: peerPublicKey)
        peer.wsMode = .wstunnel
        peer.wsUrl = WsUrl(from: "wss://vpn.example.com:8443/tunnel")
        peer.endpoint = Endpoint(from: "192.0.2.1:8443")
        peer.wstunnelTarget = "127.0.0.1:51820"
        peer.wsBearer = "secret-token"
        peer.wsMask = true
        peer.wsTlsCa = "/tmp/ca.pem"
        peer.wsPingIntervalMs = 25000
        return peer
    }

    func test_uapiConfiguration_udpPeer() {
        var peer = PeerConfiguration(publicKey: peerPublicKey)
        peer.endpoint = Endpoint(from: "192.0.2.1:51820")
        let generator = PacketTunnelSettingsGenerator(tunnelConfiguration: makeTunnelConfiguration(peer: peer), resolvedEndpoints: [peer.endpoint])

        let (wgSettings, _) = generator.uapiConfiguration()

        XCTAssertTrue(wgSettings.contains("transport=udp\n"))
        XCTAssertTrue(wgSettings.contains("endpoint=192.0.2.1:51820\n"))
        XCTAssertFalse(wgSettings.contains("ws_"))
    }

    func test_uapiConfiguration_wstunnelPeer() {
        let peer = makeWstunnelPeer()
        let generator = PacketTunnelSettingsGenerator(tunnelConfiguration: makeTunnelConfiguration(peer: peer), resolvedEndpoints: [peer.endpoint])

        let (wgSettings, _) = generator.uapiConfiguration()

        XCTAssertTrue(wgSettings.contains("transport=wstunnel\n"))
        XCTAssertTrue(wgSettings.contains("endpoint=192.0.2.1:8443\n"))
        XCTAssertTrue(wgSettings.contains("ws_url=wss://vpn.example.com:8443/tunnel\n"))
        XCTAssertTrue(wgSettings.contains("wstunnel_target=127.0.0.1:51820\n"))
        XCTAssertTrue(wgSettings.contains("ws_bearer=secret-token\n"))
        XCTAssertTrue(wgSettings.contains("ws_mask=true\n"))
        XCTAssertTrue(wgSettings.contains("ws_tls_ca=/tmp/ca.pem\n"))
        XCTAssertTrue(wgSettings.contains("ws_ping_interval=25000\n"))
        XCTAssertFalse(wgSettings.contains("ws_tls_insecure"))
        XCTAssertFalse(wgSettings.contains("ws_backoff_min"))
        XCTAssertFalse(wgSettings.contains("ws_backoff_max"))
    }

    func test_uapiConfiguration_inboundWebsocketPeer() {
        var peer = PeerConfiguration(publicKey: peerPublicKey)
        peer.wsMode = .websocket
        peer.wsBearer = "secret-token"
        let generator = PacketTunnelSettingsGenerator(tunnelConfiguration: makeTunnelConfiguration(peer: peer), resolvedEndpoints: [nil])

        let (wgSettings, _) = generator.uapiConfiguration()

        XCTAssertTrue(wgSettings.contains("transport=websocket\n"))
        XCTAssertFalse(wgSettings.contains("endpoint="))
        XCTAssertFalse(wgSettings.contains("ws_url="))
        XCTAssertTrue(wgSettings.contains("ws_bearer=secret-token\n"))
    }

    func test_endpointUapiConfiguration_wsPeerCarriesWsBlock() {
        let peer = makeWstunnelPeer()
        let generator = PacketTunnelSettingsGenerator(tunnelConfiguration: makeTunnelConfiguration(peer: peer), resolvedEndpoints: [peer.endpoint])

        let (wgSettings, _) = generator.endpointUapiConfiguration()

        XCTAssertTrue(wgSettings.contains("public_key=\(peer.publicKey.hexKey)\n"))
        XCTAssertTrue(wgSettings.contains("endpoint=192.0.2.1:8443\n"))
        XCTAssertTrue(wgSettings.contains("ws_url=wss://vpn.example.com:8443/tunnel\n"))
        XCTAssertTrue(wgSettings.contains("wstunnel_target=127.0.0.1:51820\n"))
    }

    func test_endpointUapiConfiguration_udpPeerUnchanged() {
        var peer = PeerConfiguration(publicKey: peerPublicKey)
        peer.endpoint = Endpoint(from: "192.0.2.1:51820")
        let generator = PacketTunnelSettingsGenerator(tunnelConfiguration: makeTunnelConfiguration(peer: peer), resolvedEndpoints: [peer.endpoint])

        let (wgSettings, _) = generator.endpointUapiConfiguration()

        XCTAssertEqual(wgSettings, "public_key=\(peer.publicKey.hexKey)\nendpoint=192.0.2.1:51820\n")
    }

    func test_uapiConfiguration_neverEmitsBearerForUdp() {
        var peer = PeerConfiguration(publicKey: peerPublicKey)
        peer.endpoint = Endpoint(from: "192.0.2.1:51820")
        let generator = PacketTunnelSettingsGenerator(tunnelConfiguration: makeTunnelConfiguration(peer: peer), resolvedEndpoints: [peer.endpoint])

        let (wgSettings, _) = generator.uapiConfiguration()

        XCTAssertFalse(wgSettings.contains("ws_bearer"))
    }
}
