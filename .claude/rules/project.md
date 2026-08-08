# wireguard-apple — Project Rules

This repo is **wireguard-apple**: the **official [WireGuard](https://www.wireguard.com/) client for
iOS and macOS** — one Xcode project containing an iOS app, a macOS (menu-bar) app, a packet-tunnel
Network Extension per platform, and the shared **WireGuardKit** layer (Swift config model + C crypto
+ the Go userspace core `wireguard-go` compiled to a static `libwg-go.a`). Tunnels are driven
through `NEPacketTunnelProvider` + `WireGuardAdapter`; configurations are stored in the system VPN
preferences with the wg-quick config text in the **Keychain**.

> **STATUS: this is a FORK of upstream `WireGuard/wireguard-apple`** (`origin` =
> `github.com/danielealbano/wireguard-apple`, `upstream` = `github.com/WireGuard/wireguard-apple`).
> **GOAL — DELIVERED IN CODE (plan 1):** per-peer **WebSocket/wstunnel transport** support with
> logical and functional parity with the existing UDP handling, on BOTH iOS and macOS, consuming
> the sibling **`danielealbano/wireguard-go` fork `v1.3.0`** (WebSocket transport + UDP+WebSocket
> multiplex bind), with a config surface byte-compatible with the sibling `wireguard-tools` fork.
> Live-tunnel validation (W6) is Manual Test, pending ADP enrollment (P1). Non-trivial work
> proceeds via the development pipeline per `development_pipeline.md`; the canonical docs MUST be
> kept current as decisions land.

## MANDATORY: Read These First

You MUST ALWAYS read these before ANY work, in this order:

1. **`docs/PROJECT.md`** — what the app is, tech stack, targets and module layout, the Go bridge
   build, config model and storage, platform features, build/commands, testing, roadmap.
2. **`docs/ARCHITECTURE.md`** — targets and dependencies, app-layer wiring (TunnelsManager,
   NETunnelProviderManager, Keychain), the tunnel up/down flow through the Network Extension +
   WireGuardAdapter + cgo bridge, the network-path-change handling, and the config data model
   (with Mermaid charts).
3. **`docs/WORK_INDEX.md`** — the high-level work index: prerequisites, the WebSocket work items,
   inherited debt, and the open decisions gating them.

You MUST ALSO follow, per the Rule Map below: `agent.md`, `development_pipeline.md`, `swift.md`
(all Swift code), `go.md` (the WireGuardKitGo bridge), `apple.md` (Xcode/platform/signing), and
`github.md`. It is ABSOLUTELY MANDATORY to pass ALL quality gates before any work is considered
done.

This rule file MUST stay accurate but CONCISE — it references the canonical docs, it does NOT
duplicate them.

---

## Tech Stack (current)

Versions are authoritative in `WireGuard.xcodeproj/project.pbxproj`,
`Sources/WireGuardApp/Config/Version.xcconfig`, and `Sources/WireGuardKitGo/{go.mod,Makefile}`.
Re-verify before bumping.

| Concern | Choice | Notes |
|---|---|---|
| App language | **Swift** (`SWIFT_VERSION = 5.0`) | UIKit (iOS, programmatic — no storyboards except launch) and AppKit (macOS menu-bar app). No SwiftUI. |
| Shared kit | **WireGuardKit** (Swift) + **WireGuardKitC** (C) | Config model, UAPI generation, adapter; C key/x25519 helpers. Also consumable by third parties via `Package.swift` (SPM). |
| Userspace core | **Go** (cgo `c-archive`) | `Sources/WireGuardKitGo` → universal `libwg-go.a`, wrapping the sibling fork `github.com/danielealbano/wireguard-go v1.3.0` (via `replace`; UDP+WebSocket multiplex bind). Module `golang.zx2c4.com/wireguard/apple`, `go` directive 1.26.5, pinned-download toolchain (`GOTOOLCHAIN=local`). |
| Build system | **Xcode project** (`WireGuard.xcodeproj`) + xcconfig | Deployment: **iOS 15.0 / macOS 12.0**. Go bridge built by `make` via legacy (external build tool) targets. No shared schemes are committed (`*.xcscheme` gitignored). |
| App identity/config | `Config.xcconfig` → `Version.xcconfig` (+ gitignored `Developer.xcconfig`) | `VERSION_NAME`/`VERSION_ID`; `DEVELOPMENT_TEAM`, `APP_ID_IOS`, `APP_ID_MACOS` are developer-local. |
| VPN | `NetworkExtension` packet tunnel (`NEPacketTunnelProvider`) | One NE appex per platform; app ↔ NE via system VPN preferences, app group container, and provider messages. |
| Config storage | `NETunnelProviderManager` preferences + **Keychain** | wg-quick text as generic password, referenced by `passwordReference`. NOT files, NOT a database. |
| Logging | `os_log` + `ringlogger.c` ring-buffer file in the app group container | Tags `APP` / `NET`; log export via `LogViewHelper`. |
| Lint | **SwiftLint** (`.swiftlint.yml` + Xcode build phase) | Also a trailing-whitespace-strip build phase. No other lint/format tooling. |
| Localization | `Base.lproj` + 18 languages, Crowdin | `sync-translations.sh`; `tr()` helper (`LocalizationHelper.swift`). |
| Tests / CI | **`WireGuardKitTests`** (no CI) | macOS unit-test bundle (model/serialization/view-model/highlighter). `test_ringlogger.c` is a standalone harness NOT wired into any target. |

### Xcode targets

| Target | Product / bundle id | Notes |
|---|---|---|
| `WireGuardiOS` | `$(APP_ID_IOS)` | iOS app |
| `WireGuardmacOS` | `$(APP_ID_MACOS)` | macOS menu-bar app (`LSUIElement`) |
| `WireGuardNetworkExtensioniOS` | `$(APP_ID_IOS).network-extension` | iOS packet-tunnel appex |
| `WireGuardNetworkExtensionmacOS` | `$(APP_ID_MACOS).network-extension` | macOS packet-tunnel appex |
| `WireGuardmacOSLoginItemHelper` | `$(APP_ID_MACOS).login-item-helper` | launch-at-login helper |
| `WireGuardGoBridgeiOS` / `WireGuardGoBridgemacOS` | — | legacy targets: `make` in `Sources/WireGuardKitGo` |

The Xcode targets compile the `WireGuardKit`/`WireGuardKitC`/`Shared` sources DIRECTLY into the
app/NE targets (no framework product inside this project); the SPM `WireGuardKit` library product
exists for EXTERNAL consumers.

---

## Hard Project Invariants — ABSOLUTE RULES

- **THE CGO BRIDGE CONTRACT MUST STAY IN SYNC.** The `//export` functions in
  `Sources/WireGuardKitGo/api-apple.go` (`wgSetLogger`/`wgTurnOn`/`wgTurnOff`/`wgSetConfig`/
  `wgGetConfig`/`wgBumpSockets`/`wgDisableSomeRoamingForBrokenMobileSemantics`/`wgVersion`), the C
  declarations in `Sources/WireGuardKitGo/wireguard.h`, and the Swift callers (`WireGuardAdapter`,
  reached via the `WireGuardKitGo` module map / the NE bridging header) MUST always match by name
  and signature. Change one → change all.
- **THE GO BRIDGE BUILD MUST NOT BREAK.** `libwg-go.a` is cross-compiled per-arch
  (`GOOS=darwin|ios`, `-buildmode c-archive`, patched GOROOT via
  `goruntime-boottime-over-monotonic.diff`) and lipo'd by `Sources/WireGuardKitGo/Makefile`, driven
  by the GoBridge legacy targets. A change MUST keep BOTH platforms' builds green for ALL
  configured architectures.
- **BOTH PLATFORMS ARE SACRED.** iOS AND macOS MUST BOTH keep building and working; every
  `#if os(...)` branch MUST be maintained for both, including the platform-divergent behaviors
  (network-path handling, DNS re-resolution, MTU strategy, keychain access control, on-demand
  rules). The WebSocket goal explicitly targets BOTH.
- **THE WIREGUARD CONFIG MODEL IS A CONTRACT.** `TunnelConfiguration`/`InterfaceConfiguration`/
  `PeerConfiguration` parse/serialize wg-quick text (`TunnelConfiguration+WgQuickConfig`) and
  generate UAPI settings (`PacketTunnelSettingsGenerator`, plus `TunnelConfiguration+UapiConfig`
  for runtime readback) — these MUST stay interoperable with standard WireGuard, and `Endpoint`
  parsing follows wireguard-tools `parse_endpoint` semantics.
- **KEYCHAIN-ONLY CONFIG STORAGE.** Tunnel configs (private keys!) live in the Keychain via
  `Keychain.makeReference`/`openReference` and the `passwordReference` persistent ref; the
  macOS multi-user `UID` tagging and the iOS/macOS access-control differences MUST be preserved.
  NEVER store or log key material anywhere else.
- **ADAPTER SEMANTICS ARE DELIBERATE.** `WireGuardAdapter`'s serial `workQueue`, its state machine
  (`stopped`/`started`/`temporaryShutdown`), the `NWPathMonitor` handling (macOS: `wgBumpSockets`;
  iOS: re-resolve + `wgSetConfig` + bump, or temporary shutdown when offline), and the
  `setTunnelNetworkSettings` timeout workaround MUST be preserved.
- **ENTITLEMENTS ARE MINIMAL AND DELIBERATE** (packet-tunnel provider; app groups
  `group.$(APP_ID_IOS)` / `$(DEVELOPMENT_TEAM).group.$(APP_ID_MACOS)`; iOS `wifi-info`; macOS
  sandbox + NE network client/server + app user-selected files). Do NOT add/broaden/remove any
  without user approval (see `apple.md`).
- **NO SECRETS IN LOGS OR COMMITS.** Private keys, preshared keys, and tunnel configs MUST NEVER
  appear in logs or exported artifacts; `Developer.xcconfig` MUST stay gitignored.
- Keep it SIMPLE and consistent with the existing WireGuard code style.

---

## Non-goals (MUST NOT build unless the user EXPLICITLY asks)

- Do NOT re-architect the app (no SwiftUI rewrite, no architecture frameworks, no DI/reactive
  frameworks). Do NOT change config storage away from Keychain + VPN preferences. Do NOT change
  bundle-identifier structure or entitlements. Do NOT implement the WebSocket **transport** here —
  that belongs in the `wireguard-go` fork; this repo will only *consume* it and add config/UI
  support. Do NOT add test targets, CI, or new tooling (formatters, linters, package managers) —
  tooling decisions require the user. Do NOT bump deployment targets, the pinned Go core, or the
  Swift version ad hoc.

---

## Commit Scopes

All commits MUST use one of the scopes below (matching the target/module layout). A commit spanning
multiple scopes uses `app`.

| Scope | Applies to |
|---|---|
| `app` | Cross-cutting changes and anything without its own scope |
| `ios` | iOS app UI (`Sources/WireGuardApp/UI/iOS`) |
| `macos` | macOS app UI (`Sources/WireGuardApp/UI/macOS`, LoginItemHelper) |
| `kit` | `Sources/WireGuardKit` + `Sources/WireGuardKitC` (config model, crypto, adapter) |
| `go` | `Sources/WireGuardKitGo` (Go bridge, Makefile, go.mod) |
| `ne` | `Sources/WireGuardNetworkExtension` |
| `shared` | `Sources/Shared` (keychain, logging, wg-quick parsing, model glue) |
| `xcode` | `WireGuard.xcodeproj`, xcconfig files, `Package.swift`, `.swiftlint.yml` |
| `docs` | `docs/` (PROJECT, ARCHITECTURE, plans) |
| `deps` | Dependency-only updates (`go.mod`/`go.sum`, pinned core bumps) |
| `ci` | CI workflows (none exist yet) |

```
feat(kit): add websocket endpoint field to the peer configuration
```

---

## Standard Commands

There is NO Makefile/wrapper at the repo root; invoke the underlying commands directly. One-time
setup (required before any build): copy `Sources/WireGuardApp/Config/Developer.xcconfig.template`
to `Sources/WireGuardApp/Config/Developer.xcconfig` and fill in `DEVELOPMENT_TEAM`, `APP_ID_IOS`,
`APP_ID_MACOS` (per `README.md`).

| Task | Command |
|---|---|
| Build (IDE, primary) | `open WireGuard.xcodeproj` and build the desired app target |
| Build (CLI, macOS app) | `xcodebuild -project WireGuard.xcodeproj -target WireGuardmacOS -configuration Debug build` |
| Build (CLI, iOS app) | `xcodebuild -project WireGuard.xcodeproj -target WireGuardiOS -configuration Debug build` |
| Lint (Swift) | `swiftlint` (from repo root; also runs as an Xcode build phase) |
| Go bridge (standalone) | `make -C Sources/WireGuardKitGo build` (defaults: `PLATFORM_NAME=macosx`, `ARCHS="x86_64 arm64"`) |
| Go bridge clean | `make -C Sources/WireGuardKitGo clean` |
| Go vet | `cd Sources/WireGuardKitGo && go vet ./...` (works on a macOS host) |
| Go tidy | `cd Sources/WireGuardKitGo && go mod tidy` |
| Go vulncheck | `cd Sources/WireGuardKitGo && govulncheck ./...` |
| Tests (build) | `xcodebuild -project WireGuard.xcodeproj -target WireGuardKitTests -configuration Debug build SYMROOT=build` |
| Tests (run) | `xcrun xctest build/Debug/WireGuardKitTests.xctest` |
| Mermaid check | validate all Mermaid blocks under `docs/` per `development_pipeline.md` §9 |

**Quality gates** (per `development_pipeline.md` §2, `apple.md`, `swift.md`, `go.md`): a clean
build of the iOS AND macOS app targets (which drive the NE + GoBridge targets), **SwiftLint** with
ZERO violations beyond the committed configuration, the **Go bridge** clean (`go vet` /
`go mod tidy` with NO diff / `govulncheck`), the **`WireGuardKitTests` suite passing**, and
**Mermaid validation** (when charts were touched) MUST ALL pass before any work is DONE.

**TEMPORARY deviation (user-approved, until ADP/P1–P2 complete):** the app/NE targets are
compile-verified with `CODE_SIGNING_ALLOWED=NO` appended to the build commands; the signed build
MUST be re-verified once the paid account is active, and this note MUST then be removed.
Additionally, the dev host currently has NO Xcode.app and NO swiftlint (Command Line Tools only),
so the `xcodebuild` gates (both apps + `WireGuardKitTests` bundle), the `iphoneos` Go-bridge
build, and SwiftLint are PENDING first execution — run them as soon as Xcode and swiftlint are
installed (plan 1 `## Deviations` records the substitute verification that was executed).

---

## Testing — ABSOLUTE (project-specific)

- **`WireGuardKitTests`** is THE automated harness: a macOS unit-test bundle compiling the
  model, serialization, view-model, and highlighter sources directly (no `libwg-go.a` link, no
  device, no network, no entitlements, no signing). Run it via the Standard Commands above.
  `Sources/Shared/Logging/test_ringlogger.c` remains a standalone C harness NOT compiled by any
  target. There are no Go tests (mechanical cgo glue under `go.md`'s cross-compiled exemption)
  and no CI.
- **Adding any FURTHER test target/harness (UI tests, Go tests, CI, device farms) is a tooling
  decision that REQUIRES the user's explicit approval** (see `apple.md`/`swift.md`). Keep new
  logic testable (pure Swift/Go, platform-free) and document device-dependent validation as
  **Manual Test** steps.
- Any host-testable pure Go added under `Sources/WireGuardKitGo` MUST follow `go.md` §3 (stdlib
  `testing`, table-driven, `-race`) — the cross-compiled cgo exemption in `go.md` applies ONLY to
  the mechanical `//export` glue.
- Validation of real tunnel behavior currently requires a device/Mac with the developer-signed
  build and is MANUAL. There is no on-device e2e automation; defining one is a pending decision.

---

## Key Conventions

- **All tunnel control goes through `TunnelsManager`** → `NETunnelProviderManager` → the NE appex →
  `PacketTunnelProvider` → `WireGuardAdapter` → the cgo bridge. The app NEVER talks to the Go core
  directly.
- **App ↔ NE channels** are exactly: system VPN preferences (config), Keychain (config text),
  app-group container files (`tunnel-log.bin`, `last-error.txt`, login-helper timestamp), and
  `sendProviderMessage` (runtime config readback). No new side channels.
- **The editor works on `TunnelViewModel`** (field-based sections), not on the immutable-ish model
  directly; macOS also edits raw wg-quick text via `ConfTextView` (+ `highlighter.c` syntax
  highlighting — new config keys MUST be added there too).
- **Platform guards**: `#if os(iOS)` / `#elseif os(macOS)` / `#else` + `#error("Unimplemented")` —
  keep the loud-failure idiom.
- **Errors**: typed enums implementing `WireGuardAppError` (app) / `WireGuardAdapterError` (kit) /
  `PacketTunnelProviderError` (NE), surfaced via `ErrorPresenter`; NE start errors travel via
  `ErrorNotifier` + `last-error.txt`.
- **Logging** via `wg_log` (os_log + ringlogger); NEVER log key material.
- **SwiftLint suppressions**: the ONLY accepted in-code suppressions are the 8 already committed —
  4× `force_cast` (2 of which are the reuse-cell dequeue pattern), 1× `force_try`, 1× `colon`,
  1× `weak_delegate`, 1× `trailing_closure`; NO new ones without user approval.

---

## Rule Map

| Concern | Rule file |
|---|---|
| Agnostic agent behavior, git, plans, reviews, subagents | `agent.md` |
| Plan-driven development pipeline (write → review → implement → PR) + Mermaid validation | `development_pipeline.md` |
| Swift — idioms, boundaries, concurrency, errors, testing, gates (agnostic) | `swift.md` |
| Go — the WireGuardKitGo bridge code (idioms, cgo ABI discipline, testing, gates) (agnostic) | `go.md` |
| Apple — Xcode/xcconfig/SPM, entitlements/Info.plist, NE, lint, signing, release (agnostic) | `apple.md` |
| GitHub (`gh` CLI, branches, PRs) (tooling) | `github.md` |
| Project context (this file) | `project.md` |
