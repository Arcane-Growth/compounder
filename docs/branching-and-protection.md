# Branching and repository protection

This repository is a commercial product repository. `main` is the only long-lived
branch and everything that reaches it must pass the same gate. The rules below
are enforced in GitHub settings; this document is the record of what those
settings must be, so they can be re-applied if the repository is ever recreated
or migrated.

## Branch model

| Branch | Purpose | Lifetime |
| --- | --- | --- |
| `main` | Always releasable. Protected. | permanent |
| `feat/<slug>` | New capability | short-lived, deleted on merge |
| `fix/<slug>` | Bug fix | short-lived, deleted on merge |
| `chore/<slug>` | Tooling, CI, dependencies, docs | short-lived, deleted on merge |
| `release/<version>` | Release preparation only | deleted after the tag |

No other long-lived branches. No `develop`. Release candidates are tags, not
branches.

## Protection rules for `main`

Configure under **Settings → Branches → Branch protection rules → `main`**:

| Rule | Setting |
| --- | --- |
| Require a pull request before merging | **on** |
| Required approvals | **1** (2 for changes to `.github/workflows/` or signing config) |
| Dismiss stale approvals when new commits are pushed | **on** |
| Require review from Code Owners | **on** (`.github/CODEOWNERS`) |
| Require approval of the most recent reviewable push | **on** |
| Require status checks to pass | **on** |
| Required checks | `Secret scan (gitleaks)`, `Format check`, `Analyze and test`, `Release build (ephemeral CI key)` |
| Require branches to be up to date before merging | **on** |
| Require conversation resolution before merging | **on** |
| Require signed commits | **on** |
| Require linear history | **on** |
| Do not allow bypassing the above settings | **on** (applies to admins too) |
| Restrict who can push to matching branches | **on** — nobody pushes directly; PRs only |
| Allow force pushes | **off** |
| Allow deletions | **off** |

The required-check names are the job names in `.github/workflows/ci.yml`. If a job
is renamed, update the protection rule in the same change — otherwise the rule
silently stops matching and merges go through unchecked.

## Tags

- Release tags are `v<semver>` and must be **signed** (`git tag -s`). Verify with
  `git tag -v v0.4.0`.
- Tags are immutable. If a release is wrong, delete the tag and create a new one
  with a higher build number — never move an existing tag.
- Protect tags matching `v*` against deletion and force-update
  (**Settings → Tags → protection rule**).

## Code security settings

Under **Settings → Code security**:

| Setting | State |
| --- | --- |
| Secret scanning | **enabled** |
| Push protection | **enabled** for all branches |
| Dependabot alerts | **enabled** |
| Dependabot security updates | **enabled** |
| Code scanning (CodeQL) | optional — the app is Dart, so gitleaks in CI is the primary scanner |

Push protection is the only control that stops a secret *before* it enters
history. The gitleaks job in CI is a backstop that runs after the push; it catches
what push protection missed, but the secret is already in history at that point
and must be rotated.

## Actions settings

Under **Settings → Actions → General**:

| Setting | State |
| --- | --- |
| Actions permissions | Allow selected actions only — `actions/*`, `subosito/flutter-action`, `softprops/action-gh-release` |
| Workflow permissions | **Read repository contents** (default); workflows opt into `contents: write` explicitly |
| Allow GitHub Actions to create and approve pull requests | **off** |
| Require approval for first-time contributors | **on** |

Third-party actions are pinned to commit SHAs with a version comment in the
workflow files. Dependabot updates those pins and opens a PR; a human reviews the
diff before merging.

## Merge strategy

- **Squash merge only.** One PR becomes one commit on `main`, with the PR title as
  the commit subject. This keeps `main` linear and makes `git bisect` usable.
- Delete the branch after merge.
- Never merge with failing or skipped required checks. If a check is flaky, fix
  the check — do not bypass it.

## Signed commits

`main` requires signed commits. Configure one of:

```bash
# SSH signing (recommended; no GPG agent needed)
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
git config --global tag.gpgsign true
```

Then add the same public key to GitHub under **Settings → SSH and GPG keys → New
SSH key → Signing key**. Commits signed with a key GitHub does not know are shown
as unverified and will be rejected by the protection rule.

## CODEOWNERS

`.github/CODEOWNERS` assigns review ownership. Changes to workflows, signing
configuration and release documentation require the owner's review. Keep the file
in sync with who actually holds the keys.
