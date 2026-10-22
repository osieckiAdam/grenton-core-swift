# grenton-core-swift

Swift port of the Grenton Core spec. The spec and conformance suite live in
`grenton-core-spec`, vendored as the `vendor/grenton-core-spec` submodule.

**For any change, follow the `grenton-change` skill**
(`.claude/skills/grenton-change/SKILL.md`). It covers spec first, then the
port, the docs and the examples, and the gates.

## Commands

- `scripts/check.sh`: the full gate, also run by the pre-push hook. `scripts/check.sh quick` runs the fast part.
- `scripts/impact.sh`: what a change touches and what it implies.
- `swift test`: unit tests plus the conformance suite.
- `scripts/docs.sh`: build the documentation site and serve it at http://localhost:8000/. It covers the landing page and Getting Started from `site/`, plus the DocC reference under `api/`.
- Git hooks live in `scripts/hooks`. Enable them once per clone: `git config core.hooksPath scripts/hooks`.
- The installation-data gate compares against your interface archive: `$GRENTON_INTERFACE`, `git config grenton.interface <path>`, or `dist/interface.zip`. Without one it fails. On a clone with no installation, declare it once: `git config grenton.interface none`.

## Layout

- `Sources/GrentonModel`: interface DTOs and values.
- `Sources/GrentonRuntime`: CLU sessions, transport, state store.
- `Sources/GrentonProvisioning`: Object Manager client.
- `Sources/GrentonDevices`: devices, entities, physical objects, `GrentonSystem`. This is the user-facing module.
- `Sources/*/*.docc`: DocC articles. `GrentonDevices.docc/header.html` is the site navigation shown on every reference page; the other catalogs symlink it.
- `site/`: the hand-written site pages (landing page with install tabs, Getting Started) and their CSS/JS.
- `Examples/`: library examples.
- `Examples/grenton-cli`: the smoke tool. It will move to its own repository.
- `Tests/GrentonConformanceTests`: the conformance runner, with `port.json` declaring the suite version, profiles and skips.
- `dist/`: git-ignored. It holds the user's saved interface, which contains the CLU encryption key, and the logs of live probes. Never commit it.
- `docs/grenton-core-swift-port.md`: the port plan (maintainers' notes, Polish). Code comments cite it as "Swift plan §…".

## Rules

- The spec is normative text, not a log (see the skill).
- No identifiers of the user's real installation in files or commit messages. The gate also knows the project file when `git config grenton.project <path.omp>` is set, and scans ZIP/.omp files entry by entry.
- Commit messages: one imperative sentence naming the change; a port of a spec version starts "Follow spec X.Y.Z: …" and ends with "(suite X.Y.Z)"; then a paragraph on what changed and why.
- Live runs need Local Network access for the app they run in. On this Mac, Terminal.app has it. VS Code, including its built-in terminal and Claude's session, does not unless it is granted in System Settings → Privacy & Security → Local Network. Writes that change the house need the user's go-ahead.
- GrentonModel and GrentonRuntime are not docs-gated yet. Much of their public API is plumbing between modules and should become `package` access.
