# wireguard-apple — Work Index

High-level index of the work ahead on this fork. It tracks WHAT has to happen and in which state
it is — the HOW lands per item as a plan in `docs/plans/` via the development pipeline
(`.claude/rules/development_pipeline.md`). This index MUST be kept current as items land or
decisions are made; details live in the canonical docs (`PROJECT.md`, `ARCHITECTURE.md`), not here.

Statuses: **PREREQUISITE** (blocks everything downstream) · **NOT STARTED** (agreed goal, awaiting
its plan) · **PENDING DECISION** (must be discussed before work starts) · **DEBT** (inherited,
fix bundled with the first touching change).

## 1. Prerequisites

| ID | Item | Status | Notes |
|---|---|---|---|
| P1 | Apple Developer Program enrollment (paid) | PREREQUISITE — enrollment underway | Required for the packet-tunnel Network Extension entitlement; there is no entitlement-free path (see `PROJECT.md` → Building) |
| P2 | Local signing setup | PREREQUISITE | `Developer.xcconfig` with `DEVELOPMENT_TEAM` + `APP_ID_IOS`/`APP_ID_MACOS` (app ids registered with the Network Extensions capability); file stays gitignored |
| P3 | Baseline build validation | PREREQUISITE | Build the UNMODIFIED fork for both platforms on the dev machine (validates Xcode, `go`, `swiftlint` toolchain) before any change lands |

## 2. WebSocket/wstunnel transport — the fork's goal

Add per-peer WebSocket/wstunnel transport with **logical and functional parity with the existing
UDP handling, on BOTH iOS and macOS**, consuming the sibling `danielealbano/wireguard-go` fork,
with a config surface byte-compatible with the sibling `wireguard-tools` fork. Overall status:
**W1–W5 DELIVERED (plan 1, `docs/plans/1_websocket_wstunnel_transport_20260808170409.md`)**;
W6 is PENDING P1 (ADP). The work items map onto the touch-points in `ARCHITECTURE.md` §7:

| ID | Item | Scope |
|---|---|---|
| W1 | Go bridge onto the fork | `go.mod` `replace` onto the sibling `wireguard-go` fork; reconcile the Go toolchain (the fork requires a newer Go than the current `go 1.17` floor — `Makefile` implications); build the UDP+WebSocket multiplex bind in `api-apple.go` in place of `conn.NewStdNetBind()`; keep the `wgBumpSockets` semantics; no fd-protect upcall is needed on Apple platforms |
| W2 | Config model | Per-peer WebSocket surface on `PeerConfiguration` (+ `Endpoint` handling), byte-compatible with the sibling `wireguard-tools` fork |
| W3 | Serialization surfaces | `TunnelConfiguration+WgQuickConfig` (parse/serialize), `PacketTunnelSettingsGenerator` (UAPI generation), `TunnelConfiguration+UapiConfig` (readback), `highlighter.c` (macOS raw-text editor key set) |
| W4 | UI | `TunnelViewModel` peer fields + the iOS and macOS tunnel editors |
| W5 | Behavior parity | Preserve the per-platform path-change semantics for WebSocket peers (macOS: socket bump; iOS: re-resolve / temporary shutdown), MTU and on-demand behavior, on BOTH platforms |
| W6 | Validation | **PENDING P1 (ADP)** — manual test pass on both platforms against a live WireGuard/wstunnel server, including network-switch scenarios (steps in plan 1 US9) |

## 3. Inherited debt

| ID | Item | Status | Notes |
|---|---|---|---|
| T1 | 3× `go vet` findings in `api-apple.go` | **FIXED (plan 1)** | Buffered signal channel + `unsafe.Pointer` parameters in `wgSetLogger` (root-cause fixes, ABI unchanged) |

## 4. Open decisions

| ID | Decision | Status | Notes |
|---|---|---|---|
| D1 | Fork identity / rebranding | PENDING DECISION | "WireGuard" is a registered trademark of Jason A. Donenfeld; a distinct product name, bundle identifiers, icons, and distribution channel for the fork have not been decided |
| D2 | Test harness | **RESOLVED (plan 1)** | User approved; the `WireGuardKitTests` unit bundle exists. Any FURTHER harness (UI tests, Go tests, CI) still requires explicit approval |
| D3 | CI | PENDING DECISION | No CI exists; adding workflows is a tooling decision requiring explicit approval |
| D4 | Execution plan for the WebSocket work | **RESOLVED** | Single plan (plan 1, `docs/plans/1_websocket_wstunnel_transport_20260808170409.md`), implemented end to end |
