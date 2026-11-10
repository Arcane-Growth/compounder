# Security Policy

Compounder is a local-first Android/iOS app: your data lives in a SQLite database
on your device. The app makes network calls to exactly two kinds of destination:
the AI endpoint *you* configure, and `gateway.arcanegrowth.com` for the optional
Compounder AI subscription (device registration, purchase verification,
entitlement and usage). That keeps the attack surface small, but the code still
handles health data, backups and API keys, so we treat security reports seriously.

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

- The Flutter app (`lib/`) — especially `lib/llm/llm.dart` and
  `lib/llm/routing.dart` (the chat/vision network surface),
  `lib/subscription/gateway.dart` (subscription endpoints), and
  `lib/services/backup.dart`, which reads and writes user data.
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
- Dependencies are monitored by Dependabot (`.github/dependabot.yml`) for
  Dart/pub, GitHub Actions and Gradle (AGP, Kotlin, desugaring).

## Repository settings we rely on

Compounder's source is **public** (MIT). These settings are configured in GitHub,
not in the tree; maintainers must keep them on. Verified against the live
repository on **2026-11-10** with `gh api repos/Arcane-Growth/compounder` and the
endpoints named below — re-run those commands before trusting this list.

1. **Secret scanning**: enabled, with **push protection** enabled for all
   branches (`security_and_analysis.secret_scanning` and
   `.secret_scanning_push_protection` → `enabled`). This blocks a push containing
   a recognised secret before it reaches history. Non-provider patterns and
   validity checks are off; open alerts: 0
   (`gh api repos/Arcane-Growth/compounder/secret-scanning/alerts`).
2. **Dependabot alerts** and **Dependabot security updates**: enabled
   (`vulnerability-alerts` → 204, `automated-security-fixes` → `enabled`).
3. **Private vulnerability reporting**: enabled
   (`gh api repos/Arcane-Growth/compounder/private-vulnerability-reporting` →
   `{"enabled":true}`), so the link in the section above works.
4. **Actions**: allow selected actions only (GitHub-owned plus
   `subosito/flutter-action@*` and `softprops/action-gh-release@*`); workflow
   permissions default to *read-only*; "Allow GitHub Actions to create and
   approve pull requests" off. SHA pinning is **not** enforced by GitHub — the
   workflows pin every action to a 40-character SHA by convention instead
   (`sha_pinning_required: false`, because `subosito/flutter-action` internally
   uses `actions/cache@v5` by tag and would fail setup under enforcement).
5. **Branch protection on `main`**: required PR review (1 approval, Code Owners,
   dismiss stale approvals, approval of the latest push), four required status
   checks, signed commits, linear history, conversation resolution, no
   force-push, no deletion, enforced for admins. See
   [docs/branching-and-protection.md](docs/branching-and-protection.md) for the
   exact rule set.
6. **Tag protection**: ruleset `Protect release tags (v*)` is active for
   `refs/tags/v*` — deletion and non-fast-forward updates are blocked.
7. **Merge policy**: squash merge only; merge commits and rebase are disabled and
   the branch is deleted on merge.

If secret scanning or push protection is ever disabled, the gitleaks job in CI is
the backstop — but it only runs after the push, so push protection is the one that
actually prevents a leak.
