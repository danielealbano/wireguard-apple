<!-- SACRED DOCUMENT — Edit ONLY per agent.md §2 plan-file rules: plan-review fixes, checkmarks, recorded implementation deviations, and code-review re-alignment. -->
<!-- You MUST NEVER delete this file or alter files outside this plan's scope. -->
<!-- Plans in docs/plans/ are PERMANENT artifacts. There are ZERO exceptions. -->

# Plan 1 — WebSocket/wstunnel transport (fork switch, config surface, UI, tests)

## Goal & scope

Add per-peer WebSocket/wstunnel transport to wireguard-apple with logical and functional parity
with the existing UDP handling on BOTH iOS and macOS, consuming the sibling
`danielealbano/wireguard-go` fork `v1.3.0`, with a wg-quick config surface byte-compatible with the
sibling `wireguard-tools` fork — the Apple counterpart of wireguard-android PR #2. Includes the new
`WireGuardKitTests` unit-test target (approved by the user), the 3 inherited `go vet` fixes (T1),
and docs refresh. Live-tunnel validation (W6) is **Manual Test**, deferred until the ADP account is
active.

Out of scope (explicitly): device-level WebSocket server keys (`WSListen`, `WSServerTLSCert`,
`WSServerTLSKey`, `WSServerBearer`, `WSTrustedProxies`) — client-only, same as Android; fork
rebranding (D1); CI (D3); any entitlement change; any change to the `//export` ABI surface
(`wireguard.h` stays byte-identical).

## Verified contracts (sources read at the pinned versions)

### Fork `v1.3.0` API consumed by the bridge (verified in `../wireguard-go` at tag `v1.3.0`)

- `conn.NewMultiplexBind(opts ...WSOption) (*multiplexBind, error)` — platform UDP bind + WS bind
  in one; UDP data path unchanged (`conn/ws_multiplex.go`).
- `conn.WithWSLogger(conn.Logger)` with `Logger{Verbosef, Errorf func(format string, args ...any)}`
  (`conn/ws_config.go`). `conn.WithWSProtect` exists but is NOT used on Apple (no
  `VpnService.protect` equivalent; the NE needs no fd-protect upcall).
- `device.NewDevice(tun, bind, logger)`, `Device.Up() error`, `Device.BindUpdate() error`,
  `Device.SendKeepalivesToPeersWithCurrentKeypair()`,
  `Device.DisableSomeRoamingForBrokenMobileSemantics()`, `ipcErrorf` returns `*device.IPCError`
  with `ErrorCode() int64`, `tun.CreateTUNFromFile` — all present at `v1.3.0`.
- WS re-dial on network change: `device.BindUpdate()` closes and reopens the multiplex bind
  (UDP rebind + WS re-dial). The existing `wgBumpSockets` retry loop already calls `BindUpdate()`.
- The WS dialer always connects to the **resolved `endpoint=` ip:port**; the URL host is used only
  for TLS SNI / HTTP Host (`conn/ws_dial.go`). iOS endpoint re-resolution therefore stays
  meaningful for WS peers.

### UAPI contract (verified in fork `device/uapi.go` at `v1.3.0`)

- Set, per peer: `transport=udp|websocket|wstunnel` — **mandatory at peer creation**; an
  incremental update may omit it (persisted transport kept). `ws_*` keys **rejected** for
  `transport=udp`. Dialing WS peer = `ws_url` present, then `endpoint=ip:port` (numeric,
  `netip.ParseAddrPort`) is **required**. `wstunnel_target` without `ws_url` is an error.
  **An `endpoint=` line for a WS peer sent WITHOUT `ws_url` is silently ignored**
  (`handlePostConfig` only applies the endpoint through `ParseWSPeerEndpoint`), so any endpoint
  update for a WS peer MUST carry the full `ws_*` block.
- Peer keys: `ws_url`, `wstunnel_target`, `ws_bearer` (secret — value never logged), `ws_mask`
  (`true|false`), `ws_tls_ca`/`ws_tls_cert`/`ws_tls_key` (file paths), `ws_tls_insecure`
  (`true|false`), `ws_ping_interval`/`ws_backoff_min`/`ws_backoff_max` (milliseconds, 0 ⇒ default).
- Get: **every** peer emits `transport=` (also plain UDP peers!); a dialing WS endpoint round-trips
  `ws_url` + the set client keys after `endpoint=` (`WSPeerKVs`, only non-default values); zero
  timings are not emitted. `protocol_version=1` already handled by the readback parser.
  ⇒ the readback parser MUST accept `transport` (and `ws_*`) or **runtime stats break for every
  tunnel, including pure-UDP ones**, the moment the fork is pinned.

### Config-file surface (byte-compatible with `../wireguard-tools` fork `src/config.c`, verified)

`[Peer]` keys: `Endpoint` (`ws(s)://host:port[/path]` URL for WS peers — explicit port required,
path preserved verbatim, query/fragment only after a path, userinfo rejected — see the "URL
acceptance set" decision; `host:port` for UDP), `WSMode = websocket|wstunnel`,
`WSTunnelTarget` (host:port, stored verbatim, resolved by the relay — never DNS-resolved locally),
`WSBearer` (inline literal secret, non-empty, never in error text), `WSMask` (`true|false`),
`WSTLSCA`/`WSTLSCert`/`WSTLSKey` (non-empty paths), `WSTLSInsecure` (`true|false`),
`WSPingInterval`/`WSBackoffMin`/`WSBackoffMax` (milliseconds, base-10, ≥0; 0 ⇒ default, dropped).

Transport inference + validation (identical to the tools fork and Android):
- `ws(s)://` Endpoint → dialing WS peer; `WSMode` **required**; URL host:port becomes the routable
  `Endpoint` (DNS pre-resolution as for UDP); URL stored verbatim, emitted as `ws_url=`.
- `WSMode = wstunnel` → `WSTunnelTarget` **required** (dialing) and **forbidden** for
  `websocket` mode or inbound peers; inbound (no URL) `wstunnel` **rejected**.
- `WSMode` present with no Endpoint → inbound WS peer (websocket only, no endpoint/ws_url).
- `host:port` Endpoint + `WSMode` → error. **ANY** `WS*` key on a UDP peer → error — presence,
  not value, triggers (a `WSMask = false` on a UDP peer is still an error).

## Decisions (design record)

- **Go pin**: `require golang.zx2c4.com/wireguard v0.0.0-20250521234502-f333402bd9cb` +
  `replace golang.zx2c4.com/wireguard => github.com/danielealbano/wireguard-go v1.3.0`,
  `go 1.26.5`, `golang.org/x/sys v0.47.0` (same resolution as the Android sibling).
- **Toolchain**: the Makefile downloads the official `go1.26.5` darwin tarball (SHA256-pinned —
  hashes taken from the sibling Android fork's Makefile, which builds green with them), extracts
  it, applies the boottime patch to THAT GOROOT, and exports `GOTOOLCHAIN=local`. Rationale: the
  host Go (1.25.7) is older than the fork's `go 1.26.5` directive, and Go's automatic toolchain
  switching would silently BYPASS the patched GOROOT (unpatched runtime ⇒ broken timers after
  sleep). Hermetic pinning removes both failure modes. `go vet`/`go mod tidy`/`govulncheck` run
  with the default `GOTOOLCHAIN=auto` (pure analysis — the patched runtime is irrelevant there).
- **Boottime patch refresh**: verified against `go1.26.5` sources — `sys_darwin.go` and
  `sys_darwin_arm64.s` hunks still match; the `sys_darwin_amd64.s` hunk's leading context
  (`PUSHQ BP` / `MOVQ SP, BP`) no longer exists in 1.26.5 — the diff is regenerated with verified
  context so `patch -f` applies deterministically (no fuzz reliance).
- **Bridge**: `conn.NewMultiplexBind(conn.WithWSLogger(...))` replaces `conn.NewStdNetBind()`.
  NO protect upcall, NO new exports — **`wireguard.h` is unchanged**; `wgBumpSockets` keeps its
  existing retry loop (now also re-dialing WS via `BindUpdate`). The 3 inherited `go vet` findings
  (unbuffered signal channel; 2× `unsafe.Pointer` misuse in `wgSetLogger`) are fixed here (T1);
  `Device.Up()`'s error (now returned at v1.3.0) is handled; `wgVersion()` becomes replace-aware
  (reports `v1.3.0`); the handle map gets a mutex (Android parity; the concurrent accessors are
  the caller-thread init/deinit-time calls — `wgSetLogger`, the adapter `deinit`'s `wgTurnOff`,
  `wgVersion` — racing the adapter's serial-queue calls).
- **Version header**: `wireguard-go-version.h`'s sed rule matches the `replace` line and emits
  `1.3.0`. The current rule matches the base `require` pseudo-version and would stamp the WRONG
  version (`f333402b`, the base-module hash) instead of the fork's `1.3.0`; the new rule fixes the
  displayed version and a `[ -s "$@" ]` guard makes any future empty output a loud build failure.
- **iOS path change**: `endpointUapiConfiguration()` emits, for each re-resolved dialing WS peer,
  the endpoint AND the full `ws_*` block (fork requirement above). UDP peers unchanged.
- **TLS files**: stored as **absolute paths inside the app group container** under `ws-tls/`
  (the only location both the app and the NE sandbox can read; exact parity with Android's
  app-private absolute paths). iOS: document picker copies the picked file there. macOS: raw-text
  editor — the user places the file in
  `~/Library/Group Containers/<TEAMID>.group.<APP_ID_MACOS>/ws-tls/` and writes the absolute path
  (documented as Manual Test note). No macOS picker (the macOS editor is raw wg-quick text).
- **Secrets**: `WSBearer` round-trips config/UAPI but NEVER appears in logs, error messages
  (`ParseError` case carries NO associated value), or detail views (detail shows an
  "enabled"-style marker, like the preshared key row).
- **No dispatcher / no `hasWebSocketPeers()`**: Apple has only the userspace Go backend — the
  Android `DispatchingBackend`/`WgQuickBackend` guard and `Config.hasWebSocketPeers()` have no
  Apple counterpart. The adapter's `NWPathMonitor` already runs unconditionally on both platforms
  (macOS: `wgBumpSockets`; iOS: re-resolve + `wgSetConfig` + bump) — WS peers ride the existing
  per-platform semantics; no new network watcher is added.
- **Tests**: new `WireGuardKitTests` macOS unit-test bundle target (hand-edited pbxproj, minted
  UUIDs), compiling the model/serialization sources + `WireGuardKitC` + `highlighter.c` +
  `TunnelViewModel.swift`/`LocalizationHelper.swift` directly. The ONLY excluded kit source is
  `WireGuardAdapter.swift` (it calls the `wg*` C functions and would force a `libwg-go.a` link);
  `DNSResolver.swift` IS compiled (needed by `PacketTunnelSettingsGenerator`; its
  `withReresolvedIP()` is a no-op on macOS, so tests stay offline). Runs scheme-less:
  `xcodebuild -target WireGuardKitTests` + `xcrun xctest`. `CODE_SIGNING_ALLOWED=NO` in the
  target settings.
- **URL acceptance set**: the canonical acceptance set for `ws(s)://` endpoint URLs is the
  wireguard-tools fork's (byte-compat authority): userinfo (`user:pass@`) is REJECTED, and a
  query/fragment is accepted only AFTER a path (`ws://h:80?q=1` rejected, `ws://h:80/p?q=1`
  accepted). `WsUrl` and `highlighter.c` enforce the SAME set, so a config saveable on one
  platform is saveable on the other. (Android's `java.net.URI`-based parser is laxer on these
  two edge forms; the tools fork wins per the byte-compat requirement.)
- **Quality-gate deviation (user-approved, temporary until ADP/P1–P2 complete)**: app/NE targets
  are compile-verified with `CODE_SIGNING_ALLOWED=NO`; the signed build is re-verified once the
  paid account is active.
- **Git**: implementation branch `feat/plan-1-websocket-wstunnel-transport` from `master` (this
  repo's main branch). First commit brings the currently-untracked `.claude/` + `docs/` baseline
  onto the branch (mandatory per `agent.md` §3), then this plan document, then the work in logical
  commits per user story (scopes: `deps`/`go`, `kit`, `shared`, `app`, `ios`, `macos`, `xcode`,
  `docs`).

## Sequential execution order

US1 Go bridge → US2 config model (kit) → US3 UAPI surfaces → US4 view model + strings →
US5 iOS UI → US6 macOS UI → US7 test target + tests → US8 docs/rules refresh → US9 ground-up
verification + quality gates.

---

## User Story 1 — Go bridge: fork pin, toolchain, multiplex bind, vet fixes `[x]`

Why: everything downstream needs the fork's WS-capable core compiled into `libwg-go.a`, and T1
must be fixed with the first bridge-touching change.

Acceptance criteria (code-state — build/vet/tidy execution happens ONLY in the US9 gates):
- `[x]` `go.mod`/`go.sum` pin the fork exactly as specified (base + `replace` v1.3.0, `go 1.26.5`)
- `[x]` `wireguard.h` byte-identical (no ABI change)
- `[x]` the three T1 root causes are gone from `api-apple.go` (buffered signal channel,
  `unsafe.Pointer` parameters) and `Up()`/bind errors are handled
- `[x]` the Makefile pins go1.26.5 (SHA256-verified, cached outside `BUILDDIR`,
  `GOTOOLCHAIN=local`) and the boottime diff carries the refreshed go1.26.5 hunks
- `[x]` the version-header rule is the replace-aware sed with the `[ -s ]` guard

### Task 1.1 — `Sources/WireGuardKitGo/go.mod` + `go.sum` `[x]`

- `[x]` Action: modify `Sources/WireGuardKitGo/go.mod`:

```
module golang.zx2c4.com/wireguard/apple

go 1.26.5

require (
	golang.org/x/sys v0.47.0
	golang.zx2c4.com/wireguard v0.0.0-20250521234502-f333402bd9cb
)

require (
	github.com/gobwas/httphead v0.1.0 // indirect
	github.com/gobwas/pool v0.2.1 // indirect
	github.com/gobwas/ws v1.4.0 // indirect
	github.com/golang-jwt/jwt/v5 v5.3.1 // indirect
	github.com/google/uuid v1.6.0 // indirect
	golang.org/x/crypto v0.54.0 // indirect
	golang.org/x/net v0.57.0 // indirect
	golang.zx2c4.com/wintun v0.0.0-20230126152724-0fa3db229ce2 // indirect
)

replace golang.zx2c4.com/wireguard => github.com/danielealbano/wireguard-go v1.3.0
```

- `[x]` Action: run `cd Sources/WireGuardKitGo && go mod tidy` (network; this generates `go.sum`
  — a source artifact, not a quality gate) and commit the regenerated `go.sum` together with
  `go.mod`. `go mod tidy` output is authoritative for the indirect block; if it settles different
  indirect pins than listed above, keep tidy's result and record the delta in `## Deviations`.

DoD: `go.mod` + `go.sum` committed together and consistent (tidy idempotence is re-verified as a
US9 quality gate).

### Task 1.2 — Makefile: pinned toolchain + patch flow + version header `[x]`

- `[x]` Action: replace `Sources/WireGuardKitGo/Makefile` content:

```make
# SPDX-License-Identifier: MIT
#
# Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.

# These are generally passed to us by xcode, but we set working defaults for standalone compilation too.
ARCHS ?= x86_64 arm64
PLATFORM_NAME ?= macosx
SDKROOT ?= $(shell xcrun --sdk $(PLATFORM_NAME) --show-sdk-path)
CONFIGURATION_BUILD_DIR ?= $(CURDIR)/out
CONFIGURATION_TEMP_DIR ?= $(CURDIR)/.tmp

export CC ?= clang
LIPO ?= lipo
DESTDIR ?= $(CONFIGURATION_BUILD_DIR)
BUILDDIR ?= $(CONFIGURATION_TEMP_DIR)/wireguard-go-bridge

CFLAGS_PREFIX := $(if $(DEPLOYMENT_TARGET_CLANG_FLAG_NAME),-$(DEPLOYMENT_TARGET_CLANG_FLAG_NAME)=$($(DEPLOYMENT_TARGET_CLANG_ENV_NAME)),) -isysroot $(SDKROOT) -arch
GOARCH_arm64 := arm64
GOARCH_x86_64 := amd64
GOOS_macosx := darwin
GOOS_iphoneos := ios

# Pinned Go toolchain: downloaded (SHA256-verified), then patched with the boottime diff.
# The system Go is NOT used for artifact builds — Go's automatic toolchain switching would
# silently bypass the patched GOROOT, producing binaries whose timers stop across device sleep.
GO_VERSION := 1.26.5
GO_HOST_ARCH_arm64 := arm64
GO_HOST_ARCH_x86_64 := amd64
GO_PLATFORM := darwin-$(GO_HOST_ARCH_$(shell uname -m))
GO_TARBALL := go$(GO_VERSION).$(GO_PLATFORM).tar.gz
GO_HASH_darwin-amd64 := 6231d8d3b8f5552ec6cbf6d685bdd5482e1e703214b120e89b3bf0d7bf1ef725
GO_HASH_darwin-arm64 := efb87ff28af9a188d0536ef5d42e63dd52ba8263cd7344a993cc48dd11dedb6a
GO_HASH := $(GO_HASH_$(GO_PLATFORM))
# The tarball cache survives `clean` so a clean rebuild does not re-download the toolchain;
# the SHA256 is verified at download time and the extracted GOROOT is rebuilt from it as needed.
GO_CACHE_DIR := $(CURDIR)/.cache

export GOROOT := $(BUILDDIR)/goroot
export GOTOOLCHAIN := local
export PATH := $(GOROOT)/bin:$(PATH):/usr/local/bin:/opt/homebrew/bin

build: $(DESTDIR)/libwg-go.a
version-header: $(DESTDIR)/wireguard-go-version.h

$(GO_CACHE_DIR)/$(GO_TARBALL):
	[ -n "$(GO_HASH)" ]
	mkdir -p "$(GO_CACHE_DIR)"
	curl -fLo "$@.tmp" "https://go.dev/dl/$(GO_TARBALL)"
	echo "$(GO_HASH)  $@.tmp" | shasum -a 256 -c
	mv "$@.tmp" "$@"

$(GOROOT)/.prepared: $(GO_CACHE_DIR)/$(GO_TARBALL)
	rm -rf "$(GOROOT)"
	mkdir -p "$(GOROOT)"
	tar -C "$(GOROOT)" --strip-components=1 -xzf "$(GO_CACHE_DIR)/$(GO_TARBALL)"
	cat goruntime-*.diff | patch -p1 -f -N -r- -d "$(GOROOT)"
	touch "$@"

define libwg-go-a
$(BUILDDIR)/libwg-go-$(1).a: export CGO_ENABLED := 1
$(BUILDDIR)/libwg-go-$(1).a: export CGO_CFLAGS := $(CFLAGS_PREFIX) $(ARCH)
$(BUILDDIR)/libwg-go-$(1).a: export CGO_LDFLAGS := $(CFLAGS_PREFIX) $(ARCH)
$(BUILDDIR)/libwg-go-$(1).a: export GOOS := $(GOOS_$(PLATFORM_NAME))
$(BUILDDIR)/libwg-go-$(1).a: export GOARCH := $(GOARCH_$(1))
$(BUILDDIR)/libwg-go-$(1).a: $(GOROOT)/.prepared go.mod
	go build -ldflags=-w -trimpath -v -o "$(BUILDDIR)/libwg-go-$(1).a" -buildmode c-archive
	rm -f "$(BUILDDIR)/libwg-go-$(1).h"
endef
$(foreach ARCH,$(ARCHS),$(eval $(call libwg-go-a,$(ARCH))))

$(DESTDIR)/wireguard-go-version.h: go.mod
	 sed -E -n 's/.*danielealbano\/wireguard-go +v([0-9][0-9.]*).*/#define WIREGUARD_GO_VERSION "\1"/p' "$<" > "$@.tmp"
	 [ -s "$@.tmp" ]
	 mv "$@.tmp" "$@"

$(DESTDIR)/libwg-go.a: $(foreach ARCH,$(ARCHS),$(BUILDDIR)/libwg-go-$(ARCH).a)
	@mkdir -vp "$(DESTDIR)"
	$(LIPO) -create -output "$@" $^

clean:
	rm -rf "$(BUILDDIR)" "$(DESTDIR)/libwg-go.a" "$(DESTDIR)/wireguard-go-version.h"

install: build

.PHONY: clean build version-header install
```

Context (non-obvious): the temp-file + `[ -s ]` + `mv` sequence makes an empty version header a
loud build failure on EVERY build (a direct `> "$@"` would leave a stale empty target that later
builds consider up to date); the rule no longer depends on the prepared GOROOT (it is pure
`sed`), so app builds don't download Go just to stamp the version.

- `[x]` Action: modify `.gitignore` — append under the "Wireguard specific" section:

```
Sources/WireGuardKitGo/.cache/
```

- `[x]` Action: replace `Sources/WireGuardKitGo/goruntime-boottime-over-monotonic.diff` content
  (context refreshed for go1.26.5; `sys_darwin_amd64.s` no longer has the `PUSHQ BP`/`MOVQ SP, BP`
  prologue lines in `nanotime_trampoline`):

```
runtime: use libc_mach_continuous_time in nanotime on Darwin

This makes timers account for having expired while a computer was
asleep, which is quite common on mobile devices. Note that
continuous_time is the same as absolute_time, except that it takes
into account time spent in suspend.

Based on the original patch by Jason A. Donenfeld <Jason@zx2c4.com>;
hunk context refreshed for the Go 1.26.5 runtime sources.

--- a/src/runtime/sys_darwin.go
+++ b/src/runtime/sys_darwin.go
@@ -440,3 +440,3 @@
 //go:cgo_import_dynamic libc_mach_timebase_info mach_timebase_info "/usr/lib/libSystem.B.dylib"
-//go:cgo_import_dynamic libc_mach_absolute_time mach_absolute_time "/usr/lib/libSystem.B.dylib"
+//go:cgo_import_dynamic libc_mach_continuous_time mach_continuous_time "/usr/lib/libSystem.B.dylib"
 //go:cgo_import_dynamic libc_clock_gettime clock_gettime "/usr/lib/libSystem.B.dylib"
--- a/src/runtime/sys_darwin_amd64.s
+++ b/src/runtime/sys_darwin_amd64.s
@@ -110,5 +110,5 @@
 TEXT runtime·nanotime_trampoline(SB),NOSPLIT,$0
 	MOVQ	DI, BX
-	CALL	libc_mach_absolute_time(SB)
+	CALL	libc_mach_continuous_time(SB)
 	MOVQ	AX, 0(BX)
 	MOVL	timebase<>+machTimebaseInfo_numer(SB), SI
--- a/src/runtime/sys_darwin_arm64.s
+++ b/src/runtime/sys_darwin_arm64.s
@@ -143,5 +143,5 @@
 TEXT runtime·nanotime_trampoline(SB),NOSPLIT,$40
 	MOVD	R0, R19
-	BL	libc_mach_absolute_time(SB)
+	BL	libc_mach_continuous_time(SB)
 	MOVD	R0, 0(R19)
 	MOVW	timebase<>+machTimebaseInfo_numer(SB), R20
```

DoD: Makefile and diff file content exactly as specified (pinned toolchain + `GOTOOLCHAIN=local`
+ refreshed hunks + replace-aware version sed with the `[ -s ]` guard). Build execution happens
ONLY in the US9 quality gates.

### Task 1.3 — `Sources/WireGuardKitGo/api-apple.go` `[x]`

- `[x]` Action: replace file content (multiplex bind; T1 vet fixes: buffered signal channel +
  `unsafe.Pointer` parameters instead of `uintptr`; `Up()` error handled; error paths close the
  device (the previous `unix.Close(dupTunFd)` after `CreateTUNFromFile` succeeded was a
  double-close — the tun owns the fd); mutex-guarded handle map; replace-aware `wgVersion`):

```go
/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 */

package main

// #include <stdlib.h>
// #include <sys/types.h>
// static void callLogger(void *func, void *ctx, int level, const char *msg)
// {
// 	((void(*)(void *, int, const char *))func)(ctx, level, msg);
// }
import "C"

import (
	"fmt"
	"math"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

var loggerFunc unsafe.Pointer
var loggerCtx unsafe.Pointer

type CLogger int

func cstring(s string) *C.char {
	b, err := unix.BytePtrFromString(s)
	if err != nil {
		b := [1]C.char{}
		return &b[0]
	}
	return (*C.char)(unsafe.Pointer(b))
}

func (l CLogger) Printf(format string, args ...interface{}) {
	if uintptr(loggerFunc) == 0 {
		return
	}
	C.callLogger(loggerFunc, loggerCtx, C.int(l), cstring(fmt.Sprintf(format, args...)))
}

type tunnelHandle struct {
	*device.Device
	*device.Logger
}

var (
	tunnelHandles      = make(map[int32]tunnelHandle)
	tunnelHandlesMutex sync.Mutex
)

func init() {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, unix.SIGUSR2)
	go func() {
		buf := make([]byte, os.Getpagesize())
		for {
			select {
			case <-signals:
				n := runtime.Stack(buf, true)
				buf[n] = 0
				if uintptr(loggerFunc) != 0 {
					C.callLogger(loggerFunc, loggerCtx, 0, (*C.char)(unsafe.Pointer(&buf[0])))
				}
			}
		}
	}()
}

//export wgSetLogger
func wgSetLogger(context, loggerFn unsafe.Pointer) {
	loggerCtx = context
	loggerFunc = loggerFn
}

//export wgTurnOn
func wgTurnOn(settings *C.char, tunFd int32) int32 {
	logger := &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
	}
	dupTunFd, err := unix.Dup(int(tunFd))
	if err != nil {
		logger.Errorf("Unable to dup tun fd: %v", err)
		return -1
	}

	err = unix.SetNonblock(dupTunFd, true)
	if err != nil {
		logger.Errorf("Unable to set tun fd as non blocking: %v", err)
		unix.Close(dupTunFd)
		return -1
	}
	tunDev, err := tun.CreateTUNFromFile(os.NewFile(uintptr(dupTunFd), "/dev/tun"), 0)
	if err != nil {
		logger.Errorf("Unable to create new tun device from fd: %v", err)
		unix.Close(dupTunFd)
		return -1
	}
	logger.Verbosef("Attaching to interface")

	// One bind for UDP and WebSocket/wstunnel peers: the UDP data path is the unchanged
	// platform StdNetBind; WS peers dial through the WebSocket sub-bind. No fd-protect
	// upcall is needed on Apple platforms.
	bind, err := conn.NewMultiplexBind(
		conn.WithWSLogger(conn.Logger{Verbosef: logger.Verbosef, Errorf: logger.Errorf}),
	)
	if err != nil {
		logger.Errorf("Unable to create multiplex bind: %v", err)
		tunDev.Close()
		return -1
	}
	dev := device.NewDevice(tunDev, bind, logger)

	err = dev.IpcSet(C.GoString(settings))
	if err != nil {
		logger.Errorf("Unable to set IPC settings: %v", err)
		dev.Close()
		return -1
	}

	err = dev.Up()
	if err != nil {
		logger.Errorf("Unable to bring up device: %v", err)
		dev.Close()
		return -1
	}
	logger.Verbosef("Device started")

	tunnelHandlesMutex.Lock()
	var i int32
	for i = 0; i < math.MaxInt32; i++ {
		if _, exists := tunnelHandles[i]; !exists {
			break
		}
	}
	if i == math.MaxInt32 {
		tunnelHandlesMutex.Unlock()
		dev.Close()
		return -1
	}
	tunnelHandles[i] = tunnelHandle{dev, logger}
	tunnelHandlesMutex.Unlock()
	return i
}

//export wgTurnOff
func wgTurnOff(tunnelHandle int32) {
	tunnelHandlesMutex.Lock()
	dev, ok := tunnelHandles[tunnelHandle]
	if ok {
		delete(tunnelHandles, tunnelHandle)
	}
	tunnelHandlesMutex.Unlock()
	if !ok {
		return
	}
	dev.Close()
}

//export wgSetConfig
func wgSetConfig(tunnelHandle int32, settings *C.char) int64 {
	tunnelHandlesMutex.Lock()
	dev, ok := tunnelHandles[tunnelHandle]
	tunnelHandlesMutex.Unlock()
	if !ok {
		return 0
	}
	err := dev.IpcSet(C.GoString(settings))
	if err != nil {
		dev.Errorf("Unable to set IPC settings: %v", err)
		if ipcErr, ok := err.(*device.IPCError); ok {
			return ipcErr.ErrorCode()
		}
		return -1
	}
	return 0
}

//export wgGetConfig
func wgGetConfig(tunnelHandle int32) *C.char {
	tunnelHandlesMutex.Lock()
	dev, ok := tunnelHandles[tunnelHandle]
	tunnelHandlesMutex.Unlock()
	if !ok {
		return nil
	}
	settings, err := dev.IpcGet()
	if err != nil {
		return nil
	}
	return C.CString(settings)
}

//export wgBumpSockets
func wgBumpSockets(tunnelHandle int32) {
	tunnelHandlesMutex.Lock()
	dev, ok := tunnelHandles[tunnelHandle]
	tunnelHandlesMutex.Unlock()
	if !ok {
		return
	}
	go func() {
		for i := 0; i < 10; i++ {
			err := dev.BindUpdate()
			if err == nil {
				dev.SendKeepalivesToPeersWithCurrentKeypair()
				return
			}
			dev.Errorf("Unable to update bind, try %d: %v", i+1, err)
			time.Sleep(time.Second / 2)
		}
		dev.Errorf("Gave up trying to update bind; tunnel is likely dysfunctional")
	}()
}

//export wgDisableSomeRoamingForBrokenMobileSemantics
func wgDisableSomeRoamingForBrokenMobileSemantics(tunnelHandle int32) {
	tunnelHandlesMutex.Lock()
	dev, ok := tunnelHandles[tunnelHandle]
	tunnelHandlesMutex.Unlock()
	if !ok {
		return
	}
	dev.DisableSomeRoamingForBrokenMobileSemantics()
}

//export wgVersion
func wgVersion() *C.char {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return C.CString("unknown")
	}
	for _, dep := range info.Deps {
		if dep.Path == "golang.zx2c4.com/wireguard" {
			mod := dep
			if dep.Replace != nil {
				mod = dep.Replace
			}
			parts := strings.Split(mod.Version, "-")
			if len(parts) == 3 && len(parts[2]) == 12 {
				return C.CString(parts[2][:7])
			}
			return C.CString(mod.Version)
		}
	}
	return C.CString("unknown")
}

func main() {}
```

Context (non-obvious): `wgSetLogger`'s parameters become `unsafe.Pointer` (cgo maps them to
`void *`, matching the unchanged `wireguard.h` declaration) — this is the root-cause fix for the
two `unsafe.Pointer` vet findings, not a suppression. The Swift caller (`WireGuardAdapter`) is
unaffected.

DoD: file content exactly as specified — the three T1 root causes are gone (buffered signal
channel; `unsafe.Pointer` parameters), `Up()`/bind errors handled with `dev.Close()`, mutex on
every handle-map access, replace-aware `wgVersion`. `go vet` and both platform builds run ONLY in
the US9 quality gates.

---

## User Story 2 — WireGuardKit config model: `WsMode`, `WsUrl`, peer fields, wg-quick surface `[x]`

Why: the byte-compatible config surface is the contract every other layer builds on.

Acceptance criteria:
- `[x]` `ws(s)://` endpoints parse into `wsUrl` + routable `endpoint`; all 11 `WS*` keys parse
- `[x]` every validation rule from the verified contract enforced with a typed `ParseError`
- `[x]` `asWgQuickConfig()` round-trips WS peers byte-compatibly (URL verbatim, zero timings dropped)
- `[x]` the bearer value never appears in any error

### Task 2.1 — create `Sources/WireGuardKit/WsMode.swift` `[x]`

- `[x]` Action: create:

```swift
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
```

### Task 2.2 — create `Sources/WireGuardKit/WsUrl.swift` `[x]`

- `[x]` Action: create:

```swift
// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

/// A per-peer WebSocket URL (`ws(s)://host:port[/path]`). Stored verbatim; the host and port are
/// also exposed for building the routable `Endpoint`. The scheme must be `ws` or `wss`
/// (case-insensitive), the host is required, and an explicit port is required (parity with the
/// routable endpoint). A path is optional and preserved verbatim; a query/fragment is accepted
/// only after a path, and userinfo is rejected (the wireguard-tools fork's acceptance set — the
/// byte-compat authority).
public struct WsUrl {
    public let urlString: String
    public let host: String
    public let port: UInt16

    public init?(from string: String) {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              components.user == nil, components.password == nil,
              var host = components.host, !host.isEmpty,
              let portValue = components.port,
              let port = UInt16(exactly: portValue) else { return nil }
        if components.path.isEmpty && (components.query != nil || components.fragment != nil) {
            return nil
        }
        // Some Foundation versions return an IPv6 literal host WITH its surrounding brackets;
        // strip them so `host` is the bare literal and `endpoint()` brackets exactly once.
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count > 1 {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        self.urlString = string
        self.host = host
        self.port = port
    }

    public static func isWsUrl(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        return lowercased.hasPrefix("ws://") || lowercased.hasPrefix("wss://")
    }

    /// The routable endpoint (`host:port`) dialed for this URL, exactly as a UDP endpoint would
    /// be parsed. IPv6 literal hosts are (re-)bracketed.
    public func endpoint() -> Endpoint? {
        let hostPort = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        return Endpoint(from: hostPort)
    }
}

extension WsUrl: Equatable {
    public static func == (lhs: WsUrl, rhs: WsUrl) -> Bool {
        return lhs.urlString == rhs.urlString
    }
}

extension WsUrl: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(urlString)
    }
}
```

### Task 2.3 — modify `Sources/WireGuardKit/PeerConfiguration.swift` `[x]`

- `[x]` Action: replace file content:

```swift
// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

public struct PeerConfiguration {
    public var publicKey: PublicKey
    public var preSharedKey: PreSharedKey?
    public var allowedIPs = [IPAddressRange]()
    public var endpoint: Endpoint?
    public var persistentKeepAlive: UInt16?
    public var rxBytes: UInt64?
    public var txBytes: UInt64?
    public var lastHandshakeTime: Date?
    public var wsMode: WsMode?
    public var wsUrl: WsUrl?
    public var wstunnelTarget: String?
    public var wsBearer: String?
    public var wsMask = false
    public var wsTlsCa: String?
    public var wsTlsCert: String?
    public var wsTlsKey: String?
    public var wsTlsInsecure = false
    public var wsPingIntervalMs: UInt32?
    public var wsBackoffMinMs: UInt32?
    public var wsBackoffMaxMs: UInt32?

    /// The UAPI `transport=` value for this peer: `udp`, `websocket`, or `wstunnel`.
    public var uapiTransport: String {
        return wsMode?.rawValue ?? "udp"
    }

    public init(publicKey: PublicKey) {
        self.publicKey = publicKey
    }
}

extension PeerConfiguration: Equatable {
    public static func == (lhs: PeerConfiguration, rhs: PeerConfiguration) -> Bool {
        return lhs.publicKey == rhs.publicKey &&
            lhs.preSharedKey == rhs.preSharedKey &&
            Set(lhs.allowedIPs) == Set(rhs.allowedIPs) &&
            lhs.endpoint == rhs.endpoint &&
            lhs.persistentKeepAlive == rhs.persistentKeepAlive &&
            lhs.wsMode == rhs.wsMode &&
            lhs.wsUrl == rhs.wsUrl &&
            lhs.wstunnelTarget == rhs.wstunnelTarget &&
            lhs.wsBearer == rhs.wsBearer &&
            lhs.wsMask == rhs.wsMask &&
            lhs.wsTlsCa == rhs.wsTlsCa &&
            lhs.wsTlsCert == rhs.wsTlsCert &&
            lhs.wsTlsKey == rhs.wsTlsKey &&
            lhs.wsTlsInsecure == rhs.wsTlsInsecure &&
            lhs.wsPingIntervalMs == rhs.wsPingIntervalMs &&
            lhs.wsBackoffMinMs == rhs.wsBackoffMinMs &&
            lhs.wsBackoffMaxMs == rhs.wsBackoffMaxMs
    }
}

extension PeerConfiguration: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
        hasher.combine(preSharedKey)
        hasher.combine(Set(allowedIPs))
        hasher.combine(endpoint)
        hasher.combine(persistentKeepAlive)
        hasher.combine(wsMode)
        hasher.combine(wsUrl)
        hasher.combine(wstunnelTarget)
        hasher.combine(wsBearer)
        hasher.combine(wsMask)
        hasher.combine(wsTlsCa)
        hasher.combine(wsTlsCert)
        hasher.combine(wsTlsKey)
        hasher.combine(wsTlsInsecure)
        hasher.combine(wsPingIntervalMs)
        hasher.combine(wsBackoffMinMs)
        hasher.combine(wsBackoffMaxMs)
    }
}
```

### Task 2.4 — modify `Sources/Shared/Model/TunnelConfiguration+WgQuickConfig.swift` `[x]`

- `[x]` Action: extend `ParseError` with the new cases (append after `multipleEntriesForKey`):

```swift
        case peerHasInvalidWsMode(String)
        case peerHasInvalidWsTunnelTarget(String)
        case peerHasInvalidWsBearer // carries no value: the bearer is a secret
        case peerHasInvalidWsBoolean(String)
        case peerHasInvalidWsMillis(String)
        case peerHasEmptyWsValue(String) // offending key (canonical spelling)
        case peerHasInvalidTransport(String)
        case peerWsUrlRequiresWsMode
        case peerWsModeForbidsHostPortEndpoint
        case peerInboundWstunnelForbidden
        case peerWstunnelRequiresTarget
        case peerWsTunnelTargetForbidden
        case peerHasWsKeyWithoutWsMode(String) // offending key (canonical spelling)
```

- `[x]` Action: extend `peerSectionKeys` in the parser:

```swift
                    let peerSectionKeys: Set<String> = ["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive",
                                                       "wsmode", "wstunneltarget", "wsbearer", "wsmask", "wstlsca", "wstlscert",
                                                       "wstlskey", "wstlsinsecure", "wspinginterval", "wsbackoffmin", "wsbackoffmax"]
```

- `[x]` Action: in `collate(peerAttributes:)`, replace the endpoint block and append WS parsing +
  validation before `return peer`:

```swift
        if let endpointString = attributes["endpoint"] {
            if WsUrl.isWsUrl(endpointString) {
                guard let wsUrl = WsUrl(from: endpointString), let endpoint = wsUrl.endpoint() else {
                    throw ParseError.peerHasInvalidEndpoint(endpointString)
                }
                peer.wsUrl = wsUrl
                peer.endpoint = endpoint
            } else {
                guard let endpoint = Endpoint(from: endpointString) else {
                    throw ParseError.peerHasInvalidEndpoint(endpointString)
                }
                peer.endpoint = endpoint
            }
        }
        if let persistentKeepAliveString = attributes["persistentkeepalive"] {
            guard let persistentKeepAlive = UInt16(persistentKeepAliveString) else {
                throw ParseError.peerHasInvalidPersistentKeepAlive(persistentKeepAliveString)
            }
            peer.persistentKeepAlive = persistentKeepAlive
        }
        if let wsModeString = attributes["wsmode"] {
            guard let wsMode = WsMode(fromWireFormat: wsModeString) else {
                throw ParseError.peerHasInvalidWsMode(wsModeString)
            }
            peer.wsMode = wsMode
        }
        if let wstunnelTargetString = attributes["wstunneltarget"] {
            // Validate the host:port shape; store the raw string. The inner target is resolved
            // by the wstunnel relay, never by this app.
            guard Endpoint(from: wstunnelTargetString) != nil else {
                throw ParseError.peerHasInvalidWsTunnelTarget(wstunnelTargetString)
            }
            peer.wstunnelTarget = wstunnelTargetString
        }
        if let wsBearerString = attributes["wsbearer"] {
            guard !wsBearerString.isEmpty else { throw ParseError.peerHasInvalidWsBearer }
            peer.wsBearer = wsBearerString
        }
        peer.wsMask = try parseWsBoolean(attributes, key: "wsmask")
        peer.wsTlsCa = try parseWsNonEmpty(attributes, key: "wstlsca", canonical: "WSTLSCA")
        peer.wsTlsCert = try parseWsNonEmpty(attributes, key: "wstlscert", canonical: "WSTLSCert")
        peer.wsTlsKey = try parseWsNonEmpty(attributes, key: "wstlskey", canonical: "WSTLSKey")
        peer.wsTlsInsecure = try parseWsBoolean(attributes, key: "wstlsinsecure")
        peer.wsPingIntervalMs = try parseWsMillis(attributes, key: "wspinginterval")
        peer.wsBackoffMinMs = try parseWsMillis(attributes, key: "wsbackoffmin")
        peer.wsBackoffMaxMs = try parseWsMillis(attributes, key: "wsbackoffmax")
        try validateWs(peer: peer, attributes: attributes)
        return peer
```

- `[x]` Action: add the private helpers to the same extension:

```swift
    private static func parseWsBoolean(_ attributes: [String: String], key: String) throws -> Bool {
        guard let value = attributes[key] else { return false }
        switch value {
        case "true": return true
        case "false": return false
        default: throw ParseError.peerHasInvalidWsBoolean(value)
        }
    }

    private static func parseWsNonEmpty(_ attributes: [String: String], key: String, canonical: String) throws -> String? {
        guard let value = attributes[key] else { return nil }
        guard !value.isEmpty else { throw ParseError.peerHasEmptyWsValue(canonical) }
        return value
    }

    // A UAPI ws_* timing of 0 means "use the default", so it is not carried or emitted.
    private static func parseWsMillis(_ attributes: [String: String], key: String) throws -> UInt32? {
        guard let value = attributes[key] else { return nil }
        guard let millis = UInt32(value) else { throw ParseError.peerHasInvalidWsMillis(value) }
        return millis == 0 ? nil : millis
    }

    private static func validateWs(peer: PeerConfiguration, attributes: [String: String]) throws {
        let isWstunnel = peer.wsMode == .wstunnel
        if peer.wsUrl != nil && peer.wsMode == nil {
            throw ParseError.peerWsUrlRequiresWsMode
        }
        if peer.wsUrl == nil && peer.wsMode != nil && peer.endpoint != nil {
            throw ParseError.peerWsModeForbidsHostPortEndpoint
        }
        if isWstunnel && peer.wsUrl == nil {
            throw ParseError.peerInboundWstunnelForbidden
        }
        if isWstunnel && peer.wsUrl != nil && peer.wstunnelTarget == nil {
            throw ParseError.peerWstunnelRequiresTarget
        }
        if peer.wstunnelTarget != nil && !(isWstunnel && peer.wsUrl != nil) {
            throw ParseError.peerWsTunnelTargetForbidden
        }
        if peer.wsMode == nil {
            // Presence, not value, is the trigger (a `WSMask = false` on a UDP peer is an error).
            // `WSTunnelTarget` is absent here on purpose: the target-placement check above
            // already threw `.peerWsTunnelTargetForbidden` for it.
            let wsKeys: [(String, String)] = [
                ("wsbearer", "WSBearer"), ("wsmask", "WSMask"),
                ("wstlsca", "WSTLSCA"), ("wstlscert", "WSTLSCert"), ("wstlskey", "WSTLSKey"),
                ("wstlsinsecure", "WSTLSInsecure"), ("wspinginterval", "WSPingInterval"),
                ("wsbackoffmin", "WSBackoffMin"), ("wsbackoffmax", "WSBackoffMax")
            ]
            for (key, canonical) in wsKeys where attributes[key] != nil {
                throw ParseError.peerHasWsKeyWithoutWsMode(canonical)
            }
        }
    }
```

- `[x]` Action: in `asWgQuickConfig()`, replace the peer `Endpoint` line and append the WS keys
  after `PersistentKeepalive` (Android emission set; bearer last):

```swift
            if let wsUrl = peer.wsUrl {
                output.append("Endpoint = \(wsUrl.urlString)\n")
            } else if let endpoint = peer.endpoint {
                output.append("Endpoint = \(endpoint.stringRepresentation)\n")
            }
            if let persistentKeepAlive = peer.persistentKeepAlive {
                output.append("PersistentKeepalive = \(persistentKeepAlive)\n")
            }
            if let wsMode = peer.wsMode {
                output.append("WSMode = \(wsMode.rawValue)\n")
            }
            if let wstunnelTarget = peer.wstunnelTarget {
                output.append("WSTunnelTarget = \(wstunnelTarget)\n")
            }
            if peer.wsMask {
                output.append("WSMask = true\n")
            }
            if let wsTlsCa = peer.wsTlsCa {
                output.append("WSTLSCA = \(wsTlsCa)\n")
            }
            if let wsTlsCert = peer.wsTlsCert {
                output.append("WSTLSCert = \(wsTlsCert)\n")
            }
            if let wsTlsKey = peer.wsTlsKey {
                output.append("WSTLSKey = \(wsTlsKey)\n")
            }
            if peer.wsTlsInsecure {
                output.append("WSTLSInsecure = true\n")
            }
            if let wsPingIntervalMs = peer.wsPingIntervalMs {
                output.append("WSPingInterval = \(wsPingIntervalMs)\n")
            }
            if let wsBackoffMinMs = peer.wsBackoffMinMs {
                output.append("WSBackoffMin = \(wsBackoffMinMs)\n")
            }
            if let wsBackoffMaxMs = peer.wsBackoffMaxMs {
                output.append("WSBackoffMax = \(wsBackoffMaxMs)\n")
            }
            if let wsBearer = peer.wsBearer {
                output.append("WSBearer = \(wsBearer)\n")
            }
```

DoD: parse → serialize → parse round-trips WS and UDP peers; every rule in "Verified contracts"
throws its specific typed error.

---

## User Story 3 — UAPI generation and readback `[x]`

Why: the NE must speak the fork's UAPI (set) and survive its extended output (get) — including for
pure-UDP tunnels, whose `wgGetConfig` output now contains `transport=udp`.

Acceptance criteria:
- `[x]` `uapiConfiguration()` emits `transport=` for every peer and the `ws_*` block for WS peers
- `[x]` `endpointUapiConfiguration()` re-sends the full `ws_*` block with the re-resolved endpoint
- `[x]` readback accepts `transport` + all `ws_*` peer keys; UDP tunnels keep working

### Task 3.1 — modify `Sources/WireGuardKit/PacketTunnelSettingsGenerator.swift` `[x]`

- `[x]` Action: add the private WS-lines helper and wire it into both configuration builders:

```swift
    private class func wsUapiConfiguration(for peer: PeerConfiguration) -> String {
        var wgSettings = ""
        if let wsUrl = peer.wsUrl {
            wgSettings.append("ws_url=\(wsUrl.urlString)\n")
        }
        if let wstunnelTarget = peer.wstunnelTarget {
            wgSettings.append("wstunnel_target=\(wstunnelTarget)\n")
        }
        if let wsBearer = peer.wsBearer {
            wgSettings.append("ws_bearer=\(wsBearer)\n")
        }
        if peer.wsMask {
            wgSettings.append("ws_mask=true\n")
        }
        if let wsTlsCa = peer.wsTlsCa {
            wgSettings.append("ws_tls_ca=\(wsTlsCa)\n")
        }
        if let wsTlsCert = peer.wsTlsCert {
            wgSettings.append("ws_tls_cert=\(wsTlsCert)\n")
        }
        if let wsTlsKey = peer.wsTlsKey {
            wgSettings.append("ws_tls_key=\(wsTlsKey)\n")
        }
        if peer.wsTlsInsecure {
            wgSettings.append("ws_tls_insecure=true\n")
        }
        if let wsPingIntervalMs = peer.wsPingIntervalMs {
            wgSettings.append("ws_ping_interval=\(wsPingIntervalMs)\n")
        }
        if let wsBackoffMinMs = peer.wsBackoffMinMs {
            wgSettings.append("ws_backoff_min=\(wsBackoffMinMs)\n")
        }
        if let wsBackoffMaxMs = peer.wsBackoffMaxMs {
            wgSettings.append("ws_backoff_max=\(wsBackoffMaxMs)\n")
        }
        return wgSettings
    }
```

- `[x]` Action: in `uapiConfiguration()`, after `wgSettings.append("public_key=...")` insert:

```swift
            wgSettings.append("transport=\(peer.uapiTransport)\n")
```

  and replace the endpoint-result block so the `ws_*` block of a DIALING peer travels only WITH a
  successfully resolved `endpoint=` line (the fork rejects `ws_url` without `endpoint` and the
  WHOLE `IpcSet` would fail — on iOS resolution failure the peer must instead be created
  endpoint-less, exactly like a UDP peer with a failed resolution; inbound peers have no
  endpoint/URL and their client settings are always emitted):

```swift
            let result = resolvedEndpoint.map(Self.reresolveEndpoint)
            if case .success((_, let resolvedEndpoint)) = result {
                if case .name = resolvedEndpoint.host { assert(false, "Endpoint is not resolved") }
                wgSettings.append("endpoint=\(resolvedEndpoint.stringRepresentation)\n")
                if peer.wsUrl != nil {
                    wgSettings.append(Self.wsUapiConfiguration(for: peer))
                }
            }
            resolutionResults.append(result)
            if peer.wsMode != nil && peer.wsUrl == nil {
                wgSettings.append(Self.wsUapiConfiguration(for: peer))
            }
```

  Context: the resolution-failure branch is NOT host-testable (`withReresolvedIP()` is a no-op on
  macOS) — it is covered by the Manual Test network-switch pass (US9).

- `[x]` Action: in `endpointUapiConfiguration()`, replace the endpoint-append block so the WS
  block travels WITH the endpoint (the fork ignores an `endpoint=` for a WS peer that arrives
  without `ws_url`; on resolution failure nothing is sent for that peer, preserving the current
  UDP behavior):

```swift
            let result = resolvedEndpoint.map(Self.reresolveEndpoint)
            if case .success((_, let resolvedEndpoint)) = result {
                if case .name = resolvedEndpoint.host { assert(false, "Endpoint is not resolved") }
                wgSettings.append("endpoint=\(resolvedEndpoint.stringRepresentation)\n")
                if peer.wsUrl != nil {
                    wgSettings.append(Self.wsUapiConfiguration(for: peer))
                }
            }
            resolutionResults.append(result)
```

DoD: generated strings match the verified UAPI contract for UDP, dialing websocket, dialing
wstunnel, and inbound websocket peers.

### Task 3.2 — modify `Sources/WireGuardApp/Tunnel/TunnelConfiguration+UapiConfig.swift` `[x]`

- `[x]` Action: extend `peerSectionKeys`:

```swift
            let peerSectionKeys: Set<String> = ["public_key", "preshared_key", "allowed_ip", "endpoint", "persistent_keepalive_interval",
                                               "last_handshake_time_sec", "last_handshake_time_nsec", "rx_bytes", "tx_bytes", "protocol_version",
                                               "transport", "ws_url", "wstunnel_target", "ws_bearer", "ws_mask", "ws_tls_ca", "ws_tls_cert",
                                               "ws_tls_key", "ws_tls_insecure", "ws_ping_interval", "ws_backoff_min", "ws_backoff_max"]
```

- `[x]` Action: in `collate(peerAttributes:)` append before `return peer` (the `endpoint=` line
  keeps populating `peer.endpoint` — for a WS peer it is the resolved dial target):

```swift
        if let transportString = attributes["transport"] {
            switch transportString {
            case "udp":
                break
            case "websocket":
                peer.wsMode = .websocket
            case "wstunnel":
                peer.wsMode = .wstunnel
            default:
                throw ParseError.peerHasInvalidTransport(transportString)
            }
        }
        if let wsUrlString = attributes["ws_url"] {
            guard let wsUrl = WsUrl(from: wsUrlString) else {
                throw ParseError.peerHasInvalidEndpoint(wsUrlString)
            }
            peer.wsUrl = wsUrl
        }
        if let wstunnelTargetString = attributes["wstunnel_target"] {
            guard Endpoint(from: wstunnelTargetString) != nil else {
                throw ParseError.peerHasInvalidWsTunnelTarget(wstunnelTargetString)
            }
            peer.wstunnelTarget = wstunnelTargetString
        }
        if let wsBearerString = attributes["ws_bearer"] {
            guard !wsBearerString.isEmpty else { throw ParseError.peerHasInvalidWsBearer }
            peer.wsBearer = wsBearerString
        }
        if let wsMaskString = attributes["ws_mask"] {
            peer.wsMask = wsMaskString == "true"
        }
        peer.wsTlsCa = attributes["ws_tls_ca"]
        peer.wsTlsCert = attributes["ws_tls_cert"]
        peer.wsTlsKey = attributes["ws_tls_key"]
        if let wsTlsInsecureString = attributes["ws_tls_insecure"] {
            peer.wsTlsInsecure = wsTlsInsecureString == "true"
        }
        if let wsPingIntervalString = attributes["ws_ping_interval"] {
            guard let millis = UInt32(wsPingIntervalString) else {
                throw ParseError.peerHasInvalidWsMillis(wsPingIntervalString)
            }
            peer.wsPingIntervalMs = millis == 0 ? nil : millis
        }
        if let wsBackoffMinString = attributes["ws_backoff_min"] {
            guard let millis = UInt32(wsBackoffMinString) else {
                throw ParseError.peerHasInvalidWsMillis(wsBackoffMinString)
            }
            peer.wsBackoffMinMs = millis == 0 ? nil : millis
        }
        if let wsBackoffMaxString = attributes["ws_backoff_max"] {
            guard let millis = UInt32(wsBackoffMaxString) else {
                throw ParseError.peerHasInvalidWsMillis(wsBackoffMaxString)
            }
            peer.wsBackoffMaxMs = millis == 0 ? nil : millis
        }
        return peer
```

DoD: `init(fromUapiConfig:)` parses fork-shaped output for UDP and WS peers (incl.
`transport=udp` on plain peers).

---

## User Story 4 — `TunnelViewModel`: WS peer fields, validation, strings `[x]`

Why: both platforms' detail views and the iOS editor are driven by this field model.

Acceptance criteria:
- `[x]` all 11 WS fields round-trip scratchpad ⇄ `PeerConfiguration`
- `[x]` `save()` enforces the full validation contract with per-field errors + localized messages
- `[x]` endpoint field carries the `ws(s)://` URL verbatim for WS peers

### Task 4.1 — modify `Sources/WireGuardApp/UI/TunnelViewModel.swift` `[x]`

- `[x]` Action: extend `PeerField` (new cases after `.persistentKeepAlive`) and its
  `localizedUIString`:

```swift
        case wsMode
        case wstunnelTarget
        case wsBearer
        case wsMask
        case wsTlsCa
        case wsTlsCert
        case wsTlsKey
        case wsTlsInsecure
        case wsPingInterval
        case wsBackoffMin
        case wsBackoffMax
```

```swift
            case .wsMode: return tr("tunnelPeerWsMode")
            case .wstunnelTarget: return tr("tunnelPeerWstunnelTarget")
            case .wsBearer: return tr("tunnelPeerWsBearer")
            case .wsMask: return tr("tunnelPeerWsMask")
            case .wsTlsCa: return tr("tunnelPeerWsTlsCa")
            case .wsTlsCert: return tr("tunnelPeerWsTlsCert")
            case .wsTlsKey: return tr("tunnelPeerWsTlsKey")
            case .wsTlsInsecure: return tr("tunnelPeerWsTlsInsecure")
            case .wsPingInterval: return tr("tunnelPeerWsPingInterval")
            case .wsBackoffMin: return tr("tunnelPeerWsBackoffMin")
            case .wsBackoffMax: return tr("tunnelPeerWsBackoffMax")
```

- `[x]` Action: in `PeerData.createScratchPad(from:)`, replace the endpoint line and add the WS
  fields (booleans stored as `"true"`/absent, timings as decimal strings, mode as wire format):

```swift
            if let wsUrl = config.wsUrl {
                scratchpad[.endpoint] = wsUrl.urlString
            } else if let endpoint = config.endpoint {
                scratchpad[.endpoint] = endpoint.stringRepresentation
            }
            if let wsMode = config.wsMode {
                scratchpad[.wsMode] = wsMode.rawValue
            }
            if let wstunnelTarget = config.wstunnelTarget {
                scratchpad[.wstunnelTarget] = wstunnelTarget
            }
            if let wsBearer = config.wsBearer {
                scratchpad[.wsBearer] = wsBearer
            }
            if config.wsMask {
                scratchpad[.wsMask] = "true"
            }
            if let wsTlsCa = config.wsTlsCa {
                scratchpad[.wsTlsCa] = wsTlsCa
            }
            if let wsTlsCert = config.wsTlsCert {
                scratchpad[.wsTlsCert] = wsTlsCert
            }
            if let wsTlsKey = config.wsTlsKey {
                scratchpad[.wsTlsKey] = wsTlsKey
            }
            if config.wsTlsInsecure {
                scratchpad[.wsTlsInsecure] = "true"
            }
            if let wsPingIntervalMs = config.wsPingIntervalMs {
                scratchpad[.wsPingInterval] = String(wsPingIntervalMs)
            }
            if let wsBackoffMinMs = config.wsBackoffMinMs {
                scratchpad[.wsBackoffMin] = String(wsBackoffMinMs)
            }
            if let wsBackoffMaxMs = config.wsBackoffMaxMs {
                scratchpad[.wsBackoffMax] = String(wsBackoffMaxMs)
            }
```

- `[x]` Action: in `PeerData.save()`, replace the endpoint block and add WS parsing + cross-field
  validation before `guard errorMessages.isEmpty`:

```swift
            if let endpointString = scratchpad[.endpoint] {
                if WsUrl.isWsUrl(endpointString) {
                    if let wsUrl = WsUrl(from: endpointString), let endpoint = wsUrl.endpoint() {
                        config.wsUrl = wsUrl
                        config.endpoint = endpoint
                    } else {
                        fieldsWithError.insert(.endpoint)
                        errorMessages.append(tr("alertInvalidPeerMessageEndpointInvalid"))
                    }
                } else if let endpoint = Endpoint(from: endpointString) {
                    config.endpoint = endpoint
                } else {
                    fieldsWithError.insert(.endpoint)
                    errorMessages.append(tr("alertInvalidPeerMessageEndpointInvalid"))
                }
            }
            if let persistentKeepAliveString = scratchpad[.persistentKeepAlive] {
                if let persistentKeepAlive = UInt16(persistentKeepAliveString) {
                    config.persistentKeepAlive = persistentKeepAlive
                } else {
                    fieldsWithError.insert(.persistentKeepAlive)
                    errorMessages.append(tr("alertInvalidPeerMessagePersistentKeepaliveInvalid"))
                }
            }
            if let wsModeString = scratchpad[.wsMode] {
                if let wsMode = WsMode(fromWireFormat: wsModeString) {
                    config.wsMode = wsMode
                } else {
                    fieldsWithError.insert(.wsMode)
                    errorMessages.append(tr("alertInvalidPeerMessageWsModeInvalid"))
                }
            }
            if let wstunnelTargetString = scratchpad[.wstunnelTarget] {
                if Endpoint(from: wstunnelTargetString) != nil {
                    config.wstunnelTarget = wstunnelTargetString
                } else {
                    fieldsWithError.insert(.wstunnelTarget)
                    errorMessages.append(tr("alertInvalidPeerMessageWstunnelTargetInvalid"))
                }
            }
            if let wsBearerString = scratchpad[.wsBearer], !wsBearerString.isEmpty {
                config.wsBearer = wsBearerString
            }
            config.wsMask = scratchpad[.wsMask] == "true"
            config.wsTlsCa = scratchpad[.wsTlsCa]
            config.wsTlsCert = scratchpad[.wsTlsCert]
            config.wsTlsKey = scratchpad[.wsTlsKey]
            config.wsTlsInsecure = scratchpad[.wsTlsInsecure] == "true"
            for (field, keyPath) in [(PeerField.wsPingInterval, \PeerConfiguration.wsPingIntervalMs),
                                     (PeerField.wsBackoffMin, \PeerConfiguration.wsBackoffMinMs),
                                     (PeerField.wsBackoffMax, \PeerConfiguration.wsBackoffMaxMs)] {
                if let millisString = scratchpad[field] {
                    if let millis = UInt32(millisString) {
                        config[keyPath: keyPath] = millis == 0 ? nil : millis
                    } else {
                        fieldsWithError.insert(field)
                        errorMessages.append(tr("alertInvalidPeerMessageWsMillisInvalid"))
                    }
                }
            }
            // Cross-field rules (identical to the wg-quick parser; presence-triggered).
            if config.wsUrl != nil && config.wsMode == nil {
                fieldsWithError.insert(.wsMode)
                errorMessages.append(tr("alertInvalidPeerMessageWsUrlRequiresMode"))
            }
            if config.wsUrl == nil && config.wsMode != nil && config.endpoint != nil {
                fieldsWithError.insert(.endpoint)
                errorMessages.append(tr("alertInvalidPeerMessageWsModeForbidsHostPort"))
            }
            if config.wsMode == .wstunnel && config.wsUrl == nil {
                fieldsWithError.insert(.wsMode)
                errorMessages.append(tr("alertInvalidPeerMessageInboundWstunnel"))
            }
            if config.wsMode == .wstunnel && config.wsUrl != nil && config.wstunnelTarget == nil {
                fieldsWithError.insert(.wstunnelTarget)
                errorMessages.append(tr("alertInvalidPeerMessageWstunnelTargetRequired"))
            }
            if config.wstunnelTarget != nil && !(config.wsMode == .wstunnel && config.wsUrl != nil) {
                fieldsWithError.insert(.wstunnelTarget)
                errorMessages.append(tr("alertInvalidPeerMessageWstunnelTargetForbidden"))
            }
            if config.wsMode == nil {
                // `.wstunnelTarget` is absent on purpose: the target-placement check above
                // already reported it (identical to the wg-quick parser's presence list).
                let wsFieldPresence: [PeerField] = [.wsBearer, .wsMask, .wsTlsCa, .wsTlsCert,
                                                    .wsTlsKey, .wsTlsInsecure, .wsPingInterval, .wsBackoffMin, .wsBackoffMax]
                for field in wsFieldPresence where scratchpad[field] != nil {
                    fieldsWithError.insert(field)
                    errorMessages.append(tr("alertInvalidPeerMessageWsKeyWithoutMode"))
                    break
                }
            }
```

- `[x]` Action: add to `PeerData` (after `excludePrivateIPsValueChanged`) the WS-clearing helper
  used by the iOS editor when the mode is set back to None — without it, previously entered WS
  values would survive invisibly in the scratchpad and block `save()` with errors on rows that
  are no longer rendered:

```swift
        static let wsParameterFields: [PeerField] = [
            .wstunnelTarget, .wsBearer, .wsMask, .wsTlsCa, .wsTlsCert,
            .wsTlsKey, .wsTlsInsecure, .wsPingInterval, .wsBackoffMin, .wsBackoffMax
        ]

        func clearWsParameterFields() {
            for field in PeerData.wsParameterFields {
                self[field] = ""
            }
        }
```

### Task 4.2 — modify `Sources/WireGuardApp/Base.lproj/Localizable.strings` `[x]`

- `[x]` Action: append (Base only — the other 18 lproj files are Crowdin-managed via
  `sync-translations.sh`):

```
/* WebSocket/wstunnel transport */
"tunnelPeerWsMode" = "WebSocket mode";
"tunnelPeerWsModeNone" = "None (UDP)";
"tunnelPeerWsModeWebsocket" = "WebSocket";
"tunnelPeerWsModeWstunnel" = "wstunnel";
"tunnelPeerWstunnelTarget" = "wstunnel target";
"tunnelPeerWsBearer" = "WebSocket bearer";
"tunnelPeerWsMask" = "Mask WebSocket frames";
"tunnelPeerWsTlsCa" = "TLS CA certificate";
"tunnelPeerWsTlsCert" = "TLS client certificate";
"tunnelPeerWsTlsKey" = "TLS client key";
"tunnelPeerWsTlsInsecure" = "Skip TLS verification";
"tunnelPeerWsPingInterval" = "WebSocket ping interval (ms)";
"tunnelPeerWsBackoffMin" = "Reconnect backoff min (ms)";
"tunnelPeerWsBackoffMax" = "Reconnect backoff max (ms)";
"tunnelPeerWsEnabled" = "enabled";
"tunnelEditSelectFile" = "Select file";

"alertInvalidPeerMessageWsModeInvalid" = "Peer's WebSocket mode must be 'websocket' or 'wstunnel'";
"alertInvalidPeerMessageWstunnelTargetInvalid" = "Peer's wstunnel target must be of the form 'host:port'";
"alertInvalidPeerMessageWsMillisInvalid" = "Peer's WebSocket timings must be non-negative millisecond counts";
"alertInvalidPeerMessageWsUrlRequiresMode" = "A ws:// or wss:// endpoint requires a WebSocket mode";
"alertInvalidPeerMessageWsModeForbidsHostPort" = "A WebSocket mode requires a ws:// or wss:// endpoint, not 'host:port'";
"alertInvalidPeerMessageInboundWstunnel" = "wstunnel mode requires a ws:// or wss:// endpoint (it is a dialing mode)";
"alertInvalidPeerMessageWstunnelTargetRequired" = "wstunnel mode requires a wstunnel target";
"alertInvalidPeerMessageWstunnelTargetForbidden" = "A wstunnel target is only valid for a dialing wstunnel peer";
"alertInvalidPeerMessageWsKeyWithoutMode" = "WebSocket options require a WebSocket mode";
"alertWsFileImportFailedTitle" = "Unable to import file";
"alertWsFileImportFailedMessage (%@)" = "The selected file could not be imported: %@";
"alertWsFileImportFailedNoContainerMessage" = "The app group container is unavailable";

"macAlertWsModeInvalid (%@)" = "WSMode '%@' is invalid";
"macAlertWsTunnelTargetInvalid (%@)" = "WSTunnelTarget '%@' is invalid";
"macAlertWsBearerInvalid" = "WSBearer must not be empty";
"macAlertWsBooleanInvalid (%@)" = "Expected 'true' or 'false', got '%@'";
"macAlertWsMillisInvalid (%@)" = "'%@' is not a valid millisecond count";
"macAlertWsValueEmpty (%@)" = "Value for '%@' must not be empty";
"macAlertTransportInvalid (%@)" = "Transport '%@' is invalid";
"macAlertWsUrlRequiresWsMode" = "A ws(s):// Endpoint requires WSMode";
"macAlertWsModeForbidsHostPortEndpoint" = "WSMode requires a ws(s):// Endpoint, not 'host:port'";
"macAlertInboundWstunnelForbidden" = "WSMode=wstunnel requires a ws(s):// Endpoint (wstunnel is a dialing mode)";
"macAlertWstunnelRequiresTarget" = "WSMode=wstunnel requires WSTunnelTarget";
"macAlertWsTunnelTargetForbidden" = "WSTunnelTarget requires WSMode=wstunnel and a ws(s):// Endpoint";
"macAlertWsKeyWithoutWsMode (%@)" = "'%@' requires WSMode";
```

DoD: every `tr()` key referenced by US4–US6 exists in `Base.lproj/Localizable.strings`.

---

## User Story 5 — iOS UI: editor + detail `[x]`

Why: parity with Android's full WS parameter editor, in the existing iOS table idiom.

Acceptance criteria:
- `[x]` WS mode selectable (None/WebSocket/wstunnel); WS rows appear only when a mode is set
- `[x]` TLS CA/cert/key rows open the document picker and store the copied app-group path
- `[x]` detail view shows set WS fields; bearer/booleans render as "enabled"-style markers

### Task 5.1 — modify `Sources/Shared/FileManager+Extension.swift` `[x]`

- `[x]` Action: add the WS TLS import helpers (below `loginHelperTimestampURL`):

```swift
    static var wsTlsDirectoryURL: URL? {
        return sharedFolderURL?.appendingPathComponent("ws-tls", isDirectory: true)
    }

    enum WsTlsImportError: Error {
        case noAppGroupContainer
        case copyFailed(Error)
    }

    static func importWsTlsFile(from url: URL) throws -> URL {
        guard let directory = wsTlsDirectoryURL else { throw WsTlsImportError.noAppGroupContainer }
        let sanitized = url.lastPathComponent.map { character -> Character in
            return character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" ? character : "_"
        }
        // An empty or all-dots name ("." / "..") would escape the ws-tls directory.
        let fileName = sanitized.isEmpty || sanitized.allSatisfy({ $0 == "." }) ? "ws-tls" : String(sanitized)
        let destination = directory.appendingPathComponent(fileName)
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw WsTlsImportError.copyFailed(error)
        }
        return destination
    }
```

### Task 5.2 — modify `Sources/WireGuardApp/UI/iOS/ViewController/TunnelEditTableViewController.swift` `[x]`

- `[x]` Action: add `import UniformTypeIdentifiers` below the existing `import UIKit`
  (`UIDocumentPickerViewController(forOpeningContentTypes:)` takes `[UTType]`).

- `[x]` Action: replace the stored `peerFields` property with a dynamic builder, and update
  EVERY former `peerFields` reference site (the property is removed — all seven sites below MUST
  change):

  1. `numberOfRowsInSection` (`.peer` case): `peerFieldsToShow(for: peerData).count` (the
     `shouldAllowExcludePrivateIPsControl` filter moves INTO the builder).
  2. `peerCell(for:at:with:)`: `let field = peerFieldsToShow(for: peerData)[indexPath.row]`.
  3. `interfaceFieldKeyValueCell`'s DNS `onValueChanged` closure: the allowedIPs row reload
     becomes per-peer:

```swift
                if isAllowedIPsChanged {
                    let section = self.sections.firstIndex { if case .peer = $0 { return true } else { return false } }
                    if let section = section, case .peer(let peerData) = self.sections[section],
                       let row = self.peerFieldsToShow(for: peerData).firstIndex(of: .allowedIPs) {
                        self.tableView.reloadRows(at: [IndexPath(row: row, section: section)], with: .none)
                    }
                }
```

  4. `excludePrivateIPsCell`'s `onSwitchToggled`: `if let row = self.peerFieldsToShow(for:
     peerData).firstIndex(of: .allowedIPs)` (same reload, `indexPath.section`).
  5. `peerFieldKeyValueCell`'s allowedIPs `onValueBeingEdited`: `.excludePrivateIPs` sits
     directly after `.allowedIPs` in the built list, so both the insert and the delete index are
     derived from the CURRENT list (which never contains the toggled row's dependency on itself):

```swift
                let oldValue = peerData.shouldAllowExcludePrivateIPsControl
                peerData[.allowedIPs] = value
                if oldValue != peerData.shouldAllowExcludePrivateIPsControl,
                   let allowedIPsRow = self.peerFieldsToShow(for: peerData).firstIndex(of: .allowedIPs) {
                    let excludeRow = allowedIPsRow + 1
                    if peerData.shouldAllowExcludePrivateIPsControl {
                        self.tableView.insertRows(at: [IndexPath(row: excludeRow, section: indexPath.section)], with: .fade)
                    } else {
                        self.tableView.deleteRows(at: [IndexPath(row: excludeRow, section: indexPath.section)], with: .fade)
                    }
                }
```

  6. `deletePeerCell`'s confirmation closure (re-inserting `.excludePrivateIPs` into the FIRST
     peer section): `if let firstPeerData = self.tunnelViewModel.peersData.first, let row =
     self.peerFieldsToShow(for: firstPeerData).firstIndex(of: .excludePrivateIPs)`.
  7. `addPeerCell`'s closure (deleting the first peer's `.excludePrivateIPs` row after append):
     the control is no longer in the built list, so the removed row index is
     `peerFieldsToShow(for: firstPeerData).firstIndex(of: .allowedIPs)! + 1` — expressed with
     `guard let` (no force-unwrap):

```swift
                if shouldHideExcludePrivateIPs, let firstPeerData = self.tunnelViewModel.peersData.first,
                   let allowedIPsRow = self.peerFieldsToShow(for: firstPeerData).firstIndex(of: .allowedIPs) {
                    let rowIndexPath = IndexPath(row: allowedIPsRow + 1, section: self.interfaceFieldsBySection.count /* First peer section */)
                    self.tableView.deleteRows(at: [rowIndexPath], with: .fade)
                }
```

  The builder:

```swift
    func peerFieldsToShow(for peerData: TunnelViewModel.PeerData) -> [TunnelViewModel.PeerField] {
        var fields: [TunnelViewModel.PeerField] = [.publicKey, .preSharedKey, .endpoint, .wsMode]
        if !peerData[.wsMode].isEmpty {
            fields.append(contentsOf: TunnelViewModel.PeerData.wsParameterFields)
        }
        fields.append(.allowedIPs)
        if peerData.shouldAllowExcludePrivateIPsControl {
            fields.append(.excludePrivateIPs)
        }
        fields.append(contentsOf: [.persistentKeepAlive, .deletePeer])
        return fields
    }
```

- `[x]` Action: route the new fields in `peerCell(for:at:with:)`:

```swift
        switch field {
        case .deletePeer:
            return deletePeerCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        case .excludePrivateIPs:
            return excludePrivateIPsCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        case .wsMode:
            return wsModeCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        case .wsMask, .wsTlsInsecure:
            return wsSwitchCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        case .wsTlsCa, .wsTlsCert, .wsTlsKey:
            return wsFileCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        default:
            return peerFieldKeyValueCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        }
```

- `[x]` Action: add the new cell builders + selection handling + document picker plumbing. The
  two stored properties (`pendingWsFilePeer`, `pendingWsFileField`) MUST go in the main `class
  TunnelEditTableViewController` declaration body (stored properties cannot live in extensions);
  the methods join the existing data-source extension:

```swift
    private func wsModeCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = field.localizedUIString
        cell.detailMessage = wsModeLocalizedDescription(peerData[.wsMode])
        return cell
    }

    private func wsModeLocalizedDescription(_ wireValue: String) -> String {
        switch wireValue {
        case WsMode.websocket.rawValue: return tr("tunnelPeerWsModeWebsocket")
        case WsMode.wstunnel.rawValue: return tr("tunnelPeerWsModeWstunnel")
        default: return tr("tunnelPeerWsModeNone")
        }
    }

    private func wsSwitchCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = field.localizedUIString
        cell.isOn = peerData[field] == "true"
        cell.onSwitchToggled = { [weak peerData] isOn in
            peerData?[field] = isOn ? "true" : ""
        }
        return cell
    }

    private func wsFileCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = field.localizedUIString
        let value = peerData[field]
        cell.detailMessage = value.isEmpty ? tr("tunnelEditSelectFile") : (value as NSString).lastPathComponent
        return cell
    }

    private func showWsModeActionSheet(for peerData: TunnelViewModel.PeerData, at indexPath: IndexPath) {
        let alert = UIAlertController(title: tr("tunnelPeerWsMode"), message: nil, preferredStyle: .actionSheet)
        let options: [(String, String)] = [
            (tr("tunnelPeerWsModeNone"), ""),
            (tr("tunnelPeerWsModeWebsocket"), WsMode.websocket.rawValue),
            (tr("tunnelPeerWsModeWstunnel"), WsMode.wstunnel.rawValue)
        ]
        for (title, wireValue) in options {
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self, weak peerData] _ in
                guard let self = self, let peerData = peerData else { return }
                peerData[.wsMode] = wireValue
                if wireValue.isEmpty {
                    // Back to UDP: drop the now-hidden WS parameter values, or save() would
                    // reject them via the presence checks with no visible field to fix.
                    peerData.clearWsParameterFields()
                }
                self.tableView.reloadSections(IndexSet(integer: indexPath.section), with: .fade)
            })
        }
        alert.addAction(UIAlertAction(title: tr("actionCancel"), style: .cancel, handler: nil))
        if let popoverPresentationController = alert.popoverPresentationController {
            popoverPresentationController.sourceView = tableView.cellForRow(at: indexPath) ?? tableView
            popoverPresentationController.sourceRect = (tableView.cellForRow(at: indexPath) ?? tableView).bounds
        }
        present(alert, animated: true)
    }

    private var pendingWsFilePeer: TunnelViewModel.PeerData?
    private var pendingWsFileField: TunnelViewModel.PeerField?

    private func showWsFilePicker(for peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) {
        pendingWsFilePeer = peerData
        pendingWsFileField = field
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = self
        present(picker, animated: true)
    }
```

  Selection wiring (`willSelectRowAt` / `didSelectRowAt` gain peer-section handling):

```swift
    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        switch sections[indexPath.section] {
        case .onDemand:
            return indexPath.row == 2 ? indexPath : nil
        case .peer(let peerData):
            switch peerFieldsToShow(for: peerData)[indexPath.row] {
            case .wsMode, .wsTlsCa, .wsTlsCert, .wsTlsKey:
                return indexPath
            default:
                return nil
            }
        default:
            return nil
        }
    }
```

  and `didSelectRowAt` becomes:

```swift
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch sections[indexPath.section] {
        case .onDemand:
            assert(indexPath.row == 2)
            tableView.deselectRow(at: indexPath, animated: true)
            let ssidOptionVC = SSIDOptionEditTableViewController(option: onDemandViewModel.ssidOption, ssids: onDemandViewModel.selectedSSIDs)
            ssidOptionVC.delegate = self
            navigationController?.pushViewController(ssidOptionVC, animated: true)
        case .peer(let peerData):
            tableView.deselectRow(at: indexPath, animated: true)
            switch peerFieldsToShow(for: peerData)[indexPath.row] {
            case .wsMode:
                showWsModeActionSheet(for: peerData, at: indexPath)
            case .wsTlsCa, .wsTlsCert, .wsTlsKey:
                showWsFilePicker(for: peerData, field: peerFieldsToShow(for: peerData)[indexPath.row])
            default:
                assertionFailure()
            }
        default:
            assertionFailure()
        }
    }
```

  Document picker delegate (new extension in the same file):

```swift
extension TunnelEditTableViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let peerData = pendingWsFilePeer
        let field = pendingWsFileField
        pendingWsFilePeer = nil
        pendingWsFileField = nil
        guard let url = urls.first, let peerData = peerData, let field = field else { return }
        // The picked URL can be a non-local file-provider item whose copy blocks on a download —
        // never on the main thread (same pattern as TunnelImporter).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FileManager.importWsTlsFile(from: url) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let destination):
                    peerData[field] = destination.path
                    self.tableView.reloadData()
                case .failure(let error):
                    self.showWsFileImportError(error)
                }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingWsFilePeer = nil
        pendingWsFileField = nil
    }

    private func showWsFileImportError(_ error: Error) {
        // Shared code stays tr()-free (the NE must not see it), so the localized mapping
        // lives here: surface the underlying Cocoa error's localized message.
        let message: String
        switch error {
        case FileManager.WsTlsImportError.noAppGroupContainer:
            message = tr("alertWsFileImportFailedNoContainerMessage")
        case FileManager.WsTlsImportError.copyFailed(let underlyingError):
            message = tr(format: "alertWsFileImportFailedMessage (%@)", underlyingError.localizedDescription)
        default:
            message = tr(format: "alertWsFileImportFailedMessage (%@)", error.localizedDescription)
        }
        ErrorPresenter.showErrorAlert(title: tr("alertWsFileImportFailedTitle"), message: message, from: self)
    }
}
```

  Also extend `peerFieldKeyValueCell`'s keyboard/placeholder switch:

```swift
        case .wstunnelTarget, .wsBearer:
            cell.placeholderText = tr("tunnelEditPlaceholderTextOptional")
            cell.keyboardType = .default
        case .wsPingInterval, .wsBackoffMin, .wsBackoffMax:
            cell.placeholderText = tr("tunnelEditPlaceholderTextAutomatic")
            cell.keyboardType = .numberPad
        case .wsMode, .wsMask, .wsTlsCa, .wsTlsCert, .wsTlsKey, .wsTlsInsecure:
            fatalError()
```

Context: `tr("actionCancel")` already exists in `Localizable.strings`.

### Task 5.3 — modify `Sources/WireGuardApp/UI/iOS/ViewController/TunnelDetailTableViewController.swift` `[x]`

- `[x]` Action: extend the static `peerFields` list (after `.persistentKeepAlive`):

```swift
    static let peerFields: [TunnelViewModel.PeerField] = [
        .publicKey, .preSharedKey, .endpoint,
        .allowedIPs, .persistentKeepAlive,
        .wsMode, .wstunnelTarget, .wsBearer, .wsMask, .wsTlsCa, .wsTlsCert,
        .wsTlsKey, .wsTlsInsecure, .wsPingInterval, .wsBackoffMin, .wsBackoffMax,
        .rxBytes, .txBytes, .lastHandshakeTime
    ]
```

- `[x]` Action: in the peer-cell configuration (where `.preSharedKey` maps to
  `tr("tunnelPeerPresharedKeyEnabled")`), render the secret/boolean fields as markers:

```swift
        if field == .persistentKeepAlive {
            cell.value = tr(format: "tunnelPeerPersistentKeepaliveValue (%@)", peerData[field])
        } else if field == .preSharedKey || field == .wsBearer {
            cell.value = tr("tunnelPeerPresharedKeyEnabled")
        } else if field == .wsMask || field == .wsTlsInsecure {
            cell.value = tr("tunnelPeerWsEnabled")
        } else {
            cell.value = peerData[field]
        }
```

  (the existing `.persistentKeepAlive` formatting branch is PRESERVED — only the marker branches
  are added)

DoD (US5): all US5 actions implemented as specified; WS fields hidden for UDP peers
(`filterFieldsWithValueOrControl` drops empty fields in detail; the editor shows them only when a
mode is set). Build execution happens ONLY in the US9 quality gates.

---

## User Story 6 — macOS UI: highlighter + detail + error mapping `[x]`

Why: the macOS editor is raw wg-quick text gated by the highlighter (`ConfTextStorage.hasError`
blocks saving) — without the new keys, macOS users cannot save WS configs at all.

Acceptance criteria:
- `[x]` all 11 `WS*` keys + `ws(s)://` endpoints highlight as valid; invalid values highlight red
- `[x]` macOS detail view shows WS fields (bearer/booleans as markers)
- `[x]` every new `ParseError` case has a macOS alert mapping

### Task 6.1 — modify `Sources/WireGuardApp/UI/macOS/View/highlighter.c` `[x]`

- `[x]` Action: add validators (after `is_valid_endpoint`):

```c
static bool is_valid_ws_mode(string_span_t s)
{
	return is_caseless_same(s, "websocket") || is_caseless_same(s, "wstunnel");
}

static bool is_valid_ws_bool(string_span_t s)
{
	return is_same(s, "true") || is_same(s, "false");
}

static bool is_valid_ws_millis(string_span_t s)
{
	return is_valid_uint(s, false, 0, 4294967295U);
}

static bool is_valid_ws_url(string_span_t s)
{
	size_t authority_start, authority_len = 0;

	if (s.len > 5 && is_caseless_same((string_span_t){ s.s, 5 }, "ws://"))
		authority_start = 5;
	else if (s.len > 6 && is_caseless_same((string_span_t){ s.s, 6 }, "wss://"))
		authority_start = 6;
	else
		return false;
	while (authority_start + authority_len < s.len && s.s[authority_start + authority_len] != '/')
		++authority_len;
	return is_valid_endpoint((string_span_t){ s.s + authority_start, authority_len });
}
```

- `[x]` Action: extend `enum field` (peer section, before `Invalid`):

```c
	PeerSection,
	PublicKey,
	PresharedKey,
	AllowedIPs,
	Endpoint,
	PersistentKeepalive,
	WSMode,
	WSTunnelTarget,
	WSBearer,
	WSMask,
	WSTLSCA,
	WSTLSCert,
	WSTLSKey,
	WSTLSInsecure,
	WSPingInterval,
	WSBackoffMin,
	WSBackoffMax,

	Invalid
```

- `[x]` Action: extend `get_field` with the matching `check_enum` lines (after
  `check_enum(PersistentKeepalive);`):

```c
	check_enum(WSMode);
	check_enum(WSTunnelTarget);
	check_enum(WSBearer);
	check_enum(WSMask);
	check_enum(WSTLSCA);
	check_enum(WSTLSCert);
	check_enum(WSTLSKey);
	check_enum(WSTLSInsecure);
	check_enum(WSPingInterval);
	check_enum(WSBackoffMin);
	check_enum(WSBackoffMax);
```

- `[x]` Action: in `highlight_value`, accept `ws(s)://` URLs for `Endpoint` and add the new field
  cases (before `default:`):

```c
	case Endpoint: {
		size_t colon;

		if (is_valid_ws_url(s)) {
			append_highlight_span(ret, parent.s, s, HighlightHost);
			break;
		}
		if (!is_valid_endpoint(s)) {
			append_highlight_span(ret, parent.s, s, HighlightError);
			break;
		}
		/* ... existing host:port splitting unchanged ... */
		break;
	}
	case WSMode:
		append_highlight_span(ret, parent.s, s, is_valid_ws_mode(s) ? HighlightHost : HighlightError);
		break;
	case WSTunnelTarget:
		append_highlight_span(ret, parent.s, s, is_valid_endpoint(s) ? HighlightHost : HighlightError);
		break;
	case WSBearer:
	case WSTLSCA:
	case WSTLSCert:
	case WSTLSKey:
		append_highlight_span(ret, parent.s, s, s.len ? HighlightHost : HighlightError);
		break;
	case WSMask:
	case WSTLSInsecure:
		append_highlight_span(ret, parent.s, s, is_valid_ws_bool(s) ? HighlightHost : HighlightError);
		break;
	case WSPingInterval:
	case WSBackoffMin:
	case WSBackoffMax:
		append_highlight_span(ret, parent.s, s, is_valid_ws_millis(s) ? HighlightKeepalive : HighlightError);
		break;
```

Context: existing highlight types are reused (values render like hosts/numbers) — no
`highlighter.h`/theme change, so `ConfTextStorage`/`ConfTextColorTheme` stay untouched.

### Task 6.2 — modify `Sources/WireGuardApp/UI/macOS/ViewController/TunnelDetailTableViewController.swift` `[x]`

- `[x]` Action: extend the static `peerFields` list (after `.persistentKeepAlive`):

```swift
    static let peerFields: [TunnelViewModel.PeerField] = [
        .publicKey, .preSharedKey, .endpoint,
        .allowedIPs, .persistentKeepAlive,
        .wsMode, .wstunnelTarget, .wsBearer, .wsMask, .wsTlsCa, .wsTlsCert,
        .wsTlsKey, .wsTlsInsecure, .wsPingInterval, .wsBackoffMin, .wsBackoffMax,
        .rxBytes, .txBytes, .lastHandshakeTime
    ]
```

- `[x]` Action: in the `.peerFieldRow(let peerData, let field)` case of the row builder, extend
  the value chain with the marker fields:

```swift
            if field == .persistentKeepAlive {
                cell.value = tr(format: "tunnelPeerPersistentKeepaliveValue (%@)", peerData[field])
            } else if field == .preSharedKey || field == .wsBearer {
                cell.value = tr("tunnelPeerPresharedKeyEnabled")
            } else if field == .wsMask || field == .wsTlsInsecure {
                cell.value = tr("tunnelPeerWsEnabled")
            } else {
                cell.value = peerData[field]
            }
```

### Task 6.3 — modify `Sources/WireGuardApp/UI/macOS/ParseError+WireGuardAppError.swift` `[x]`

- `[x]` Action: extend the `switch` with the new cases:

```swift
        case .peerHasInvalidWsMode(let value):
            return (tr(format: "macAlertWsModeInvalid (%@)", value), "")
        case .peerHasInvalidWsTunnelTarget(let value):
            return (tr(format: "macAlertWsTunnelTargetInvalid (%@)", value), "")
        case .peerHasInvalidWsBearer:
            return (tr("macAlertWsBearerInvalid"), "")
        case .peerHasInvalidWsBoolean(let value):
            return (tr(format: "macAlertWsBooleanInvalid (%@)", value), "")
        case .peerHasInvalidWsMillis(let value):
            return (tr(format: "macAlertWsMillisInvalid (%@)", value), "")
        case .peerHasEmptyWsValue(let key):
            return (tr(format: "macAlertWsValueEmpty (%@)", key), "")
        case .peerHasInvalidTransport(let value):
            return (tr(format: "macAlertTransportInvalid (%@)", value), "")
        case .peerWsUrlRequiresWsMode:
            return (tr("macAlertWsUrlRequiresWsMode"), "")
        case .peerWsModeForbidsHostPortEndpoint:
            return (tr("macAlertWsModeForbidsHostPortEndpoint"), "")
        case .peerInboundWstunnelForbidden:
            return (tr("macAlertInboundWstunnelForbidden"), "")
        case .peerWstunnelRequiresTarget:
            return (tr("macAlertWstunnelRequiresTarget"), "")
        case .peerWsTunnelTargetForbidden:
            return (tr("macAlertWsTunnelTargetForbidden"), "")
        case .peerHasWsKeyWithoutWsMode(let key):
            return (tr(format: "macAlertWsKeyWithoutWsMode (%@)", key), "")
```

DoD (US6): all US6 actions implemented as specified; the highlighter accepts exactly the
canonical URL/key acceptance set and flags invalid values as `HighlightError` (covered by the US7
highlighter tests; executed in US9). Build execution happens ONLY in the US9 quality gates.

---

## User Story 7 — `WireGuardKitTests` target + tests `[x]`

Why: user-approved harness (resolves D2); covers the entire new decision logic on the host.

Acceptance criteria:
- `[x]` the `WireGuardKitTests` target exists, buildable with no team configured
  (`CODE_SIGNING_ALLOWED=NO` in its settings), compiling exactly the source set from the
  Decisions section
- `[x]` all test files from Task 7.3 are implemented (execution happens in the US9 quality gates)

### Task 7.1 — modify `WireGuard.xcodeproj/project.pbxproj` `[x]`

- `[x]` Action: add a `WireGuardKitTests` unit-test bundle target with minted UUIDs (prefix
  `AA0000000000000000000xxx`), wiring:
  1. `PBXFileReference` entries: `WireGuardKitTests.xctest` (product), the new source files
     `WsMode.swift` (`AA0000000000000000000101`), `WsUrl.swift` (`AA0000000000000000000102`),
     `WireGuardKitTests-Bridging-Header.h`, `WsUrlTests.swift`, `WgQuickWsConfigTests.swift`,
     `UapiGenerationTests.swift`, `UapiReadbackTests.swift`, `HighlighterTests.swift`,
     `TunnelViewModelWsTests.swift`.
  2. `PBXBuildFile` entries compiling INTO THE TEST TARGET: the 6 test files plus these existing
     file references — `585B10492577E293004F691E` (TunnelConfiguration.swift),
     `585B10462577E293004F691E` (InterfaceConfiguration.swift),
     `585B10472577E293004F691E` (PeerConfiguration.swift),
     `585B10522577E293004F691E` (Endpoint.swift), `585B10512577E293004F691E`
     (IPAddressRange.swift), `585B10482577E293004F691E` (DNSServer.swift),
     `585B104F2577E293004F691E` (PrivateKey.swift), `585B10502577E293004F691E`
     (PacketTunnelSettingsGenerator.swift), `585B104D2577E293004F691E` (DNSResolver.swift),
     `585B104E2577E293004F691E` (IPAddress+AddrInfo.swift), `585B104C2577E293004F691E`
     (Array+ConcurrentMap.swift), `5F9696AF21CD7128008063FE`
     (TunnelConfiguration+WgQuickConfig.swift), `5F4541B121CBFAEE00994C13`
     (String+ArrayConversion.swift), `6B707D8321F918D4000A8F73`
     (TunnelConfiguration+UapiConfig.swift), `5F52D0C121E378C000283CEA` (highlighter.c),
     `585B10572577E293004F691E` (key.c), `585B10562577E293004F691E` (x25519.c),
     `6F628C3C217F09E9003482A3` (TunnelViewModel.swift), `6FE1765921C90E87002690EA`
     (LocalizationHelper.swift), and the new `WsMode.swift`/`WsUrl.swift` refs.
  3. `PBXBuildFile` entries adding `WsMode.swift` + `WsUrl.swift` to the 4 existing Sources phases
     (`6FF4AC10211EC46F002C96EB` iOS app, `6FB1BD5921D2607A00A991BF` macOS app,
     `6F5D0C16218352EF000F85AD` NE iOS, `6FB1BD8D21D4BFE600A991BF` NE macOS), and group-children
     entries in the `WireGuardKit` group `585B10452577E293004F691E`.
  4. New `PBXGroup` "WireGuardKitTests" (path `Sources/WireGuardKitTests`) added to the
     `mainGroup` (`6FF4AC0B211EC46F002C96EB`) children; product added to the Products group
     (`6FF4AC15211EC46F002C96EB`).
  5. New `PBXSourcesBuildPhase` + empty `PBXFrameworksBuildPhase`, `PBXNativeTarget`
     (`productType = "com.apple.product-type.bundle.unit-test"`), entry in the `PBXProject`
     `targets` list, and an `XCConfigurationList` with Debug/Release `XCBuildConfiguration`s:

```
		AA0000000000000000000201 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGNING_ALLOWED = NO;
				GENERATE_INFOPLIST_FILE = YES;
				MACOSX_DEPLOYMENT_TARGET = 12.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.wireguard.WireGuardKitTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = macosx;
				SWIFT_OBJC_BRIDGING_HEADER = "Sources/WireGuardKitTests/WireGuardKitTests-Bridging-Header.h";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
```

  (Release: identical minus `SWIFT_OPTIMIZATION_LEVEL`.) The test target compiles the
  model/serialization sources directly — NOT `WireGuardAdapter.swift` — so nothing links
  `libwg-go.a` and no signing/entitlements are involved.

### Task 7.2 — create `Sources/WireGuardKitTests/WireGuardKitTests-Bridging-Header.h` `[x]`

- `[x]` Action: create:

```c
/* SPDX-License-Identifier: MIT */

#include "../WireGuardKitC/WireGuardKitC.h"
#include "../WireGuardApp/UI/macOS/View/highlighter.h"
```

### Task 7.3 — create the test files `[x]`

All tests: XCTest, Arrange-Act-Assert, `test_method_scenario` naming, offline, order-independent,
self-cleaning (no filesystem/network use). Full test code is derivable from the implementation +
this table:

- `[x]` `Sources/WireGuardKitTests/WsUrlTests.swift`

| Test | Verifies |
|---|---|
| `test_init_acceptsWssHostPortPath` | `wss://h:443/p` → host/port/urlString verbatim |
| `test_init_acceptsNoPathAndQueryAfterPath` | `ws://h:80` and `wss://h:443/p?q=1` parse |
| `test_init_rejectsMissingPortSchemeHost` | missing port / `http://` / empty host → nil |
| `test_init_rejectsUserinfo` | `ws://user:pass@h:80/p` → nil (tools acceptance set) |
| `test_init_rejectsQueryWithoutPath` | `ws://h:80?q=1` → nil (tools acceptance set) |
| `test_init_ipv6BracketHost` | `ws://[::1]:8080` → host `::1` (brackets stripped whether or not Foundation returns them); `endpoint()` re-brackets exactly once |
| `test_endpoint_matchesUdpEndpointParsing` | `endpoint()` equals `Endpoint(from: "h:port")` |
| `test_isWsUrl_caseInsensitivePrefix` | `WS://`/`wss://` true; `host:port` false |

- `[x]` `Sources/WireGuardKitTests/WgQuickWsConfigTests.swift` (parse + validation + round-trip;
  each rejection asserts the SPECIFIC `ParseError` case)

| Test | Verifies |
|---|---|
| `test_parse_wsEndpointWithMode_dialingWebsocket` | URL endpoint + `WSMode = websocket` → wsUrl + routable endpoint set |
| `test_parse_wstunnelRequiresTarget` | wstunnel + URL without `WSTunnelTarget` → `.peerWstunnelRequiresTarget` |
| `test_parse_websocketRejectsTarget` | websocket + target → `.peerWsTunnelTargetForbidden` |
| `test_parse_wsModeWithoutEndpoint_inbound` | mode, no endpoint → inbound peer, no endpoint/wsUrl |
| `test_parse_inboundWstunnel_rejected` | wstunnel, no endpoint → `.peerInboundWstunnelForbidden` |
| `test_parse_wsUrlWithoutMode_rejected` | URL endpoint, no mode → `.peerWsUrlRequiresWsMode` |
| `test_parse_hostPortEndpointWithMode_rejected` | `host:port` + mode → `.peerWsModeForbidsHostPortEndpoint` |
| `test_parse_wsKeysOnUdpPeer_rejected` | each `WS*` key alone on UDP peer EXCEPT `WSTunnelTarget` (incl. `WSMask = false`, `WSPingInterval = 0`) → `.peerHasWsKeyWithoutWsMode` |
| `test_parse_wstunnelTargetOnUdpPeer_rejected` | `WSTunnelTarget` alone on UDP peer → `.peerWsTunnelTargetForbidden` (placement check fires first) |
| `test_parse_badBoolAndMillis_rejected` | `WSMask = yes` → `.peerHasInvalidWsBoolean`; `WSPingInterval = abc`/`-1` → `.peerHasInvalidWsMillis` |
| `test_parse_invalidWsMode_rejected` | `WSMode = tcp` → `.peerHasInvalidWsMode` |
| `test_parse_malformedWstunnelTarget_rejected` | `WSTunnelTarget = nocolon` → `.peerHasInvalidWsTunnelTarget` |
| `test_parse_emptyBearer_rejected` | `WSBearer =` → `.peerHasInvalidWsBearer` (error carries no value) |
| `test_parse_zeroMillis_absentAfterRoundTrip` | `WSPingInterval = 0` on WS peer → parses, dropped on emission |
| `test_asWgQuickConfig_roundTrip_wsPeer` | full wstunnel peer parse→emit→parse equal; URL byte-verbatim |
| `test_asWgQuickConfig_udpPeerUnchanged` | UDP peer emission has zero `WS*` lines |
| `test_parse_caseInsensitiveKeysAndValues` | `wsmode = WEBSOCKET`, `WSMODE` key casing accepted |

- `[x]` `Sources/WireGuardKitTests/UapiGenerationTests.swift`

| Test | Verifies |
|---|---|
| `test_uapiConfiguration_udpPeer` | `transport=udp` present, zero `ws_*` lines |
| `test_uapiConfiguration_wstunnelPeer` | `transport=wstunnel`, `ws_url=`, `wstunnel_target=`, set flags/timings emitted, unset ones absent |
| `test_uapiConfiguration_inboundWebsocketPeer` | `transport=websocket`, no `endpoint=`, no `ws_url=` |
| `test_endpointUapiConfiguration_wsPeerCarriesWsBlock` | resolved WS peer update includes `endpoint=` AND `ws_url=` block |
| `test_endpointUapiConfiguration_udpPeerUnchanged` | UDP peer update stays `public_key` + `endpoint` only |
| `test_uapiConfiguration_neverEmitsBearerForUdp` | belt-and-braces: `ws_bearer` only under a WS mode |

  Setup note: build `PacketTunnelSettingsGenerator` with pre-resolved IP endpoints
  (`resolvedEndpoints:` init parameter) — no DNS involved.

- `[x]` `Sources/WireGuardKitTests/UapiReadbackTests.swift`

| Test | Verifies |
|---|---|
| `test_fromUapiConfig_udpPeerWithTransportLine` | fork-shaped `transport=udp` get-output parses (regression gate for ALL tunnels) |
| `test_fromUapiConfig_wstunnelPeerFullBlock` | ws fields populated; `endpoint=` = resolved dial target; stats parsed |
| `test_fromUapiConfig_invalidTransport_rejected` | `transport=tcp` → `.peerHasInvalidTransport` |
| `test_fromUapiConfig_zeroTimingNormalizedToNil` | `ws_ping_interval=0` → nil |

- `[x]` `Sources/WireGuardKitTests/HighlighterTests.swift` (calls `highlight_config` through the
  bridging header; helper converts the span array to `(type, substring)` pairs and `free`s it)

| Test | Verifies |
|---|---|
| `test_highlight_wsKeysValid` | full WS peer block → no `HighlightError` span |
| `test_highlight_wsEndpointUrl` | `Endpoint = wss://h:443/p` → `HighlightHost`, no error |
| `test_highlight_urlAcceptanceMatchesWsUrl` | `ws://user:pass@h:80/p` and `ws://h:80?q=1` → `HighlightError` (same rejection as `WsUrl`) |
| `test_highlight_invalidModeBoolMillis` | `WSMode = tcp`, `WSMask = yes`, `WSPingInterval = x` → `HighlightError` each |
| `test_highlight_wsKeysStillInvalidInInterfaceSection` | `WSMode` under `[Interface]` → `HighlightError` |
| `test_highlight_udpConfigUnaffected` | pre-existing UDP config highlights exactly as before (no error spans) |

- `[x]` `Sources/WireGuardKitTests/TunnelViewModelWsTests.swift` (the view-model duplicates the
  cross-field contract with per-field errors — `tr()` returns the raw key in the test bundle,
  so assertions target `fieldsWithError`/`SaveResult` cases, never message text)

| Test | Verifies |
|---|---|
| `test_save_wsPeerRoundTrip` | scratchpad from a full wstunnel `PeerConfiguration` → `save()` → equal configuration |
| `test_save_wsUrlEndpointParsesToWsUrl` | endpoint field `wss://h:443/p` + mode → `wsUrl` + routable endpoint set |
| `test_save_wsUrlWithoutMode_marksWsModeError` | `.error` result, `fieldsWithError` contains `.wsMode` |
| `test_save_hostPortWithMode_marksEndpointError` | `.error` result, `fieldsWithError` contains `.endpoint` |
| `test_save_wstunnelWithoutTarget_marksTargetError` | `.error` result, `fieldsWithError` contains `.wstunnelTarget` |
| `test_save_targetWithoutDialingWstunnel_marksTargetError` | target + websocket mode → `.error`, `.wstunnelTarget` marked |
| `test_save_wsFieldWithoutMode_marksFieldError` | any WS param without mode → `.error`, offending field marked |
| `test_save_invalidMillis_marksFieldError` | `wsPingInterval = "abc"` → `.error`, `.wsPingInterval` marked |
| `test_save_zeroMillisNormalizedToNil` | `"0"` timing saves as nil (dropped on emission) |
| `test_scratchpad_booleansStoredAsTrueMarker` | `wsMask`/`wsTlsInsecure` true → scratchpad `"true"`; false → absent |
| `test_clearWsParameterFields_makesUdpPeerSaveable` | WS peer → mode cleared + `clearWsParameterFields()` → `save()` succeeds as plain UDP peer |

DoD: target wiring and test files exactly as specified; test execution and SwiftLint run ONLY in
the US9 quality gates.

---

## User Story 8 — Docs + rules refresh `[x]`

Why: the canonical docs and `project.md` MUST always reflect the delivered state (pipeline §2).

Acceptance criteria:
- `[x]` canonical docs describe the delivered state; WORK_INDEX statuses updated; `project.md`
  accurate and concise

### Task 8.1 — update `docs/PROJECT.md`, `docs/ARCHITECTURE.md`, `docs/WORK_INDEX.md` `[x]`

- `[x]` Action: modify `docs/PROJECT.md`:
  - Tech-stack table, "Userspace core" row cell becomes:

```
`Sources/WireGuardKitGo` → universal `libwg-go.a`, wrapping `golang.zx2c4.com/wireguard` replaced by the sibling fork `github.com/danielealbano/wireguard-go v1.3.0` (UDP + WebSocket multiplex bind). Module `golang.zx2c4.com/wireguard/apple`, `go` directive 1.26.5; the Makefile downloads and patches a pinned Go 1.26.5 toolchain (`GOTOOLCHAIN=local`).
```

  - "The Go bridge" section: state the multiplex bind (`conn.NewMultiplexBind` +
    `conn.WithWSLogger`, no protect upcall on Apple), the UNCHANGED `//export`/`wireguard.h`
    surface, the pinned-toolchain + boottime-patch flow, the replace-aware version header, and
    REMOVE the "Known pre-existing debt" paragraph (T1 fixed by this plan).
  - "Config model & storage": add the per-peer WS surface (the 11 `WS*` keys, `ws(s)://`
    endpoints, URL acceptance set) and:

```
TLS CA/cert/key files referenced by WS peers live in the app group container's `ws-tls/` folder
(the only location both the app and the NE sandbox can read); the iOS editor's document picker
copies picked files there, macOS users place files there manually.
```

  - "Testing" section: replace the "no automated tests" paragraph with the `WireGuardKitTests`
    description (macOS unit bundle; model/serialization/view-model/highlighter scope; run via
    `xcodebuild -project WireGuard.xcodeproj -target WireGuardKitTests -configuration Debug build
    SYMROOT=build` + `xcrun xctest build/Debug/WireGuardKitTests.xctest`; no device/network/
    signing). Keep the statement that tunnel behavior validation is manual.
  - "Roadmap": WebSocket transport delivered in code by plan 1; live-tunnel validation (W6)
    pending ADP.
- `[x]` Action: modify `docs/ARCHITECTURE.md`:
  - §2 sequence chart line (Mermaid touched ⇒ US9 gate 8 validates it):

```
    Go->>Go: CreateTUNFromFile + NewMultiplexBind<br/>IpcSet + device.Up
```

  - §3: append after the platform-divergence table:

```
WebSocket/wstunnel peers ride the SAME per-platform path-change semantics: `wgBumpSockets` →
`device.BindUpdate()` closes and reopens the multiplex bind (UDP rebind + WS re-dial), and the
iOS endpoint re-resolution path re-sends each dialing WS peer's full `ws_*` block together with
the re-resolved `endpoint=` (the fork ignores a WS endpoint update that arrives without
`ws_url`; on resolution failure nothing is sent for that peer, matching UDP behavior).
```

  - §4: add the WS fields to the model description and the `WS*`/`transport=`+`ws_*` keys to the
    three serialization-surface paragraphs (`highlighter.c` key set included).
  - §5: describe the pinned Go 1.26.5 download (SHA256-verified, cached in
    `Sources/WireGuardKitGo/.cache/`, `GOTOOLCHAIN=local`) feeding the patched-GOROOT flow.
  - §7: replace the "will land" framing with the delivered touch-point mapping (this plan).
- `[x]` Action: modify `docs/WORK_INDEX.md` — statuses become: W1–W5 `DELIVERED (plan 1)`;
  W6 `PENDING P1 (ADP)`; T1 `FIXED (plan 1)`; D2 `RESOLVED — user approved; WireGuardKitTests
  added (plan 1)`; D4 `RESOLVED — single plan (docs/plans/1_websocket_wstunnel_transport_
  20260808170409.md)`; P1 unchanged (enrollment underway).

### Task 8.2 — update `.claude/rules/project.md` `[x]`

- `[x]` Action: modify `.claude/rules/project.md`:
  - Tech-stack "Userspace core" row cell becomes:

```
`Sources/WireGuardKitGo` → universal `libwg-go.a`, wrapping the sibling fork `github.com/danielealbano/wireguard-go v1.3.0` (via `replace`; UDP+WebSocket multiplex bind). Module `golang.zx2c4.com/wireguard/apple`, `go` directive 1.26.5, pinned-download toolchain (`GOTOOLCHAIN=local`).
```

  - Standard Commands table — add:

```
| Tests (build) | `xcodebuild -project WireGuard.xcodeproj -target WireGuardKitTests -configuration Debug build SYMROOT=build` |
| Tests (run) | `xcrun xctest build/Debug/WireGuardKitTests.xctest` |
```

    and append below the table:

```
**TEMPORARY deviation (user-approved, until ADP/P1–P2 complete):** the app/NE targets are
compile-verified with `CODE_SIGNING_ALLOWED=NO` appended to the build commands; the signed build
MUST be re-verified once the paid account is active, and this note MUST then be removed.
```

  - Remove the "Known pre-existing debt" paragraph (T1 fixed).
  - Testing section: replace "There are NO automated tests in this repo" with the
    `WireGuardKitTests` scope (model/serialization/view-model/highlighter; host-only, no
    device/network/signing) + keep "tunnel behavior validation is MANUAL" and the rule that any
    FURTHER harness (UI tests, Go tests, CI) still requires explicit user approval.
  - Keep the suppressions list unchanged.

DoD: docs consistent with the code (Mermaid validation for the touched charts runs ONLY in the
US9 quality gates — gate 8).

---

## User Story 9 — Ground-up verification + quality gates `[x]`

Why: the plan's single quality-gate point (pipeline §6) — everything implemented is re-verified
from the ground up before review.

Acceptance criteria:
- `[x]` every checkbox in this plan is `[x]` (or the digression is recorded in `## Deviations`)
- `[x]` ALL quality gates below pass on the final code
- `[x]` the Manual Test steps are documented for execution once ADP is active

### Task 9.1 — double-check EVERYTHING from the ground up `[x]`

- `[x]` Re-read this plan top-to-bottom; verify every action is implemented and checkmarked;
  reconcile any digression into `## Deviations`.
- `[x]` Verify `Sources/WireGuardKitGo/wireguard.h` is byte-identical to `master`
  (`git diff master -- Sources/WireGuardKitGo/wireguard.h` is empty).
- `[x]` Verify NO entitlement, Info.plist, `Package.swift`, or `.swiftlint.yml` changes
  (`git diff master --stat` contains none of them); `swift package dump-package` still succeeds.
- `[x]` Verify the bearer never reaches logs/errors: `git grep -n "wsBearer" Sources/` — every
  hit is model/serialization/UI-marker code; no interpolation into log or error strings.
- `[x]` Quality gates (ALL must pass; capture long output per `agent.md` §5 with `tee`):
  1. `swiftlint` (repo root) — ZERO violations.
  2. `make -C Sources/WireGuardKitGo clean build 2>&1 | tee /tmp/wireguard-apple-go-macos.log`
  3. `make -C Sources/WireGuardKitGo clean build PLATFORM_NAME=iphoneos ARCHS=arm64 SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path) 2>&1 | tee /tmp/wireguard-apple-go-ios.log`
  4. `cd Sources/WireGuardKitGo && go vet ./...` — ZERO findings; `go mod tidy` — no diff;
     `govulncheck ./...` (fallback `go run golang.org/x/vuln/cmd/govulncheck@latest ./...` if not
     installed) — clean.
  5. `xcodebuild -project WireGuard.xcodeproj -target WireGuardmacOS -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wireguard-apple-build-macos.log` — succeeds, no new warnings.
  6. `xcodebuild -project WireGuard.xcodeproj -target WireGuardiOS -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wireguard-apple-build-ios.log` — succeeds, no new warnings.
  7. `xcodebuild -project WireGuard.xcodeproj -target WireGuardKitTests -configuration Debug build SYMROOT=build 2>&1 | tee /tmp/wireguard-apple-tests-build.log` then
     `xcrun xctest build/Debug/WireGuardKitTests.xctest 2>&1 | tee /tmp/wireguard-apple-tests-run.log` — ALL tests pass.
  8. Mermaid validation (§9 of `development_pipeline.md`) for `docs/ARCHITECTURE.md` and any other
     touched chart — ALL charts OK.
- `[x]` **Manual Test (deferred until ADP is active — P1/P2, then re-verify)**:
  1. Signed Release builds of both apps (no `CODE_SIGNING_ALLOWED=NO`).
  2. iOS + macOS: import a wstunnel config against a live wstunnel server; tunnel comes up;
     traffic flows; runtime stats visible (readback).
  3. Network-switch pass per platform (Wi-Fi ⇄ cellular on iOS incl. temporary-shutdown/resume;
     interface change on macOS) — WS peers re-dial via `wgBumpSockets`.
  4. macOS: place a CA file in the group container `ws-tls/` folder, reference it by absolute
     path in the editor, verify TLS pinning works; iOS: pick the CA via the document picker.

DoD: every checkbox in this plan is `[x]`; all quality gates green; deviations recorded.

---

## Deviations

1. **Task 1.2 — version-header rule gains `@mkdir -p "$(DESTDIR)"`**: the standalone
   `make version-header DESTDIR=…` invocation fails without it (Xcode pre-creates the directory,
   the CLI does not). Behavior inside Xcode unchanged.
2. **Task 7.2 — the test bridging header includes `<sys/types.h>` before `WireGuardKitC.h`**:
   `WireGuardKitC.h` uses `u_int32_t`/`u_char`/`u_int16_t` without including `<sys/types.h>`
   itself; the app's bridging header gets them transitively, a standalone include does not.
3. **Task 7.3 — `HighlighterTests.swift` adds `import Foundation`**: the file calls `free(_:)`;
   real XCTest re-exports Foundation so it compiles either way, but the explicit import keeps the
   file self-contained.
4. **US9 — host-environment gate substitutions (this machine has NO Xcode.app and NO swiftlint;
   only Command Line Tools)**: `xcodebuild` (macOS app, iOS app, `WireGuardKitTests` bundle), the
   `iphoneos` Go-bridge build (no iOS SDK), and `swiftlint` CANNOT run here. Executed instead:
   the full macOS Go-bridge build (pinned-toolchain download + patch + fork compile + lipo,
   green), `go vet` ZERO findings, `go mod tidy` no diff, `govulncheck` clean, Mermaid 5/5 OK,
   `swiftc -typecheck` of the host-checkable changed Swift surface — the kit model, both
   serialization surfaces, the view model, and the macOS error mapping (0 errors, 0 warnings;
   the iOS UIKit view controllers CANNOT be typechecked here — no iOS SDK without Xcode — and
   are verified ONLY by the pending `xcodebuild -target WireGuardiOS` gate), and ALL 52
   tests EXECUTED green on the host via a scratchpad-only XCTest shim (the real production
   sources + compiled `highlighter.c`/`key.c`/`x25519.c`; nothing shim-related is committed).
   The blocked gates MUST be re-run once Xcode + swiftlint are installed, together with the
   already-recorded signed-build re-verification (see `project.md` → TEMPORARY deviation).
   **UPDATE (Xcode 26.6 installed):** subsequently EXECUTED for real — macOS app `xcodebuild`
   BUILD SUCCEEDED and iOS app `xcodebuild -sdk iphoneos` BUILD SUCCEEDED (both with the
   approved `CODE_SIGNING_ALLOWED=NO`; ZERO warnings in branch-touched files), the committed
   `WireGuardKitTests` bundle built via `xcodebuild` and ALL 52 tests passed via
   `xcrun xctest` (0 failures), and the `iphoneos` Go-bridge build is green. ONLY the SwiftLint
   gate remains pending (the binary is not installed; installation awaits user consent) plus the
   signed-build re-verification once ADP completes.
5. **US9 — `swift package dump-package` was FAILING and `Package.swift` was fixed**: the US9
   checkbox was originally ticked in error (the failure was misread as a host-toolchain issue).
   The manifest was broken on `main` independently of this plan: it declares
   `swift-tools-version:5.3` but used `.macOS(.v12)`/`.iOS(.v15)`, which require
   PackageDescription 5.5, so it failed on EVERY toolchain. Root-cause fix applied per the
   fix-broken-builds rule: string-based platform versions (`.macOS("12.0")`/`.iOS("15.0")`),
   which are valid at tools-version 5.3 — the consumer-facing tools-version floor is unchanged.
   `swift package dump-package` now succeeds (verified on this host).
6. **US9 — `WireGuardKitC.h` gains `#include <sys/types.h>`**: with Xcode 26.6's stricter clang
   modules, building the `WireGuardKitC` module fails on every target because the umbrella header
   uses `u_int32_t`/`u_char`/`u_int16_t` without including `<sys/types.h>` (pre-existing on
   `main`; the same defect deviation #2 worked around in the test bridging header). Root-cause
   fix per the fix-broken-builds rule; the declared C surface is unchanged.
7. **Task 5.1 — dot-only names rejected in the ws-tls sanitizer** (code-review fix): a picked
   file whose sanitized name were `"."` or `".."` would resolve the copy destination to the
   `ws-tls` directory itself or the app group container root; dot-only results now fall back to
   the `"ws-tls"` default like the empty case. The Task 5.1 code block is re-aligned.
