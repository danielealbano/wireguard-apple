// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import XCTest

class WsUrlTests: XCTestCase {

    func test_init_acceptsWssHostPortPath() {
        let url = WsUrl(from: "wss://vpn.example.com:8443/tunnel")

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.urlString, "wss://vpn.example.com:8443/tunnel")
        XCTAssertEqual(url?.host, "vpn.example.com")
        XCTAssertEqual(url?.port, 8443)
    }

    func test_init_acceptsNoPathAndQueryAfterPath() {
        XCTAssertNotNil(WsUrl(from: "ws://example.com:80"))
        XCTAssertNotNil(WsUrl(from: "wss://example.com:443/path?query=1"))
    }

    func test_init_rejectsMissingPortSchemeHost() {
        XCTAssertNil(WsUrl(from: "ws://example.com/path"))
        XCTAssertNil(WsUrl(from: "http://example.com:80/path"))
        XCTAssertNil(WsUrl(from: "example.com:80"))
        XCTAssertNil(WsUrl(from: "ws://:80"))
    }

    func test_init_rejectsUserinfo() {
        XCTAssertNil(WsUrl(from: "ws://user:pass@example.com:80/path"))
    }

    func test_init_rejectsQueryWithoutPath() {
        XCTAssertNil(WsUrl(from: "ws://example.com:80?query=1"))
        XCTAssertNil(WsUrl(from: "ws://example.com:80#fragment"))
    }

    func test_init_ipv6BracketHost() {
        let url = WsUrl(from: "ws://[::1]:8080")

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "::1")
        XCTAssertEqual(url?.port, 8080)
        XCTAssertEqual(url?.endpoint(), Endpoint(from: "[::1]:8080"))
    }

    func test_endpoint_matchesUdpEndpointParsing() {
        let url = WsUrl(from: "wss://vpn.example.com:8443/tunnel")

        XCTAssertEqual(url?.endpoint(), Endpoint(from: "vpn.example.com:8443"))
    }

    func test_isWsUrl_caseInsensitivePrefix() {
        XCTAssertTrue(WsUrl.isWsUrl("WS://example.com:80"))
        XCTAssertTrue(WsUrl.isWsUrl("wss://example.com:443"))
        XCTAssertFalse(WsUrl.isWsUrl("example.com:80"))
    }
}
