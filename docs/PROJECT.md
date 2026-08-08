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
> **Goal (ROADMAP — not started):** per-peer **WebSocket/wstunnel transport** support with logical
> and functional parity with the existing UDP handling, on BOTH platforms, consuming the sibling
> `danielealbano/wireguard-go` fork (WebSocket transport + UDP/WebSocket multiplex bind), with a
> config surface byte-compatible with the sibling `wireguard-tools` fork. Execution scope and
> sequencing are a pending discussion.

## Tech stack

| Concern | Choice |
|---|---|
| Languages | Swift 5 (app, kit), C (crypto helpers, ringlogger, minizip, highlighter), Go (userspace core bridge), Objective-C (login-item helper `main.m`) |
| UI | UIKit on iOS (programmatic, no storyboards except LaunchScreen), AppKit on macOS (menu-bar app) |
| VPN | `NetworkExtension` — `NEPacketTunnelProvider`, `NETunnelProviderManager`, `NEOnDemandRule` |
| Build | Xcode project `WireGuard.xcodeproj` + xcconfig; Go bridge via `make` legacy targets; `Package.swift` (SPM) for external WireGuardKit consumers |
| Deployment targets | iOS 15.0, macOS 12.0 |
| Config storage | System VPN preferences + Keychain (wg-quick text as generic password) |
| Logging | `os_log` + memory-mapped ring-buffer file (`ringlogger.c`) in the app group container |
| Lint | SwiftLint (`.swiftlint.yml` + build phase) |
| Localization | Base + 18 languages, synced from Crowdin (`sync-translations.sh`) |
| Tests / CI | None (see Testing) |

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

- Module `golang.zx2c4.com/wireguard/apple` (`go` directive 1.17), wrapping the upstream core
  `golang.zx2c4.com/wireguard` pinned at `v0.0.0-20230209153558-1e2c3e5a3c14`.
- `api-apple.go` is a `package main` cgo file exposing the C API via `//export`:
  `wgSetLogger`, `wgTurnOn(settings, tunFd) -> handle`, `wgTurnOff(handle)`,
  `wgSetConfig(handle, settings) -> int64`, `wgGetConfig(handle) -> char*`,
  `wgBumpSockets(handle)`, `wgDisableSomeRoamingForBrokenMobileSemantics(handle)`, `wgVersion()`.
  The matching C declarations live in `wireguard.h` (consumed by the `WireGuardKitGo` module map
  and the NE bridging header). **These three surfaces must always match — change one → change all.**
- `wgTurnOn` dups the utun fd, wraps it with `tun.CreateTUNFromFile`, builds the device with
  `conn.NewStdNetBind()`, applies the UAPI settings, brings the device up, and returns an `int32`
  handle into a `tunnelHandles` map. The map is unguarded on the Go side: all tunnel-handle
  operations issued while the adapter is alive run on the adapter's private serial queue, while the
  init/deinit-time calls (`wgSetLogger`, the `deinit` `wgTurnOff`) and `wgVersion` run on the
  caller's thread and are non-concurrent only by object-lifetime ordering. `wgBumpSockets` rebinds
  sockets (retrying up to 10×) and sends keepalives — used on network path changes.
- The `Makefile` builds one `libwg-go-<arch>.a` per configured architecture
  (`-buildmode c-archive`, `GOOS` mapped from the Xcode platform: `macosx`→`darwin`,
  `iphoneos`→`ios`) using a **patched GOROOT** (`goruntime-boottime-over-monotonic.diff`, so time
  keeps advancing across device sleep) and lipo's them into a universal `libwg-go.a`. It also
  generates `wireguard-go-version.h` from the `go.mod` pin.
- Known pre-existing debt inherited from upstream (verified 2026-08-08): `go vet` reports 3
  findings in `api-apple.go` (unbuffered `os.Signal` channel passed to `signal.Notify`, and two
  `unsafe.Pointer` misuse warnings). To be fixed with the first change touching the bridge.

## Config model & storage

- **Model** (`WireGuardKit`): `TunnelConfiguration` (name + `InterfaceConfiguration` +
  `[PeerConfiguration]`), `Endpoint` (host:port, wireguard-tools `parse_endpoint` semantics),
  `IPAddressRange`, `DNSServer`, and `PrivateKey`/`PublicKey`/`PreSharedKey` (32-byte keys backed
  by `WireGuardKitC` hex/base64/x25519 helpers).
- **wg-quick text** (`Shared/Model/TunnelConfiguration+WgQuickConfig.swift`): parses/serializes the
  wg-quick subset — Interface: `PrivateKey`, `ListenPort`, `Address`, `DNS` (servers + search
  domains), `MTU`; Peer: `PublicKey`, `PresharedKey`, `AllowedIPs`, `Endpoint`,
  `PersistentKeepalive`. Unknown keys are parse errors.
- **UAPI** (`WireGuardKit/PacketTunnelSettingsGenerator.swift`): generates the userspace
  `key=value` configuration passed to `wgTurnOn`/`wgSetConfig` (keys hex-encoded, endpoints
  resolved first); `TunnelConfiguration+UapiConfig` parses the runtime config returned by
  `wgGetConfig` (rx/tx bytes, last handshake) for the UI.
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

There are **no automated tests**: no XCTest targets, no Go tests, no CI.
`Sources/Shared/Logging/test_ringlogger.c` is a standalone C harness not wired into any target.
Adding any harness is a tooling decision that requires explicit approval (see
`.claude/rules/project.md` → Testing). Tunnel behavior is validated manually on a signed build.

## Roadmap

- **WebSocket/wstunnel transport support** (the fork's goal): consume the sibling
  `danielealbano/wireguard-go` fork (UDP + WebSocket multiplex bind), extend the config model,
  wg-quick parsing, UAPI generation, and both platforms' editors with the per-peer WebSocket
  surface (byte-compatible with the sibling `wireguard-tools` fork), keeping full parity with the
  existing UDP behavior on iOS AND macOS. Execution scope and sequencing are a pending discussion.
- The high-level work breakdown (prerequisites, work items, inherited debt, open decisions) is
  tracked in `WORK_INDEX.md`.

## License

MIT (see `COPYING`); "WireGuard" and the "WireGuard" logo are registered trademarks of Jason A.
Donenfeld.
