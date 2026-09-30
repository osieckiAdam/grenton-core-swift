---
name: grenton-change
description: Use for ANY change to grenton-core-swift or grenton-core-spec — library code, protocol behaviour, device mapping, public API, DocC docs, examples, README, conformance cases. Classifies the change, then walks it through spec → conformance suite → Swift port → documentation → examples, with the gates that must pass before pushing.
---

# Changing Grenton Core

The Grenton Core **spec** (`grenton-core-spec`, vendored at
`vendor/grenton-core-spec`) is the contract. The **conformance suite**
proves each port follows it. The **Swift port** implements it, and its
**DocC docs and examples** tell users how to use it. A change is done when
all four agree and `scripts/check.sh` passes.

## 1. Classify the change

Run `scripts/impact.sh` and answer:

| Question | If yes |
|---|---|
| Does it change what goes over the wire, how values are cast, how widgets map to devices/entities, entity semantics or intents, or anything else the spec describes? | **Spec first** (step 2) |
| Does it add, remove or change a `public` declaration, or change what a public API does? | **Docs** (step 4) |
| Does it change how a user would do something shown in `Examples/` or README? | **Examples** (step 5) |
| Only internals, no behaviour change? | Tests only, then step 6 |

When unsure whether the spec describes it, grep `vendor/grenton-core-spec/spec/grenton-core-design.md`.

## 2. Spec first (in `../grenton-core-spec`)

1. Change the rule in `spec/grenton-core-design.md`. Write it normatively:
   the rule, plus one line of reason when it would look arbitrary. No dates,
   runs, counts or "verified live". Where Core deliberately differs from
   the reference implementation, mark it **Δ**.
2. Add or fix conformance cases in `conformance/cases/`. Expected values
   must come from an independent source: the spec text, `openssl`, the
   reference's Python semantics, or `tools/oracles/`. Never take them from a
   port. If an oracle exists for the operation, extend it; `suite.py check`
   re-derives expectations with it.
3. Bump the versions:
   - `| **Wersja** |` in the spec header;
   - `SPEC_VERSION` in `tools/suite.py`;
   - `SUITE_VERSION` too when cases changed.

   Then run `python3 tools/suite.py manifest`.
4. Add a `CHANGELOG.md` entry naming the spec version. The evidence (what
   was observed, why) goes here, not in the spec.
5. Commit and push. The hooks check versions, the CHANGELOG, the suite and
   installation data.

## 3. Port follows (in `grenton-core-swift`)

1. Move the submodule: `git -C vendor/grenton-core-spec fetch && git -C vendor/grenton-core-spec checkout origin/main`.
2. Set `suiteVersion` in `Tests/GrentonConformanceTests/port.json`.
3. Run `swift test`. Watch the new or changed cases fail, then implement
   until the whole suite passes. Add an operation handler in
   `Tests/GrentonConformanceTests/Operations.swift` for a new operation.
4. A case the port cannot pass yet goes into `port.json` `skips` with a
   reason. A skip that starts passing fails the run.

## 4. Documentation

- Every `public` declaration in GrentonDevices and GrentonProvisioning
  needs a `///` comment written for app developers: what it is, units and
  ranges, what `nil` means. Implementer notes (spec §, Δ, reference
  quirks) go in plain `//` comments above the `///` block.
  `scripts/check-public-docs.py` enforces this.
- New user-facing types go into a Topics group in
  `Sources/GrentonDevices/GrentonDevices.docc/GrentonDevices.md`.
- If the way to do something changed, update the article in
  `GrentonDevices.docc/` (GettingStarted, Concepts, ObservingState,
  ControllingDevices). Their code and every code block in a `///` comment
  are compiled by `scripts/check-doc-snippets.py`.
- The site in `site/` repeats the user journey. The landing page has install tabs and a Swift example; `site/getting-started/` has the walkthrough. When commands, example names or the install steps change, update these pages, and README, together. Their `language-swift` code blocks are compiled too. `scripts/check-site-links.py` fails on broken internal links.
- DocC runs with warnings as errors, so broken ``links`` fail the build.
- Preview with `scripts/docs.sh`, at http://localhost:8000/.

## 5. Examples and README

`Examples/<name>/main.swift` are small, readable programs that use the
public API; README's Quick start and Examples table point to them. Try new
behaviour against a live installation by writing an example, not a new CLI
flag. The user runs live examples in **Terminal.app**, which has Local Network
access. VS Code, including its terminal, does not unless it is granted in
System Settings. Ask before any example that
changes the house (switching, heating).

## 6. Gate

`scripts/check.sh` runs these checks, and they must all pass:
- installation identifiers;
- public docs;
- spec sync;
- build;
- tests, including the conformance suite;
- DocC with warnings as errors;
- doc snippets.

Git hooks run the quick part on commit and all of it on push. Never bypass
them (`--no-verify`); fix the cause.

## Always

- **No identifiers of the user's installation** in files or commit
  messages: object names, widget ids, labels, page/CLU names, counts. Use
  synthetic ones (`THE1001`, "Taśma A"). The hooks check this against the
  interface archive: `dist/interface.zip`, or `git config grenton.interface`.
  Without an archive they fail. A clone with no installation sets
  `grenton.interface none`.
- Commit order: spec first, then the port.
