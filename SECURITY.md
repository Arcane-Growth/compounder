# Security Policy

Compounder is a local-first Android/iOS app: your data lives in a SQLite database
on your device, and the only network traffic is to the AI endpoint *you*
configure. That keeps the attack surface small, but the code still handles health
data, backups and API keys, so we treat security reports seriously.

## Supported versions

| Version | Supported |
| --- | --- |
| 0.4.x (current release candidate) | ✅ |
| 0.3.x | ✅ security fixes only |
| ≤ 0.2.x | ❌ upgrade to the latest release |

Only the latest build of a supported line receives fixes. Pre-release tags
(`v1.0.0-rc1`) are supported until the corresponding final release ships.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Preferred channel: GitHub private vulnerability reporting —
[Security → Report a vulnerability](https://github.com/arcane-growth/compounder/security/advisories/new).
It creates a private advisory visible only to you and the maintainers.

Fallback if GitHub is unavailable: email **security@arcanegrowth.com** with the
subject `[compounder] <short summary>`. If you want an encrypted reply, say so and
we will send a PGP key.

### What to include

- Affected version (`Settings → About` shows the version, or the `v*` tag).
- Platform and OS version (Android/iOS).
- Steps to reproduce, or a minimal proof of concept.
- Impact as you see it — data exposure, crash, bypass, etc.
- Whether the issue is already public anywhere.

### What to expect

| Stage | Target |
| --- | --- |
| Acknowledgement of your report | within 2 business days |
| Initial triage and severity assessment | within 5 business days |
| Fix or mitigation plan for confirmed issues | within 30 days |
| Coordinated disclosure | by agreement, default 90 days after the fix ships |

We will credit you in the advisory and the release notes unless you ask us not to.

## Scope

In scope:

- The Flutter app (`lib/`) — especially `lib/llm/llm.dart`, the entire network
  surface, and `lib/services/backup.dart`, which reads and writes user data.
- Release artifacts published on the GitHub Releases page.
- The build and release pipeline in `.github/workflows/`.
- The Arcane Gateway (`arcane-gateway`) where the app talks to Compounder AI.

Out of scope:

- Vulnerabilities in the AI endpoint you point the app at (Ollama, OpenRouter,
  your own gateway) — report those upstream.
- Issues that require a rooted/jailbroken device or a modified OS.
- Missing hardening headers on static documentation.

## Handling secrets in this repository

- **No secret is ever committed.** Signing material (`*.jks`, `*.keystore`,
  `*.p8`, `*.p12`, `*.pem`), `android/key.properties`, `android/local.properties`
  and `.env*` are gitignored.
- CI runs a **gitleaks** job over every commit on every ref, so a secret that
  slips into history fails the build.
- Release signing material is supplied to CI as repository secrets
  (`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`) and never
  written to the repository. See [docs/release-process.md](docs/release-process.md).
- Dependencies are monitored by Dependabot (`.github/dependabot.yml`).

## Repository settings we rely on

These are configured in GitHub, not in the tree. Maintainers must keep them on:

1. **Settings → Code security → Secret scanning**: enabled, with **push
   protection** enabled for all branches. This blocks a push containing a
   recognised secret before it reaches history.
2. **Settings → Code security → Dependabot alerts** and **Dependabot security
   updates**: enabled.
3. **Settings → Actions → General**: workflow permissions default to
   *read-only*; "Allow GitHub Actions to create and approve pull requests" off.
4. **Branch protection on `main`**: required PR review, required status checks,
   no force-push, signed commits. See
   [docs/branching-and-protection.md](docs/branching-and-protection.md).

If secret scanning or push protection is ever disabled, the gitleaks job in CI is
the backstop — but it only runs after the push, so push protection is the one that
actually prevents a leak.
