# wireguard-apple — Architecture

Companion to `PROJECT.md` (what things are); this document describes how the pieces fit and flow.

## 1. Processes, targets & dependencies

Two processes per platform: the **GUI app** and the **packet-tunnel Network Extension** (a separate
sandboxed process managed by the OS). They never call each other directly — they communicate through
the system VPN preferences, the Keychain, app-group container files, and provider messages.

```mermaid
flowchart TD
    subgraph AppProc["GUI app process (WireGuardiOS / WireGuardmacOS)"]
        UI["Platform UI<br/>UIKit (iOS) / AppKit (macOS)"]
        TVM[TunnelViewModel]
        TM["TunnelsManager<br/>TunnelContainer"]
        UI --> TVM --> TM
    end

    subgraph SysChannels["System channels"]
        PREFS["VPN preferences<br/>(NETunnelProviderManager)"]
        KC["Keychain<br/>(wg-quick text, passwordReference)"]
        AG["App group container<br/>tunnel-log.bin / last-error.txt"]
    end

    subgraph NEProc["NE process (WireGuardNetworkExtension iOS/macOS)"]
        PTP[PacketTunnelProvider]
        WGA["WireGuardAdapter<br/>(WireGuardKit)"]
        BRIDGE["libwg-go.a<br/>api-apple.go via wireguard.h"]
        CORE["wireguard-go core<br/>golang.zx2c4.com/wireguard"]
        UTUN["utun device"]
        PTP --> WGA --> BRIDGE --> CORE --> UTUN
    end

    TM -- "save / load / start / stop" --> PREFS
    TM -- "config text" --> KC
    PREFS -- "startTunnel via OS" --> PTP
    KC -- "config text" --> PTP
    PTP -- "last-error.txt" --> AG
    TM -- "read errors / logs" --> AG
    TM -- "sendProviderMessage (runtime config)" --> PTP

    KIT["Shared sources compiled into BOTH processes:<br/>WireGuardKit + WireGuardKitC + Sources/Shared"]
    AppProc -.-> KIT
    NEProc -.-> KIT
```

Key structural facts:

- `WireGuardKit`, `WireGuardKitC`, and `Sources/Shared` are compiled **directly into** the app and
  NE targets (no framework product inside this project). `Package.swift` additionally exposes
  `WireGuardKit` as a Swift Package for external consumers.
- The NE targets depend on a **GoBridge legacy target** (`make` in `Sources/WireGuardKitGo`) and
  link the resulting universal `libwg-go.a`.
- The macOS app is a menu-bar app (`LSUIElement`) with a `LoginItemHelper` bundled for
  launch-at-login.

## 2. Tunnel activation flow

```mermaid
sequenceDiagram
    participant User
    participant App as GUI app (TunnelsManager)
    participant OS as OS (NetworkExtension)
    participant PTP as PacketTunnelProvider (NE process)
    participant WGA as WireGuardAdapter
    participant Go as libwg-go (wireguard-go)

    User->>App: toggle tunnel on
    App->>App: TunnelContainer.startActivation<br/>(re-enable + retry up to 8x on stale config)
    App->>OS: NETunnelProviderSession.startTunnel(activationAttemptId)
    OS->>PTP: launch NE process, startTunnel(options)
    PTP->>PTP: read NETunnelProviderProtocol.passwordReference<br/>Keychain.openReference to wg-quick text
    PTP->>WGA: start(tunnelConfiguration)
    WGA->>WGA: DNSResolver.resolveSync (DNS64-aware)
    WGA->>OS: setTunnelNetworkSettings<br/>(addresses, routes, DNS, MTU - 5s timeout guard)
    WGA->>WGA: locate utun fd (getpeername scan)
    WGA->>Go: wgTurnOn(uapiConfig, tunFd)
    Go->>Go: CreateTUNFromFile + NewMultiplexBind<br/>IpcSet + device.Up
    Go-->>WGA: non-negative handle
    WGA-->>PTP: success
    PTP-->>OS: completionHandler(nil)
    OS-->>App: NEVPNStatusDidChange to connected
    App->>App: TunnelContainer.status = active

    Note over PTP,Go: on failure ErrorNotifier writes<br/>activationAttemptId + error to last-error.txt<br/>and the app reads it after the failed activation
```

Deactivation: the app calls `stopTunnel()` on the session → `PacketTunnelProvider.stopTunnel` →
`adapter.stop()` → `wgTurnOff(handle)`; on macOS the NE process then calls `exit(0)` (documented
workaround for an Apple NE bug).

## 3. WireGuardAdapter state machine & network-path handling

All adapter work runs on a private serial `DispatchQueue`; an `NWPathMonitor` feeds path updates
into the same queue.

```mermaid
stateDiagram-v2
    [*] --> stopped
    stopped --> started: start() to wgTurnOn
    started --> stopped: stop() to wgTurnOff
    started --> started: update(config) to wgSetConfig<br/>path change (macOS) to wgBumpSockets<br/>path change (iOS, online) to re-resolve + wgSetConfig + wgBumpSockets
    started --> temporaryShutdown: path unsatisfied (iOS) to wgTurnOff
    temporaryShutdown --> started: path satisfiable (iOS) to setNetworkSettings + wgTurnOn
    temporaryShutdown --> stopped: stop()
```

Platform divergences (deliberate, MUST be preserved):

| Concern | iOS | macOS |
|---|---|---|
| Path change while up | re-resolve endpoints, `wgSetConfig`, `wgBumpSockets`, `wgDisableSomeRoamingForBrokenMobileSemantics` | `wgBumpSockets` only |
| Offline | tear down to `temporaryShutdown`, restart when satisfiable | keep running |
| DNS re-resolution | `withReresolvedIP()` (DNS64 via `getaddrinfo`) | no-op |
| Default MTU | 1280 (`networkSettings.mtu`) | `tunnelOverheadBytes = 80` |

Not platform-divergent (applies on BOTH platforms, unconditionally): interface-address IPv6 network
prefixes are clamped to /120 in `PacketTunnelSettingsGenerator.addresses()` (the code comment
attributes the motivation to the iOS networking stack); allowed-IPs routes use the configured
prefix as-is.

WebSocket/wstunnel peers ride the SAME per-platform path-change semantics: `wgBumpSockets` →
`device.BindUpdate()` closes and reopens the multiplex bind (UDP rebind + WS re-dial), and the
iOS endpoint re-resolution path re-sends each dialing WS peer's full `ws_*` block together with
the re-resolved `endpoint=` (the fork ignores a WS endpoint update that arrives without
`ws_url`; on resolution failure nothing is sent for that peer, matching UDP behavior).

## 4. Config data model & serialization surfaces

```mermaid
classDiagram
    class TunnelConfiguration {
        +String? name
        +InterfaceConfiguration interface
        +PeerConfiguration[] peers
        +init(fromWgQuickConfig)
        +asWgQuickConfig() String
        +init(fromUapiConfig, basedOn)
    }
    class InterfaceConfiguration {
        +PrivateKey privateKey
        +IPAddressRange[] addresses
        +UInt16? listenPort
        +UInt16? mtu
        +DNSServer[] dns
        +String[] dnsSearch
    }
    class PeerConfiguration {
        +PublicKey publicKey
        +PreSharedKey? preSharedKey
        +IPAddressRange[] allowedIPs
        +Endpoint? endpoint
        +UInt16? persistentKeepAlive
        +UInt64? rxBytes
        +UInt64? txBytes
        +Date? lastHandshakeTime
    }
    class Endpoint {
        +NWEndpoint.Host host
        +NWEndpoint.Port port
        +stringRepresentation String
        +withReresolvedIP() Endpoint
    }
    class BaseKey {
        <<abstract>>
        +Data rawValue (32 bytes)
        +hexKey String
        +base64Key String
    }
    TunnelConfiguration "1" --> "1" InterfaceConfiguration
    TunnelConfiguration "1" --> "*" PeerConfiguration
    PeerConfiguration --> Endpoint
    InterfaceConfiguration --> BaseKey : PrivateKey
    PeerConfiguration --> BaseKey : PublicKey / PreSharedKey
```

The model additionally carries the per-peer WebSocket surface (`WsMode`, `WsUrl`,
`wstunnelTarget`, `wsBearer`, `wsMask`, `wsTlsCa`/`wsTlsCert`/`wsTlsKey`, `wsTlsInsecure`,
`wsPingIntervalMs`/`wsBackoffMinMs`/`wsBackoffMaxMs`); a dialing WS peer's routable `endpoint` is
derived from the URL's host:port.

Three serialization surfaces, all of which MUST stay interoperable with standard WireGuard (and,
for the WS keys, byte-compatible with the sibling `wireguard-tools` fork):

1. **wg-quick text** (`TunnelConfiguration+WgQuickConfig`, in `Sources/Shared`) — user-facing
   import/export and the Keychain-stored form. Interface keys: `PrivateKey`, `ListenPort`,
   `Address`, `DNS`, `MTU`; peer keys: `PublicKey`, `PresharedKey`, `AllowedIPs`, `Endpoint`
   (`host:port` or `ws(s)://host:port[/path]`), `PersistentKeepalive`, and the eleven `WS*` keys
   (`WSMode`, `WSTunnelTarget`, `WSBearer`, `WSMask`, `WSTLSCA`, `WSTLSCert`, `WSTLSKey`,
   `WSTLSInsecure`, `WSPingInterval`, `WSBackoffMin`, `WSBackoffMax`). Unknown keys are parse
   errors (the macOS raw-text editor's `highlighter.c` enforces the same key set — and the same
   `ws(s)://` URL acceptance set — for syntax highlighting; an error span blocks saving).
2. **UAPI generation** (`PacketTunnelSettingsGenerator`) — the `key=value` form passed to
   `wgTurnOn`/`wgSetConfig` (hex keys, resolved endpoints, `replace_peers`/`replace_allowed_ips`;
   `transport=` on every peer, `ws_url`/`wstunnel_target`/`ws_bearer`/`ws_mask`/`ws_tls_*`/
   `ws_ping_interval`/`ws_backoff_*` for WS peers).
3. **UAPI readback** (`TunnelConfiguration+UapiConfig`) — parses `wgGetConfig` output (adds
   `rx_bytes`, `tx_bytes`, `last_handshake_time_*`, `protocol_version`, and round-trips
   `transport=` — emitted for EVERY peer, also plain UDP — plus the `ws_*` keys) to show runtime
   stats.

Storage: the `NETunnelProviderManager` entry holds `providerBundleIdentifier`
(`<appId>.network-extension`), `passwordReference` (Keychain persistent ref to the wg-quick text),
on macOS the owning `UID`, and a display `serverAddress`. `TunnelsManager.create()` garbage-collects
keychain items not referenced by any manager and removes managers whose keychain reference no
longer verifies.

## 5. Go bridge build pipeline

```mermaid
flowchart LR
    XC["Xcode build of an NE target"] --> DEP["dependency:<br/>WireGuardGoBridge target (per platform)"]
    DEP --> MK["make -C Sources/WireGuardKitGo<br/>(ACTION passed through)"]
    MK --> GR["prepare patched GOROOT<br/>goruntime-boottime-over-monotonic.diff"]
    GR --> GB["go build -buildmode c-archive<br/>per arch in ARCHS<br/>GOOS: macosx to darwin, iphoneos to ios<br/>CC = clang, CGO CFLAGS/LDFLAGS from SDK"]
    GB --> LP["lipo -create<br/>universal libwg-go.a"]
    LP --> LINK["linked into the NE binary<br/>(Frameworks phase of the NE targets;<br/>SPM consumers instead use<br/>Package.swift linkedLibrary wg-go)"]
    MK2["version-header build phase<br/>(app targets only)"] --> VH["wireguard-go-version.h<br/>(sed from go.mod pin)"]
    VH --> APPBIN["compiled into the GUI app<br/>(app bridging header, version display)"]
```

The Makefile takes `ARCHS`, `PLATFORM_NAME`, `SDKROOT`, and the deployment-target flag from Xcode
(with standalone defaults: `macosx`, `x86_64 arm64`), so the same `make` works inside Xcode and from
the CLI. The toolchain is a pinned **Go 1.26.5** download (SHA256-verified, cached in the
gitignored `Sources/WireGuardKitGo/.cache/` so `clean` rebuilds don't re-download) with
`GOTOOLCHAIN=local`, so Go's automatic toolchain switching can never bypass the patched GOROOT.
The boottime patch makes the Go runtime clock keep advancing across device sleep — without it
WireGuard timers misbehave after wake.

## 6. Logging & diagnostics

- `wg_log` writes to both `os_log` and a **ring-buffer log file** (`ringlogger.c`, memory-mapped)
  in the app group container — one file (`tunnel-log.bin`) shared by app (`APP` tag) and NE
  (`NET` tag). The Go core's logs flow through `wgSetLogger` into the same sink.
- `LogViewHelper` + the platform log views read/merge/export the ring buffer.
- NE activation failures reach the app via `last-error.txt` (activation attempt id + error code)
  in the app group container, because the OS reports only generic failure.

## 7. Where the WebSocket/wstunnel work landed (DELIVERED — plan 1)

Per `PROJECT.md`, delivered by `docs/plans/1_websocket_wstunnel_transport_20260808170409.md`:

| Layer | Delivered touch-point |
|---|---|
| Go bridge | `go.mod` `replace` onto the sibling `wireguard-go` fork `v1.3.0`; `conn.NewMultiplexBind` (UDP + WebSocket) in `api-apple.go`; pinned Go 1.26.5 toolchain + refreshed boottime patch in the `Makefile`; T1 `go vet` debt fixed |
| Config model | per-peer WebSocket surface on `PeerConfiguration` (`WsMode`/`WsUrl` + nine parameters) + `ws(s)://` `Endpoint` handling, byte-compatible with the sibling `wireguard-tools` fork |
| Serialization | `TunnelConfiguration+WgQuickConfig` (parse/serialize + validation), `PacketTunnelSettingsGenerator` (UAPI incl. `transport=`), `TunnelConfiguration+UapiConfig` (readback), `highlighter.c` (macOS editor key set) |
| UI | `TunnelViewModel` peer fields, the iOS field editor (mode sheet, switches, TLS document picker into the app-group `ws-tls/` folder) + detail rows, macOS detail rows + highlighter |
| Parity | per-platform path-change semantics (§3) preserved for WebSocket peers on BOTH platforms |
| Tests | `WireGuardKitTests` unit bundle (model, serialization, view model, highlighter) |

Remaining: on-device live-tunnel validation (Manual Test) once the ADP enrollment (P1) completes.
