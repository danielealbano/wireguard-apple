# wireguard-apple — Project

## What this is

**wireguard-apple** is the official [WireGuard](https://www.wireguard.com/) client for **iOS and
macOS**, MIT-licensed, built from a single Xcode project. It manages WireGuard tunnels through the
Apple **NetworkExtension** framework: the GUI app creates/edits tunnel configurations and saves
them into the system VPN preferences; a **packet-tunnel app extension** (one per platform) runs the
actual tunnel by driving the userspace WireGuard core (**wireguard-go**, compiled to a static
library) over a small cgo bridge.

> **Fork status:** this repository is a fork of `WireGuard/wireguard-apple`
> (`origin` = `github.com/danielealbano/wireguard-apple`,
> `upstream` = `github.com/WireGuard/wireguard-apple`).
> **Goal — DELIVERED IN CODE (plan 1):** per-peer **WebSocket/wstunnel transport** support with
> logical and functional parity with the existing UDP handling, on BOTH platforms, consuming the
> sibling `danielealbano/wireguard-go` fork (WebSocket transport + UDP/WebSocket multiplex bind),
> with a config surface byte-compatible with the sibling `wireguard-tools` fork. Live-tunnel
> validation (W6) is Manual Test, pending the Apple Developer Program enrollment (P1).

## Tech stack

| Concern | Choice |
|---|---|
| Languages | Swift 5 (app, kit), C (crypto helpers, ringlogger, minizip, highlighter), Go (userspace core bridge), Objective-C (login-item helper `main.m`) |
| UI | UIKit on iOS (programmatic, no storyboards except LaunchScreen), AppKit on macOS (menu-bar app) |
| VPN | `NetworkExtension` — `NEPacketTunnelProvider`, `NETunnelProviderManager`, `NEOnDemandRule` |
| Build | Xcode project `WireGuard.xcodeproj` + xcconfig; Go bridge via `make` legacy targets (pinned-download Go 1.26.5 toolchain, `GOTOOLCHAIN=local`); `Package.swift` (SPM) for external WireGuardKit consumers |
| Deployment targets | iOS 15.0, macOS 12.0 |
| Config storage | System VPN preferences + Keychain (wg-quick text as generic password) |
| Logging | `os_log` + memory-mapped ring-buffer file (`ringlogger.c`) in the app group container |
| Lint | SwiftLint (`.swiftlint.yml` + build phase) |
| Localization | Base + 18 languages, synced from Crowdin (`sync-translations.sh`) |
| Tests / CI | `WireGuardKitTests` macOS unit-test bundle (see Testing); no CI |

## Repository layout

```
Package.swift                        SPM manifest (WireGuardKit for external consumers)
WireGuard.xcodeproj/                 The Xcode project (all app/NE/bridge targets)
Sources/
  WireGuardKit/                      Swift kit: config model, DNS resolution, UAPI generation,
                                     WireGuardAdapter (the NE-side tunnel driver)
  WireGuardKitC/                     C helpers: key hex/base64 (key.c), x25519 keygen/derive,
                                     utun control structs (WireGuardKitC.h)
  WireGuardKitGo/                    Go cgo bridge: api-apple.go (//export API), wireguard.h,
                                     Makefile (c-archive build + lipo), go.mod/go.sum,
                                     goruntime-boottime-over-monotonic.diff
  WireGuardNetworkExtension/         NEPacketTunnelProvider subclass, ErrorNotifier,
                                     per-platform entitlements + Info.plist
  WireGuardApp/                      The GUI app (both platforms)
    Config/                          Config.xcconfig, Version.xcconfig, Developer.xcconfig.template
    Tunnel/                          TunnelsManager, TunnelContainer, ActivateOnDemandOption,
                                     TunnelConfiguration+UapiConfig, TunnelErrors, MockTunnels
    UI/                              TunnelViewModel, TunnelImporter + shared UI helpers
    UI/iOS/                          UIKit app (view controllers, QR scan, settings, log view)
    UI/macOS/                        AppKit app (status item + menu, manage-tunnels window,
                                     ConfTextView editor + highlighter.c, LoginItemHelper)
    ZipArchive/                      zip import/export (minizip)
    *.lproj/                         Localizable.strings (Crowdin-managed)
  Shared/                            Code shared app ↔ NE: Keychain, Logger + ringlogger.c,
                                     TunnelConfiguration+WgQuickConfig (parser/serializer),
                                     NETunnelProviderProtocol+Extension, FileManager+Extension
MOBILECONFIG.md                      How to install tunnels via .mobileconfig profiles
sync-translations.sh                 Crowdin localization sync
```

## Xcode targets

| Target | Kind | Bundle id | Purpose |
|---|---|---|---|
| `WireGuardiOS` | app | `$(APP_ID_IOS)` | iOS app |
| `WireGuardmacOS` | app | `$(APP_ID_MACOS)` | macOS menu-bar app (`LSUIElement`) |
| `WireGuardNetworkExtensioniOS` | appex | `$(APP_ID_IOS).network-extension` | iOS packet tunnel |
| `WireGuardNetworkExtensionmacOS` | appex | `$(APP_ID_MACOS).network-extension` | macOS packet tunnel |
| `WireGuardmacOSLoginItemHelper` | app | `$(APP_ID_MACOS).login-item-helper` | launch-at-login helper |
| `WireGuardGoBridgeiOS` / `WireGuardGoBridgemacOS` | legacy (external build tool) | — | run `make` in `Sources/WireGuardKitGo` |

Notes:
- The app and NE targets compile the `WireGuardKit`, `WireGuardKitC`, and `Shared` **sources
  directly** (no framework product inside this project). The SPM `WireGuardKit` library product in
  `Package.swift` exists for **external** consumers, which must create the `WireGuardGoBridge`
  external-build-system target themselves (see `README.md`).
- No shared Xcode schemes are committed (`*.xcscheme` is gitignored); opening the project in Xcode
  generates local schemes.
- The NE targets depend on the matching GoBridge target and link `libwg-go.a`.

## The Go bridge (`Sources/WireGuardKitGo`)

- Module `golang.zx2c4.com/wireguard/apple` (`go` directive 1.26.5), wrapping
  `golang.zx2c4.com/wireguard` **replaced by the sibling fork
  `github.com/danielealbano/wireguard-go v1.3.0`** (UDP + WebSocket multiplex bind).
- `api-apple.go` is a `package main` cgo file exposing the C API via `//export`:
  `wgSetLogger`, `wgTurnOn(settings, tunFd) -> handle`, `wgTurnOff(handle)`,
  `wgSetConfig(handle, settings) -> int64`, `wgGetConfig(handle) -> char*`,
  `wgBumpSockets(handle)`, `wgDisableSomeRoamingForBrokenMobileSemantics(handle)`, `wgVersion()`.
  The matching C declarations live in `wireguard.h` (consumed by the `WireGuardKitGo` module map
  and the NE bridging header). **These three surfaces must always match — change one → change all.**
- `wgTurnOn` dups the utun fd, wraps it with `tun.CreateTUNFromFile`, builds the device with
  `conn.NewMultiplexBind(conn.WithWSLogger(...))` — one bind carrying UDP and WebSocket/wstunnel
  peers; the UDP data path is the unchanged platform `StdNetBind`, and no fd-protect upcall is
  needed on Apple platforms — applies the UAPI settings, brings the device up (`Up()`'s error is
  handled), and returns an `int32` handle into a mutex-guarded `tunnelHandles` map (init/
  deinit-time calls run on the caller's thread, racing the adapter's serial-queue calls).
  `wgBumpSockets` calls `device.BindUpdate()` (retrying up to 10×) and sends keepalives — on a
  network path change this rebinds the UDP sockets AND re-dials WebSocket connections.
- The `Makefile` downloads the official **Go 1.26.5** tarball (SHA256-verified, cached in the
  gitignored `Sources/WireGuardKitGo/.cache/`), extracts it, applies the boottime patch
  (`goruntime-boottime-over-monotonic.diff`, so time keeps advancing across device sleep), and
  exports `GOTOOLCHAIN=local` so Go's automatic toolchain switching can never bypass the patched
  GOROOT. It builds one `libwg-go-<arch>.a` per configured architecture (`-buildmode c-archive`,
  `GOOS` mapped from the Xcode platform: `macosx`→`darwin`, `iphoneos`→`ios`) and lipo's them
  into a universal `libwg-go.a`. It also generates `wireguard-go-version.h` from the `go.mod`
  `replace` line (`1.3.0`), failing loudly if the pin cannot be extracted.

## Config model & storage

- **Model** (`WireGuardKit`): `TunnelConfiguration` (name + `InterfaceConfiguration` +
  `[PeerConfiguration]`), `Endpoint` (host:port, wireguard-tools `parse_endpoint` semantics),
  `IPAddressRange`, `DNSServer`, `PrivateKey`/`PublicKey`/`PreSharedKey` (32-byte keys backed
  by `WireGuardKitC` hex/base64/x25519 helpers), and the per-peer WebSocket surface: `WsMode`
  (`websocket`|`wstunnel`), `WsUrl` (`ws(s)://host:port[/path]`, explicit port required, stored
  verbatim; userinfo rejected and query/fragment accepted only after a path — the tools fork's
  acceptance set; the URL host:port doubles as the routable `Endpoint`), plus `wstunnelTarget`,
  `wsBearer` (secret — never logged or shown), `wsMask`, `wsTlsCa`/`wsTlsCert`/`wsTlsKey` (file
  paths), `wsTlsInsecure`, and `wsPingIntervalMs`/`wsBackoffMinMs`/`wsBackoffMaxMs` (0 ⇒ default,
  dropped).
- **wg-quick text** (`Shared/Model/TunnelConfiguration+WgQuickConfig.swift`): parses/serializes the
  wg-quick subset — Interface: `PrivateKey`, `ListenPort`, `Address`, `DNS` (servers + search
  domains), `MTU`; Peer: `PublicKey`, `PresharedKey`, `AllowedIPs`, `Endpoint` (`host:port` or a
  `ws(s)://` URL), `PersistentKeepalive`, `WSMode`, `WSTunnelTarget`, `WSBearer`, `WSMask`,
  `WSTLSCA`, `WSTLSCert`, `WSTLSKey`, `WSTLSInsecure`, `WSPingInterval`, `WSBackoffMin`,
  `WSBackoffMax` — byte-compatible with the sibling `wireguard-tools` fork, including its
  validation rules (a `ws(s)://` endpoint requires `WSMode`; `WSMode` forbids a `host:port`
  endpoint; inbound peers are websocket-only; wstunnel requires URL + target; ANY `WS*` key on a
  UDP peer is an error by presence, not value). Unknown keys are parse errors.
- **UAPI** (`WireGuardKit/PacketTunnelSettingsGenerator.swift`): generates the userspace
  `key=value` configuration passed to `wgTurnOn`/`wgSetConfig` (keys hex-encoded, endpoints
  resolved first; `transport=` on every peer, `ws_*` for WebSocket peers — a dialing peer's block
  travels only with a successfully resolved `endpoint=`, and the iOS endpoint re-resolution path
  re-sends the full block); `TunnelConfiguration+UapiConfig` parses the runtime config returned by
  `wgGetConfig` (rx/tx bytes, last handshake, `transport=`/`ws_*` round-trip) for the UI.
- **WS TLS files**: TLS CA/cert/key files referenced by WS peers live in the app group
  container's `ws-tls/` folder (the only location both the app and the NE sandbox can read); the
  iOS editor's document picker copies picked files there, macOS users place files there manually.
- **Storage**: each tunnel is a `NETunnelProviderManager` entry in the system VPN preferences.
  The wg-quick text itself is stored in the **Keychain** as a generic password; the manager's
  `protocolConfiguration.passwordReference` holds the persistent reference
  (`Shared/Keychain.swift`, `NETunnelProviderProtocol+Extension.swift`). On macOS the provider
  configuration also carries the owning `UID` (multi-user support) and the keychain item's ACL
  trusts the app + the NE appex; on iOS the item lives in the app group access group. Legacy
  configurations stored inline (`WgQuickConfig`) — the `.mobileconfig` install path — are migrated
  to the Keychain on load.

## App architecture (GUI side)

- **`TunnelsManager`** (`WireGuardApp/Tunnel/`) owns the tunnel list: loads all
  `NETunnelProviderManager`s, migrates/verifies keychain references, deletes orphans, sorts by
  name, and exposes add/modify/remove/activate/deactivate. Status flows in via
  `NEVPNStatusDidChange`; external config changes via `NEVPNConfigurationChange` → `reload()`.
  Only one tunnel is active at a time: activating a tunnel while another runs parks the new one in
  `.waiting` and deactivates the old one first (`ActivateOnDemand` is disabled before deactivation
  when needed). In the simulator, `MockTunnels` replaces the (unavailable) NE stack.
- **`TunnelContainer`** wraps one manager: KVO-observable `name`/`status`/on-demand flags,
  activation with retry (re-enable + reload on stale/invalid configuration, up to 8 attempts), and
  runtime-config readback over `sendProviderMessage`.
- **`TunnelViewModel`** is the field-based editor model (interface fields: name, keys, addresses,
  listen port, MTU, DNS; peer fields: keys, endpoint, allowed IPs, keepalive, rx/tx, handshake,
  exclude-private-IPs) used by both platforms' editors.
- **On-demand** (`ActivateOnDemandOption`): off / Wi-Fi (any or SSID-scoped) / cellular (iOS) /
  ethernet (macOS), mapped onto `NEOnDemandRule`s; SSID scoping needs the iOS `wifi-info`
  entitlement.
- **Import/export**: `.conf` files, zip archives (minizip-based `ZipArchive`), iOS QR-code scan;
  macOS exports a zip of all tunnels (behind `PrivateDataConfirmation` re-authentication).
- **iOS UI**: `MainViewController` (split view: tunnel list + detail), tunnel edit table VC, QR
  scan, settings (log export, version info), and home-screen quick actions fed by
  `RecentTunnelsTracker`.
- **macOS UI**: status-bar item + `StatusMenu` (tunnel toggles, manage window), manage-tunnels
  window (`ManageTunnelsRootViewController`: list + detail/edit), `ConfTextView` raw-text editor
  with C syntax highlighter (`highlighter.c` — new config keys must be added there too),
  `TunnelsTracker` (status-icon state), `LoginItemHelper` (launch at login), Mac App Store update
  detector (defers updates while a tunnel is up).

## Network Extension side

- **`PacketTunnelProvider`** (`WireGuardNetworkExtension/`) reads the saved configuration
  (Keychain via `passwordReference`), then drives **`WireGuardAdapter`**
  (`WireGuardKit/WireGuardAdapter.swift`):
  - resolves peer endpoints (`DNSResolver`, DNS64-aware),
  - applies `NEPacketTunnelNetworkSettings` (addresses, routes from allowed IPs, DNS,
    MTU — iOS defaults to 1280, macOS uses `tunnelOverheadBytes = 80`; a 5s timeout works around
    `setTunnelNetworkSettings` sometimes never calling back),
  - locates the utun fd, calls `wgTurnOn`, and tracks state on a private serial queue
    (`stopped`/`started`/`temporaryShutdown`).
- **Network path changes** (`NWPathMonitor`): macOS bumps sockets; iOS re-resolves endpoints,
  reapplies the endpoint config, bumps sockets — or tears down to `temporaryShutdown` when offline
  and restarts when connectivity returns. iOS also applies
  `wgDisableSomeRoamingForBrokenMobileSemantics`.
- **Errors**: NE start errors are written (with the activation attempt id) to `last-error.txt` in
  the app group container (`ErrorNotifier`) and surfaced by the app after the failed activation.
  On macOS, `stopTunnel` ends with `exit(0)` — a documented workaround for an Apple NE bug.
- **App ↔ NE channels** (the only ones): VPN preferences, Keychain, app group container files
  (`tunnel-log.bin`, `last-error.txt`, `login-helper-timestamp.bin`), and provider messages
  (message `0x0` → runtime UAPI config).

## Entitlements & security

- Apps + NEs: `com.apple.developer.networking.networkextension` = `packet-tunnel-provider`.
- App groups: iOS `group.$(APP_ID_IOS)`; macOS `$(DEVELOPMENT_TEAM).group.$(APP_ID_MACOS)`.
- iOS app: `wifi-info` (SSID for on-demand rules). macOS: app sandbox everywhere; the app adds
  user-selected file read-write (import/export), the NE adds network client/server.
- Tunnel configs (containing private keys) live ONLY in the Keychain; key material never appears
  in logs; macOS re-authenticates the user before revealing private keys or exporting
  (`PrivateDataConfirmation`).

## Building

1. `cp Sources/WireGuardApp/Config/Developer.xcconfig.template Sources/WireGuardApp/Config/Developer.xcconfig`
   and fill in `DEVELOPMENT_TEAM` (Apple developer Team ID) and `APP_ID_IOS`/`APP_ID_MACOS`
   (app ids registered with the Network Extensions capability). This file is gitignored.
2. Install tools: `swiftlint` and `go` (Homebrew). Xcode with the iOS/macOS SDKs.
3. `open WireGuard.xcodeproj`, pick the app target for the desired platform, build. The NE target
   and the GoBridge `make` target build as dependencies. CLI:
   `xcodebuild -project WireGuard.xcodeproj -target WireGuardmacOS -configuration Debug build`
   (or `-target WireGuardiOS`).

Building and running a packet-tunnel provider requires a **paid Apple Developer account** and app
ids with the Network Extensions capability — there is no entitlement-free path.

## Versioning & release

- `Sources/WireGuardApp/Config/Version.xcconfig`: `VERSION_NAME` (marketing, currently 1.0.16) and
  `VERSION_ID` (build number, currently 27) feed every target's Info.plist.
- Releases are signed Release builds distributed through the App Store / TestFlight; tunnels can
  also be provisioned via `.mobileconfig` profiles (see `MOBILECONFIG.md`). There is no CI or
  release automation in this repo.

## Testing

- **`WireGuardKitTests`** is a macOS unit-test bundle target compiling the model, serialization,
  view-model, and highlighter sources directly (no `libwg-go.a` link, no signing, no network, no
  device). Scope: `WsUrl` parsing, wg-quick round-trip + validation, UAPI generation + readback,
  the highlighter's key/URL acceptance, and the `TunnelViewModel` WS validation surface. Run:
  `xcodebuild -project WireGuard.xcodeproj -target WireGuardKitTests -configuration Debug build
  SYMROOT=build` then `xcrun xctest build/Debug/WireGuardKitTests.xctest`.
- There are no Go tests (the bridge is mechanical cgo glue under the cross-compiled exemption) and
  no CI. `Sources/Shared/Logging/test_ringlogger.c` is a standalone C harness not wired into any
  target. Adding any FURTHER harness is a tooling decision that requires explicit approval (see
  `.claude/rules/project.md` → Testing). Tunnel behavior is validated manually on a signed build.

## Roadmap

- **WebSocket/wstunnel transport support** (the fork's goal): **delivered in code by plan 1**
  (`docs/plans/1_websocket_wstunnel_transport_20260808170409.md`) — fork consumption, config
  model, all serialization surfaces, both platforms' UI, and the unit-test harness. Live-tunnel
  validation on device (W6) is Manual Test, pending the Apple Developer Program enrollment (P1).
- The high-level work breakdown (prerequisites, work items, inherited debt, open decisions) is
  tracked in `WORK_INDEX.md`.

## License

MIT (see `COPYING`); "WireGuard" and the "WireGuard" logo are registered trademarks of Jason A.
Donenfeld.
