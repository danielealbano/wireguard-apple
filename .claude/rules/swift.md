# Swift Rules — ABSOLUTE RULES

These rules apply to ANY Swift code in ANY project where this file is present. They are **VERY STRICT
and ABSOLUTELY NON-NEGOTIABLE**! They are AGNOSTIC: project-specific details (module layout, target
wiring, platform conditionals, command targets, documented exceptions) live in the project-specific
rule file (`project.md`) and the canonical docs it references. Apple build/signing/platform-surface
concerns live in `apple.md`. When a rule below allows a "documented exception", that exception MUST
be documented in `project.md` — otherwise it does not exist.

## 1) Architecture & Idioms — ABSOLUTE RULES

### Idioms first
- You MUST follow the official Swift API Design Guidelines and keep code consistent with the
  EXISTING style of the codebase (the existing code is the reference).
- You MUST prefer **simplicity over cleverness**; clear is better than clever.
- You MUST prefer **immutability**: `let` over `var`, value types (`struct`/`enum`) for data,
  reference types (`class`) ONLY where identity, shared mutable state, or Objective-C interop
  genuinely requires them.
- You MUST respect Swift **optionals discipline**: NO force-unwrap (`!`), force-cast (`as!`), or
  force-try (`try!`) except where the invariant is provable AND the existing codebase's documented
  suppression pattern covers it (see "No lint suppression" below); prefer `guard let` / `if let` /
  `??` and early returns.
- You MUST model states with **enums with associated values** (state machines, errors, field types)
  rather than boolean/optional flag combinations, matching the existing codebase idiom.
- You MUST keep files, types, and functions small and cohesive. You MUST NEVER create "Utils"/
  "Helpers" grab-bag files; extensions MUST be narrow, well-named, and file-scoped to one concern
  (e.g. `Type+Concern.swift`).
- You MUST use `extension` to organize conformances (`Equatable`, `Hashable`, `Codable`) separately
  from the primary type definition, matching the existing codebase style.

### Boundaries, protocols & dependency wiring
- You MUST define **protocols at the consumer site** for external boundaries and for logic that
  needs test isolation; keep protocols small and cohesive. Do NOT create protocols speculatively for
  types with a single concrete implementation and no test need.
- Dependencies MUST be passed explicitly — initializer injection first, property/closure injection
  where the platform lifecycle requires it. You MUST NOT introduce new global singletons,
  service-locator patterns, or `static var` mutable state. Existing platform singletons
  (`NotificationCenter.default`, `FileManager.default`, …) are used at the edges, not spread through
  business logic.
- You MUST NOT add a third-party DI framework, reactive framework, or architecture framework without
  the user's explicit approval.
- **Delegates MUST be `weak`** (class-bound protocols, `AnyObject`); observation tokens MUST be
  retained and released deterministically. You MUST NEVER create retain cycles — closures capturing
  `self` from an escaping context MUST use `[weak self]` unless ownership is intended and provable.

### Concurrency — ABSOLUTE
- You MUST use the codebase's ESTABLISHED concurrency model and stay consistent with it. If the
  codebase serializes work on private `DispatchQueue`s with completion handlers, new code in those
  components MUST follow that model; if it uses structured concurrency (`async`/`await`, `Task`,
  actors), new code MUST follow that. You MUST NOT mix models within a component, and migrating a
  component between models is a decision that REQUIRES the user.
- Shared mutable state MUST be confined: to a serial queue, an actor, or the main thread — one
  documented confinement per component, enforced consistently. UI state mutation MUST happen on the
  main thread/main queue.
- Every started asynchronous operation MUST have a clear completion or cancellation path: completion
  handlers MUST be called exactly once on every code path; `Task`s that can outlive their owner MUST
  be cancellable and cancelled on teardown; monitors/observers MUST be cancelled/invalidated in
  `deinit` or the owner's teardown hook.
- You MUST NEVER block the main thread on I/O, network, DNS resolution, or lock waits. Blocking
  waits (semaphores, `NSCondition`) are acceptable ONLY off-main, with a timeout, where a platform
  API's callback contract makes them unavoidable — and a comment MUST justify each one.
- Timers, notification observers, and KVO observations MUST be invalidated/removed when their owner
  goes away.

## 2) Coding Standards — ABSOLUTE RULES

### Error handling
- You MUST model known failure modes as **typed `Error` enums** (with associated values carrying the
  offending input), matching the existing codebase pattern; you MUST NOT throw or return bare
  `NSError`/`String` errors for known failure modes.
- Parsing/validation is the boundary: `init?`/`throws` initializers and `parse` functions MUST
  reject malformed input with a specific error carrying the offending value.
- You MUST NOT swallow errors silently. `try?` is acceptable ONLY where a nil result is a designed,
  handled outcome — not to make errors disappear.
- Errors surfaced to the user MUST go through the codebase's established error-presentation channels
  and MUST be localized where user-facing.

### Logging & secrets
- You MUST use the codebase's established logging facility and tagging convention.
- You MUST NEVER log private keys, preshared keys, tokens, passwords, or any key material — in ANY
  log sink, error message, or exported artifact. Sensitive values MUST NOT be interpolated into
  public (non-redacted) log format specifiers.

### Resources & localization
- User-facing strings MUST be localized through the codebase's established localization mechanism —
  NEVER hardcoded in code, matching the existing pattern.
- Platform conditionals (`#if os(...)`) MUST cover every supported platform explicitly and MUST end
  with `#else` + `#error("Unsupported")`/`#error("Unimplemented")` where the codebase uses that
  guard idiom, so a new platform fails loudly at compile time.

### Interop (C / Objective-C)
- Unsafe pointer use (`withUnsafeBytes`, `assumingMemoryBound`, C struct bridging) MUST be minimal,
  locally scoped, and MUST NOT escape the closure that creates it.
- Memory ownership at C boundaries MUST be explicit: anything allocated by C and returned to Swift
  MUST be freed exactly once (matching the C API's contract); `Unmanaged` self-references passed as
  C context MUST use the retain/unretained mode that matches the callback's lifetime.
- Bridging headers / module maps are part of the ABI contract with native code (see `project.md`);
  changing an exposed C signature means changing ALL sides in the same change.

### Dependencies
- The dependency policy is minimalism: you MUST NOT add third-party dependencies (SwiftPM packages,
  frameworks, vendored code) without the user's explicit approval. Prefer the standard library and
  the platform SDKs.

## 3) Testing Rules — ABSOLUTE RULES

- The test framework for Swift is **XCTest** (or the project's already-chosen framework — see
  `project.md` for what actually exists). You MUST NOT pretend a test harness exists where
  `project.md` says there is none, and **adding a test harness/target is a tooling decision that
  REQUIRES the user's explicit approval** — it changes the project's target and CI surface.
- **Testability is still MANDATORY.** You MUST write logic to be testable: keep decision logic
  (parsing, serialization, validation, state derivation) in pure functions and plain types free of
  platform-framework calls, so it is coverable the day a harness exists — and separated from UI and
  extension lifecycles.
- IF/when a harness exists or is approved: tests MUST follow Arrange-Act-Assert with descriptive
  `test_method_scenario` names; cover happy path, edge cases, and failure modes (asserting the
  specific typed error); be fast, offline, order-independent, and self-cleaning; and MUST NOT
  require a device, entitlements, the network, or user interaction.

## 4) Quality Gates — ABSOLUTE RULES

### Definition of Done
A Swift change is DONE **ONLY** if ALL are true:

- The project builds cleanly via the project's standard build command(s) (see `project.md`), with NO
  new compiler warnings.
- The project's Swift linter (see `apple.md`/`project.md`) reports ZERO violations beyond the
  configuration already committed to the repo.
- Any harness-covered logic you added or changed is covered by tests; the existing test suite (if
  any) still passes.
- Concurrency is disciplined per §1 (confinement respected, no leaks, completion handlers complete,
  teardown paths present).
- No TODOs, no commented-out dead code, no "temporary hacks", no new globals/frameworks/harnesses/
  dependencies beyond what was agreed.

### Fix broken tests / lint — ABSOLUTE
- You MUST fix ANY broken test or lint violation, even if unrelated — finish your change first, then
  fix it immediately. You MUST NEVER leave the build, the linter, or the test suite failing.

### No lint suppression — ABSOLUTE
- You MUST NOT add lint-suppression comments (e.g. `swiftlint:disable`), new disabled rules in the
  linter configuration, or a baseline to make findings disappear. FIX the root cause. The ONLY
  acceptable suppressions are the ones ALREADY committed in the repo (enumerated per `project.md`);
  any genuinely unavoidable NEW suppression REQUIRES the user's explicit approval first (per
  `agent.md`).
