# Branching and repository protection

This repository is a commercial product repository. `main` is the only long-lived
branch and everything that reaches it must pass the same gate. The rules below
are enforced in GitHub settings; this document is the record of what those
settings **are**, verified against the live repository on **2026-11-10**, so they
can be re-applied if the repository is ever recreated or migrated.

Re-verify with:

```bash
gh api repos/Arcane-Growth/compounder/branches/main/protection
gh api repos/Arcane-Growth/compounder/rulesets
gh api repos/Arcane-Growth/compounder --jq '.security_and_analysis'
gh api repos/Arcane-Growth/compounder/private-vulnerability-reporting
gh api repos/Arcane-Growth/compounder/actions/permissions
gh api repos/Arcane-Growth/compounder/actions/permissions/workflow
gh api repos/Arcane-Growth/compounder/actions/permissions/fork-pr-contributor-approval
```

If the API output and this table disagree, the API is right — update this file in
the same change that alters the setting.

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

| Rule | Enforced state (verified 2026-11-10) |
| --- | --- |
| Require a pull request before merging | **on** |
| Required approvals | **1** |
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
| Restrict who can push to matching branches | **on** — no user/team/app allowlist, so effectively PRs only |
| Allow force pushes | **off** |
| Allow deletions | **off** |

GitHub allows one approval count per rule and cannot condition on file paths, so
"2 approvals for `.github/` or signing config" is not expressible. The enforced
control is **1 approval plus a Code Owners review**; CODEOWNERS names the owner
for workflows, signing configuration and release documentation.

The required-check names are the job names in `.github/workflows/ci.yml`. If a job
is renamed, update the protection rule in the same change — otherwise the rule
silently stops matching and merges go through unchecked.

## Tags

- Release tags are `v<semver>` and must be **signed** (`git tag -s`). Verify with
  `git tag -v v0.4.0`.
- Tags are immutable. If a release is wrong, delete the tag and create a new one
  with a higher build number — never move an existing tag.
- A tag ruleset, `Protect release tags (v*)`, is **active** for `refs/tags/v*`:
  deletion and non-fast-forward updates are blocked, with no bypass actors.

Current tag state (2026-11-10): **no tags are pushed to `origin`** and no GitHub
Release exists yet. Locally, `v0.1.0`–`v0.2.2` are lightweight tags and
`v0.3.0`–`v0.3.2` are annotated but unsigned. The signing requirement is therefore
forward-looking: **`v0.4.0` and every later tag must be signed**, and the earlier
tags are left as-is rather than re-created.

## Code security settings

Under **Settings → Code security**:

| Setting | Enforced state (verified 2026-11-10) |
| --- | --- |
| Secret scanning | **enabled** |
| Push protection | **enabled** for all branches |
| Secret scanning non-provider patterns | disabled |
| Secret scanning validity checks | disabled |
| Dependabot alerts | **enabled** |
| Dependabot security updates | **enabled** |
| Private vulnerability reporting | **enabled** |
| Code scanning (CodeQL) | optional — the app is Dart, so gitleaks in CI is the primary scanner |

Push protection is the only control that stops a secret *before* it enters
history. The gitleaks job in CI is a backstop that runs after the push; it catches
what push protection missed, but the secret is already in history at that point
and must be rotated.

## Actions settings

Under **Settings → Actions → General**:

| Setting | Enforced state (verified 2026-11-10) |
| --- | --- |
| Actions permissions | Allow selected actions only — GitHub-owned, `subosito/flutter-action@*`, `softprops/action-gh-release@*` |
| Workflow permissions | **Read repository contents** (default); workflows opt into `contents: write` explicitly |
| Allow GitHub Actions to create and approve pull requests | **off** |
| Require SHA pinning | **off** — see below |
| Require approval for first-time contributors | **on** |

Third-party actions are pinned to commit SHAs with a version comment in the
workflow files. Dependabot updates those pins and opens a PR; a human reviews the
diff before merging.

GitHub's `sha_pinning_required` is deliberately **off**: `subosito/flutter-action`
internally uses `actions/cache@v5` by tag, so enforcement makes every job fail at
"Set up job". The SHA-pinning convention in the workflow files is the control
instead.

## Merge strategy

- **Squash merge only** — enforced: `allow_squash_merge: true`,
  `allow_merge_commit: false`, `allow_rebase_merge: false`. One PR becomes one
  commit on `main`, with the PR title as the commit subject. This keeps `main`
  linear and makes `git bisect` usable.
- The head branch is deleted on merge (`delete_branch_on_merge: true`).
- Never merge with failing or skipped required checks. If a check is flaky, fix
  the check — do not bypass it.

## Signed commits

`main` requires signed commits (`required_signatures: enabled`, enforced for
admins). Configure one of:

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

Existing commits on `main` are unsigned (`git log --format='%G?'` → `N`). That is
expected: GitHub signs the squash commit it creates when a PR is merged, so the
history becomes verified from the first PR merge onward. A **direct push** of an
unsigned commit to `main` is rejected — which is another reason to go through a
PR.

## CODEOWNERS

`.github/CODEOWNERS` assigns review ownership. Changes to workflows, signing
configuration and release documentation require the owner's review. Keep the file
in sync with who actually holds the keys.
