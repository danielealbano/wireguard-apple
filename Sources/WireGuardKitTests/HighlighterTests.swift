// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import XCTest

class HighlighterTests: XCTestCase {

    private struct Span {
        let type: highlight_type
        let text: String
    }

    private func highlight(_ config: String) -> [Span] {
        var result = [Span]()
        let bytes = Array(config.utf8)
        config.withCString { cString in
            guard let spans = highlight_config(cString) else { return }
            defer { free(spans) }
            var index = 0
            while spans[index].type != HighlightEnd {
                let span = spans[index]
                let start = Int(span.start)
                let end = start + Int(span.len)
                result.append(Span(type: span.type, text: String(decoding: bytes[start..<end], as: UTF8.self)))
                index += 1
            }
        }
        return result
    }

    private func errorSpans(_ config: String) -> [String] {
        return highlight(config).filter { $0.type == HighlightError }.map { $0.text }
    }

    private let wsPeerConfig = """
    [Interface]
    PrivateKey = 6FyKD1LShTb9NUPZyDaR8ti3XG7GU8SSbLxpwgqywmA=
    [Peer]
    PublicKey = pIpo6/1D1kDvSAbTuVE26vqfARelseCPldOc0MZFHmA=
    Endpoint = wss://vpn.example.com:8443/tunnel
    WSMode = wstunnel
    WSTunnelTarget = 127.0.0.1:51820
    WSBearer = secret-token
    WSMask = true
    WSTLSCA = /tmp/ca.pem
    WSTLSCert = /tmp/cert.pem
    WSTLSKey = /tmp/key.pem
    WSTLSInsecure = false
    WSPingInterval = 25000
    WSBackoffMin = 500
    WSBackoffMax = 30000
    """

    func test_highlight_wsKeysValid() {
        XCTAssertEqual(errorSpans(wsPeerConfig), [])
    }

    func test_highlight_wsEndpointUrl() {
        let spans = highlight(wsPeerConfig)

        XCTAssertTrue(spans.contains { $0.type == HighlightHost && $0.text == "wss://vpn.example.com:8443/tunnel" })
    }

    func test_highlight_urlAcceptanceMatchesWsUrl() {
        let userinfoConfig = "[Peer]\nEndpoint = ws://user:pass@example.com:80/path\n"
        let queryConfig = "[Peer]\nEndpoint = ws://example.com:80?query=1\n"

        XCTAssertEqual(errorSpans(userinfoConfig), ["ws://user:pass@example.com:80/path"])
        XCTAssertEqual(errorSpans(queryConfig), ["ws://example.com:80?query=1"])
        XCTAssertNil(WsUrl(from: "ws://user:pass@example.com:80/path"))
        XCTAssertNil(WsUrl(from: "ws://example.com:80?query=1"))
    }

    func test_highlight_invalidModeBoolMillis() {
        XCTAssertEqual(errorSpans("[Peer]\nWSMode = tcp\n"), ["tcp"])
        XCTAssertEqual(errorSpans("[Peer]\nWSMask = yes\n"), ["yes"])
        XCTAssertEqual(errorSpans("[Peer]\nWSPingInterval = x\n"), ["x"])
    }

    func test_highlight_wsKeysStillInvalidInInterfaceSection() {
        XCTAssertEqual(errorSpans("[Interface]\nWSMode = websocket\n"), ["WSMode"])
    }

    func test_highlight_udpConfigUnaffected() {
        let udpConfig = """
        [Interface]
        PrivateKey = 6FyKD1LShTb9NUPZyDaR8ti3XG7GU8SSbLxpwgqywmA=
        Address = 10.0.0.2/32
        [Peer]
        PublicKey = pIpo6/1D1kDvSAbTuVE26vqfARelseCPldOc0MZFHmA=
        Endpoint = vpn.example.com:51820
        AllowedIPs = 0.0.0.0/0
        PersistentKeepalive = 25
        """

        XCTAssertEqual(errorSpans(udpConfig), [])
    }
}
