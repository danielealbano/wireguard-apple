# Apple Platform Rules — ABSOLUTE RULES

These rules govern **Apple-platform build, project configuration, platform surfaces, packaging,
signing, and release** in ANY Apple-platform project (iOS / macOS / multi-platform) where this file
is present. They are **VERY STRICT and ABSOLUTELY NON-NEGOTIABLE**. They are AGNOSTIC:
project-specific details (targets, bundle identifiers, entitlement values, deployment targets,
command surface) live in `project.md` and the canonical docs it references. Language specifics live
in `swift.md` / `go.md`.

## 1) Build System & Configuration — ABSOLUTE RULES

- The project's build system (Xcode project, workspace, and/or Swift Package manifest — see
  `project.md`) is authoritative. You MUST build through it; you MUST NOT invent parallel build
  paths, scripts, or competing project files.
- Build settings MUST live where the project already keeps them (**xcconfig files** and the project
  file) — you MUST NOT scatter per-file overrides or duplicate settings across targets. Settings
  shared by several targets MUST be factored into the shared configuration, not copy-pasted.
- **Versioning MUST be centralized**: the marketing version and build number MUST come from the
  project's single documented source (e.g. a version xcconfig) — never hardcoded per-target.
- **Developer-specific configuration** (team ID, personal bundle-id prefixes) MUST stay in the
  gitignored developer configuration file the project defines; it MUST NEVER be committed, and you
  MUST NOT hardcode a team ID or personal identifier anywhere in tracked files.
- Deployment targets and the Swift language version MUST stay consistent across ALL targets of the
  same platform; you MUST NOT raise or lower them without the user's explicit approval.
- Native/foreign artifacts built by external build tools (e.g. a `make`-driven library that Xcode
  invokes through an external/legacy build target) are part of the build: a change MUST keep the
  ENTIRE build green for EVERY platform and architecture the project supports, and you MUST NOT
  hardcode, duplicate, or second-guess values the build system passes to those tools.
- If the project publishes a Swift Package manifest for external consumers, that manifest is a
  compatibility contract: target names, product names, and platform minimums MUST stay valid, and a
  change MUST keep the package resolvable/buildable for consumers.

## 2) Bundles, Entitlements & Platform Surfaces — ABSOLUTE RULES

- **Every entitlement is an attack-surface and review-surface declaration.** You MUST request the
  MINIMUM entitlements; you MUST NOT add, broaden, or remove entitlements, app groups, or keychain
  access groups without the user's explicit approval. The project's current entitlement set (per
  `project.md`) is deliberate.
- **Info.plist declarations are contracts**: document types, exported UTIs, usage-description
  strings, app-group keys, and background modes MUST stay accurate; a capability you add MUST carry
  its usage description, and a capability you no longer use MUST NOT linger.
- **App extensions are separate processes with separate sandboxes.** Code shared between an app and
  its extensions MUST live in the project's designated shared location; data shared between them
  MUST go through the project's established channels (app group container, keychain,
  provider-message IPC) — you MUST NOT invent new side channels.
- **Sensitive data belongs in the Keychain**, with the narrowest accessibility class and access
  group that works; it MUST NEVER be stored in plists, UserDefaults, files in the app container, or
  logs. Where the project stores secrets via keychain persistent references, you MUST keep that
  pattern intact.
- The app sandbox MUST stay enabled where it is enabled; you MUST NOT disable sandboxing, add
  temporary-exception entitlements, or widen file-access scopes to "fix" a problem.

### VPN / Network Extension projects — ABSOLUTE (when applicable)
- The packet-tunnel provider is THE tunnel entry point: tunnel networking MUST be configured through
  the provider's network-settings API, and configuration/teardown invariants (settings application
  before traffic, deterministic stop, error propagation to the host app) MUST be preserved.
- Tunnel configurations contain key material: they MUST be stored per the project's documented
  secure-storage pattern and MUST NEVER be logged or exported unencrypted beyond the user's explicit
  export action.

## 3) Static Analysis & Formatting — ABSOLUTE RULES

- The project's committed linter configuration (e.g. SwiftLint via its committed config file and/or
  build phase — see `project.md`) is THE static analyzer. The Definition of Done requires **ZERO
  violations** beyond the configuration already committed.
- The ONLY permitted analyzer/linter adjustments are the ones ALREADY committed (disabled rules,
  opt-in rules, in-code suppressions enumerated in `project.md`). You MUST NOT add new disabled
  rules, new in-code suppressions, or a baseline to hide findings — FIX the root cause. Any
  genuinely unavoidable suppression REQUIRES user approval first (per `agent.md`/`swift.md`).
- You MUST NOT introduce additional lint/format tooling (swiftformat, clang-format configs, hooks)
  without the user's explicit decision — it is a project-wide tooling change.
- Compiler warnings MUST be taken seriously: keep the build warning-clean; you MUST NOT silence
  warnings with blanket per-target flags.

## 4) Signing & Release — ABSOLUTE RULES

- **A shippable release MUST be a properly signed (and, where the platform requires it, notarized)
  Release build — NEVER a Debug build.**
- **Secrets are SACRED.** Signing certificates, provisioning profiles, private keys, and App Store
  Connect API keys MUST NEVER be committed or logged. Signing material MUST come from the developer
  configuration / CI secrets — never from tracked files.
- Release configuration (optimization, stripping, bitcode/entitlement variants) MUST NOT be weakened
  to make a build pass; fix the root cause.
- Distribution-channel differences (App Store vs. developer-ID/direct) MUST be handled through the
  project's established configuration mechanism, keeping ALL distributions consistent: a change to
  release behavior MUST be considered for every distribution the project ships.
- CI/release automation (when present — see `project.md`) MUST use the project's standard commands,
  MUST NOT print secrets, and MUST be extended deliberately — you MUST NOT add parallel/competing
  workflows or signing paths.

## 5) Testing (platform level) — ABSOLUTE RULES

- What automated tests exist, and where, is defined in `project.md` — you MUST NOT assume a test
  target exists where none does. Adding a test target/harness (XCTest unit/UI target, CI device
  farm) is a **tooling decision that REQUIRES the user**.
- Automated tests MUST NOT require a physical device, entitlements, signing, a live network, or
  user interaction; simulator-dependent and device-dependent validation MUST be documented as
  **Manual Test** steps where no automated harness exists.
- Platform-conditional code (`#if os(...)`) MUST be validated for EVERY platform the project
  supports — building one platform is NOT done (see `project.md` for the full build matrix).

## 6) Quality Gates — ABSOLUTE RULES

A change touching an Apple-platform project is DONE **ONLY** if ALL are true:

- The project builds cleanly for EVERY supported platform via the standard commands in
  `project.md`, with NO new warnings, including any external/legacy native build targets.
- The committed linter configuration reports ZERO violations beyond what is already documented.
- The test suite defined in `project.md` (if any) passes.
- No new entitlements, Info.plist capabilities, targets, dependencies, lint suppressions, signing
  configs, or CI beyond what was agreed with the user.
- When releasing: the artifact is a **signed** (and where required notarized) Release build (per §4).
- Mermaid charts (if any docs were touched) validate per `development_pipeline.md` §9.
