// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

/// The WebSocket carrier mode of a peer: standard WebSocket or a wstunnel relay.
public enum WsMode: String, CaseIterable {
    case websocket
    case wstunnel

    public init?(fromWireFormat string: String) {
        self.init(rawValue: string.lowercased())
    }
}
