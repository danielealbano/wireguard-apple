// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import XCTest

class TunnelViewModelWsTests: XCTestCase {

    private let peerPublicKey = PrivateKey().publicKey

    private func makeWstunnelPeer() -> PeerConfiguration {
        var peer = PeerConfiguration(publicKey: peerPublicKey)
        peer.wsMode = .wstunnel
        peer.wsUrl = WsUrl(from: "wss://vpn.example.com:8443/tunnel")
        peer.endpoint = peer.wsUrl?.endpoint()
        peer.wstunnelTarget = "127.0.0.1:51820"
        peer.wsBearer = "secret-token"
        peer.wsMask = true
        peer.wsTlsCa = "/tmp/ca.pem"
        peer.wsTlsInsecure = true
        peer.wsPingIntervalMs = 25000
        return peer
    }

    private func makePeerData(config: PeerConfiguration) -> TunnelViewModel.PeerData {
        let peerData = TunnelViewModel.PeerData(index: 0)
        peerData.validatedConfiguration = config
        return peerData
    }

    private func makePeerData(fields: [TunnelViewModel.PeerField: String]) -> TunnelViewModel.PeerData {
        let peerData = TunnelViewModel.PeerData(index: 0)
        peerData[.publicKey] = peerPublicKey.base64Key
        for (field, value) in fields {
            peerData[field] = value
        }
        return peerData
    }

    private func assertSaveFails(_ peerData: TunnelViewModel.PeerData, markingField field: TunnelViewModel.PeerField, file: StaticString = #filePath, line: UInt = #line) {
        guard case .error = peerData.save() else {
            XCTFail("Expected save() to fail", file: file, line: line)
            return
        }
        XCTAssertTrue(peerData.fieldsWithError.contains(field), "Expected \(field) to be marked", file: file, line: line)
    }

    func test_save_wsPeerRoundTrip() {
        let config = makeWstunnelPeer()
        let peerData = makePeerData(config: config)
        peerData.populateScratchpad()
        peerData.validatedConfiguration = nil

        guard case .saved(let saved) = peerData.save() else {
            XCTFail("Expected save() to succeed")
            return
        }
        XCTAssertEqual(saved, config)
    }

    func test_save_wsUrlEndpointParsesToWsUrl() {
        let peerData = makePeerData(fields: [.endpoint: "wss://vpn.example.com:8443/tunnel", .wsMode: "websocket"])

        guard case .saved(let saved) = peerData.save() else {
            XCTFail("Expected save() to succeed")
            return
        }
        XCTAssertEqual(saved.wsUrl?.urlString, "wss://vpn.example.com:8443/tunnel")
        XCTAssertEqual(saved.endpoint, Endpoint(from: "vpn.example.com:8443"))
    }

    func test_save_wsUrlWithoutMode_marksWsModeError() {
        let peerData = makePeerData(fields: [.endpoint: "wss://vpn.example.com:8443"])

        assertSaveFails(peerData, markingField: .wsMode)
    }

    func test_save_hostPortWithMode_marksEndpointError() {
        let peerData = makePeerData(fields: [.endpoint: "192.0.2.1:51820", .wsMode: "websocket"])

        assertSaveFails(peerData, markingField: .endpoint)
    }

    func test_save_wstunnelWithoutTarget_marksTargetError() {
        let peerData = makePeerData(fields: [.endpoint: "wss://vpn.example.com:8443", .wsMode: "wstunnel"])

        assertSaveFails(peerData, markingField: .wstunnelTarget)
    }

    func test_save_targetWithoutDialingWstunnel_marksTargetError() {
        let peerData = makePeerData(fields: [.endpoint: "wss://vpn.example.com:8443", .wsMode: "websocket", .wstunnelTarget: "127.0.0.1:51820"])

        assertSaveFails(peerData, markingField: .wstunnelTarget)
    }

    func test_save_wsFieldWithoutMode_marksFieldError() {
        let peerData = makePeerData(fields: [.wsBearer: "secret-token"])

        assertSaveFails(peerData, markingField: .wsBearer)
    }

    func test_save_invalidMillis_marksFieldError() {
        let peerData = makePeerData(fields: [.endpoint: "wss://vpn.example.com:8443", .wsMode: "websocket", .wsPingInterval: "abc"])

        assertSaveFails(peerData, markingField: .wsPingInterval)
    }

    func test_save_zeroMillisNormalizedToNil() {
        let peerData = makePeerData(fields: [.endpoint: "wss://vpn.example.com:8443", .wsMode: "websocket", .wsPingInterval: "0"])

        guard case .saved(let saved) = peerData.save() else {
            XCTFail("Expected save() to succeed")
            return
        }
        XCTAssertNil(saved.wsPingIntervalMs)
    }

    func test_scratchpad_booleansStoredAsTrueMarker() {
        var config = PeerConfiguration(publicKey: peerPublicKey)
        config.wsMode = .websocket
        config.wsMask = true
        config.wsTlsInsecure = false
        let peerData = makePeerData(config: config)
        peerData.populateScratchpad()

        XCTAssertEqual(peerData[.wsMask], "true")
        XCTAssertEqual(peerData[.wsTlsInsecure], "")
    }

    func test_clearWsParameterFields_makesUdpPeerSaveable() {
        let peerData = makePeerData(fields: [.wsMode: "websocket", .wsBearer: "secret-token", .wsMask: "true", .wsPingInterval: "25000"])

        peerData[.wsMode] = ""
        peerData.clearWsParameterFields()

        guard case .saved(let saved) = peerData.save() else {
            XCTFail("Expected save() to succeed after clearing WS fields")
            return
        }
        XCTAssertNil(saved.wsMode)
        XCTAssertNil(saved.wsBearer)
        XCTAssertFalse(saved.wsMask)
    }
}
